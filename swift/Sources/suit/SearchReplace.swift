import Foundation

// The project-wide replace behind the sidebar's Search tab: turning a set of
// ripgrep hits into rewritten files.
//
// Foundation-only with the file IO injected (the FindReplace / EditorOps
// pattern), so a harness can drive a whole apply pass over in-memory files. The
// AppKit half (SearchView) owns the fields, the confirm sheet and the status
// line; it asks this what a replace would do and what it did, and re-derives
// none of it.
//
// Matching is delegated to FindReplace — the same engine the file viewer's ⌘F
// bar uses — but applied *line by line*, because a line is the coordinate system
// the results list speaks. rg runs without --multiline, so every hit the user is
// looking at is a match inside one line; feeding the whole file to
// NSRegularExpression instead would anchor `^` and `$` to the file's ends and
// replace somewhere other than where the hit was shown.
enum SearchReplace {

    // MARK: - Query

    // The rg options the visible results were built from, expressed as the
    // FindQuery that reproduces them.
    //
    // Every flag has to travel: a query that matches *less* than the search did
    // quietly skips hits the user is looking at, and one that matches more
    // rewrites text they were never shown. wholeWord in particular defaults off
    // so a caller that predates the ab toggle can't accidentally turn rg -w on.
    static func query(pattern: String, isRegex: Bool, caseSensitive: Bool,
                      wholeWord: Bool = false) -> FindQuery {
        FindQuery(text: pattern, caseSensitive: caseSensitive, wholeWord: wholeWord, regex: isRegex)
    }

    // MARK: - Gate

    // Whether Replace All may run at all, and why not when it may not. The UI
    // renders `refusal` into the status line rather than deciding for itself.
    enum Gate: Equatable {
        case ready(files: Int, replacements: Int)
        case noPattern
        case stillSearching
        case truncated
        case noMatches

        // nil when the replace is allowed to proceed.
        var refusal: String? {
            switch self {
            case .ready: return nil
            case .noPattern: return "Type a search pattern first"
            case .stillSearching: return "Still searching — let the results settle first"
            case .truncated: return "Too many matches to replace safely — narrow the search first"
            case .noMatches: return "No matches to replace"
            }
        }
    }

    static func gate(pattern: String, fileCount: Int, matchCount: Int,
                     isSearching: Bool, truncated: Bool) -> Gate {
        if pattern.isEmpty { return .noPattern }
        // Replacing while rg is still streaming would rewrite the files that
        // happened to arrive first and stop there.
        if isSearching { return .stillSearching }
        // A capped result set is a partial view of the matches: replacing what is
        // listed leaves the rest of the repo silently untouched, which is worse
        // than refusing. A glob or a tighter scope brings it back under the cap.
        if truncated { return .truncated }
        if matchCount == 0 || fileCount == 0 { return .noMatches }
        return .ready(files: fileCount, replacements: matchCount)
    }

    // The same gate for the single file behind a result row's ⇄ button.
    //
    // Truncation deliberately isn't a refusal here. The cap makes the *file
    // list* partial, which is what makes Replace All unsafe; this pass rewrites
    // one whole file, so every match in it is replaced whether or not the list
    // got to show them all. A still-streaming search is still a refusal, because
    // the row's own match count is mid-flight.
    static func fileGate(pattern: String, matchCount: Int, isSearching: Bool) -> Gate {
        if pattern.isEmpty { return .noPattern }
        if isSearching { return .stillSearching }
        if matchCount == 0 { return .noMatches }
        return .ready(files: 1, replacements: matchCount)
    }

    // MARK: - Prose

    // The confirm sheet's two strings. Project-wide replace edits files that
    // aren't open in any pane, so there is no ⌘Z waiting on the other side of it —
    // the detail line says so instead of implying a way back.
    static func confirmation(files: Int, replacements: Int, template: String,
                             scopeLabel: String) -> (message: String, detail: String) {
        let fileText = count(files, "file", "files")
        let matchText = count(replacements, "match", "matches")
        let target = template.isEmpty ? "deleting them" : "replacing them with “\(template)”"
        return (
            "Replace \(matchText) in \(fileText)?",
            "This rewrites \(fileText) under \(scopeLabel) on disk, \(target). "
                + "Files that aren't open in a pane can't be undone from here — commit or stash first."
        )
    }

    // What the status line says once the pass is done.
    static func summary(_ outcome: Outcome) -> String {
        var parts: [String] = []
        if outcome.replacements > 0 {
            parts.append("Replaced \(count(outcome.replacements, "match", "matches"))"
                + " in \(count(outcome.filesChanged.count, "file", "files"))")
        }
        if let first = outcome.skipped.first {
            parts.append(outcome.skipped.count == 1
                ? "skipped \(first.relativePath) (\(first.reason))"
                : "skipped \(outcome.skipped.count) files")
        }
        return parts.isEmpty ? "Nothing to replace" : parts.joined(separator: " — ")
    }

    private static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n) \(n == 1 ? singular : plural)"
    }

    // MARK: - Applying

    // One file skipped and why, so the summary can name it instead of pretending
    // the pass was clean.
    struct Skip: Equatable {
        let relativePath: String
        let reason: String
    }

    struct Outcome: Equatable {
        var filesChanged: [String] = []
        var replacements: Int = 0
        var skipped: [Skip] = []
    }

    // Every match on every line of `text` replaced, plus how many there were.
    // Returns the text unchanged (and 0) when nothing matches, so a caller can
    // skip dirtying a file over a no-op.
    static func replaceAll(inFileText text: String, query: FindQuery,
                           template: String, preserveCase: Bool = false) -> (text: String, count: Int) {
        guard !query.isEmpty else { return (text, 0) }
        var lines = text.components(separatedBy: "\n")
        var total = 0
        for index in lines.indices {
            let line = lines[index]
            // A CRLF file leaves the \r at the end of every component. Matching
            // over it would put a `$`-anchored pattern one character off the end
            // of the line, so it is peeled off and re-attached.
            let hasCarriageReturn = line.hasSuffix("\r")
            let body = hasCarriageReturn ? String(line.dropLast()) : line
            let replaced = replaceLine(body, query: query, template: template, preserveCase: preserveCase)
            guard replaced.count > 0 else { continue }
            total += replaced.count
            lines[index] = hasCarriageReturn ? replaced.text + "\r" : replaced.text
        }
        guard total > 0 else { return (text, 0) }
        return (lines.joined(separator: "\n"), total)
    }

    // One line. With preserve-case off this is FindReplace's one-pass rewrite
    // verbatim; with it on the loop has to be unrolled here, because the
    // transform needs the text each individual match consumed and
    // FindReplace.replaceAll only hands back the finished line.
    private static func replaceLine(_ body: String, query: FindQuery, template: String,
                                    preserveCase: Bool) -> (text: String, count: Int) {
        guard preserveCase else {
            return FindReplace.replaceAll(in: body, query: query, template: template)
        }
        let ranges = FindReplace.matchRanges(in: body, query: query)
        guard !ranges.isEmpty else { return (body, 0) }
        let ns = body as NSString
        var result = ""
        var cursor = 0
        for range in ranges {
            result += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            let expanded = FindReplace.replacementText(in: body, matchRange: range,
                                                       query: query, template: template)
            result += preservingCase(expanded, matching: ns.substring(with: range))
            cursor = range.location + range.length
        }
        result += ns.substring(from: cursor)
        return (result, ranges.count)
    }

    // The AB toggle: carry the *matched* text's capitalization onto the
    // replacement, so replacing "widget" also fixes "Widget" and "WIDGET"
    // without three passes.
    //
    // This only ever raises case, never lowers it. VS Code additionally
    // lowercases the replacement when the match was all-lowercase, which
    // silently destroys a deliberately-cased template — replacing "handler"
    // with "onKeyDown" would write "onkeydown". Leaving a lowercase match
    // verbatim gives the same answer for the case everyone actually types
    // (a lowercase template) and stops mangling the case that they don't.
    static func preservingCase(_ replacement: String, matching matched: String) -> String {
        let letters = matched.filter(\.isLetter)
        guard let firstLetter = letters.first, let firstCharacter = replacement.first else {
            return replacement
        }
        // A single uppercase letter is ambiguous between ALLCAPS and Titlecase;
        // it falls through to the title branch, which agrees with both.
        if letters.count > 1, letters.allSatisfy(\.isUppercase) {
            return replacement.uppercased()
        }
        if firstLetter.isUppercase {
            return String(firstCharacter).uppercased() + replacement.dropFirst()
        }
        return replacement
    }

    // Apply across the files the search listed, in order.
    //
    // `read` and `write` are injected (path in, text out / path and text in) so
    // the harness can run the pass over a dictionary; the app hands in a UTF-8
    // read and FileEditWriter's atomic write — the same writer ⌘S uses, so a
    // crash mid-pass can't leave a half-written source file.
    static func apply(root: String, relativePaths: [String], query: FindQuery, template: String,
                      preserveCase: Bool = false,
                      read: (String) throws -> String,
                      write: (String, String) throws -> Void) -> Outcome {
        var outcome = Outcome()
        guard !query.isEmpty else { return outcome }
        for relativePath in relativePaths {
            let path = absolutePath(root: root, relativePath: relativePath)
            let text: String
            do {
                text = try read(path)
            } catch {
                outcome.skipped.append(Skip(relativePath: relativePath, reason: "unreadable as UTF-8 text"))
                continue
            }
            let result = replaceAll(inFileText: text, query: query, template: template,
                                    preserveCase: preserveCase)
            guard result.count > 0 else {
                // Two ways to land here, both worth reporting rather than
                // writing the file back byte-identical: the file changed since
                // the search ran, or rg's Rust regex accepted a pattern that
                // ICU's dialect reads differently.
                outcome.skipped.append(Skip(relativePath: relativePath, reason: "no longer matches"))
                continue
            }
            do {
                try write(path, result.text)
            } catch {
                outcome.skipped.append(Skip(relativePath: relativePath, reason: "write failed"))
                continue
            }
            outcome.filesChanged.append(relativePath)
            outcome.replacements += result.count
        }
        return outcome
    }

    // rg reports paths relative to the directory it ran in; an absolute path is
    // passed through so a caller that already resolved one isn't punished.
    static func absolutePath(root: String, relativePath: String) -> String {
        relativePath.hasPrefix("/") ? relativePath : root + "/" + relativePath
    }
}
