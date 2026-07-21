import Foundation

// The UI-free core of the viewer's editing intelligence: auto-indent, bracket
// auto-close, comment toggling, indent/outdent, and the range math behind
// multi-cursor (⌘D add-next-occurrence) and column selection. Foundation-only
// with no app deps — the FindReplace / FileEdit / RoadmapParser pattern — so
// scripts/editor-ops-test.sh compiles it standalone and asserts the rules.
// FileViewerPane+SmartTyping.swift and +MultiCursor.swift are the thin AppKit
// halves that turn these decisions into NSTextView edits.
//
// Everything here works in UTF-16 offsets (NSString's world), because that is
// what NSTextView hands us and what lineStarts is built from. Mixing in
// Character offsets would be a silent off-by-N on any file with an emoji in it.

// The language traits editing cares about. Deliberately *not* CodeLanguage from
// SyntaxHighlighter.swift: that file imports Cocoa, which would drag AppKit into
// a core the harness has to compile on its own. The two detect() tables are
// allowed to drift — highlighting cares about keywords, editing cares about
// comment markers and whether blocks are braced or indented.
enum EditorLanguage {
    case swift, go, javascript, python, shell, json, yaml, markdown, c, ruby, sql, lisp, plain

    static func detect(path: String) -> EditorLanguage {
        let name = (path as NSString).lastPathComponent.lowercased()
        switch (name as NSString).pathExtension {
        case "swift": return .swift
        case "go": return .go
        case "js", "jsx", "ts", "tsx", "mjs", "cjs": return .javascript
        case "py": return .python
        case "sh", "bash", "zsh": return .shell
        case "json": return .json
        case "yaml", "yml": return .yaml
        case "md", "markdown": return .markdown
        case "c", "h", "m", "mm", "cpp", "hpp", "cc": return .c
        case "rb": return .ruby
        case "sql": return .sql
        case "el", "lisp", "clj", "scm": return .lisp
        default:
            switch name {
            case "makefile", "dockerfile", ".zshrc", ".zprofile", ".bashrc", "build.sh": return .shell
            default: return .plain
            }
        }
    }

    // The token that comments out a line, or nil where the language has none we
    // can safely insert (JSON). ⌘/ is a no-op rather than a corruption there.
    var lineComment: String? {
        switch self {
        case .swift, .go, .javascript, .c: return "//"
        case .python, .shell, .yaml, .ruby: return "#"
        case .sql: return "--"
        case .lisp: return ";"
        case .markdown, .json, .plain: return nil
        }
    }

    // Whether blocks are delimited by braces (fold + auto-indent by nesting) or
    // by indentation alone (fold by column, indent after a trailing colon).
    var usesBraces: Bool {
        switch self {
        case .python, .yaml, .markdown, .plain: return false
        default: return true
        }
    }

    // One indent step. Tabs are never emitted — the repo's own sources are
    // spaces, and a mixed-indentation file is worse than a wrongly-sized one.
    var indentWidth: Int {
        switch self {
        case .go: return 4          // gofmt uses tabs; 4 spaces is the closest we emit
        case .yaml, .ruby: return 2
        default: return 4
        }
    }
}

enum EditorOps {

    // MARK: - Lines

    // The UTF-16 line starts of `text`, the same shape FileViewerPaneContent
    // maintains. Duplicated here (rather than passed in) so the harness can
    // build inputs without an app object.
    static func lineStarts(of text: String) -> [Int] {
        var starts = [0]
        let ns = text as NSString
        var index = 0
        while index < ns.length {
            let found = ns.range(of: "\n", options: [], range: NSRange(location: index, length: ns.length - index))
            if found.location == NSNotFound { break }
            starts.append(found.location + 1)
            index = found.location + 1
        }
        return starts
    }

    // The 0-based index of the line owning `offset` — the last start ≤ offset.
    static func lineIndex(forOffset offset: Int, lineStarts: [Int]) -> Int {
        guard !lineStarts.isEmpty else { return 0 }
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    // The full UTF-16 range of a 0-based line, newline included when there is
    // one. Out-of-range indices return nil rather than clamping — a caller
    // asking for line 900 of a 12-line file has a bug we shouldn't paper over.
    static func lineRange(_ index: Int, lineStarts: [Int], length: Int) -> NSRange? {
        guard lineStarts.indices.contains(index) else { return nil }
        let start = lineStarts[index]
        let end = index + 1 < lineStarts.count ? lineStarts[index + 1] : length
        guard start <= end, end <= length else { return nil }
        return NSRange(location: start, length: end - start)
    }

    // The 0-based line indices a selection touches. A zero-length selection
    // touches exactly its own line; a selection ending exactly at a line start
    // does *not* pull that next line in (matching how every editor renders a
    // full-line selection made by dragging down).
    static func lineIndices(touching range: NSRange, lineStarts: [Int]) -> [Int] {
        let first = lineIndex(forOffset: range.location, lineStarts: lineStarts)
        guard range.length > 0 else { return [first] }
        var lastOffset = range.location + range.length
        if lastOffset > range.location { lastOffset -= 1 }
        let last = lineIndex(forOffset: lastOffset, lineStarts: lineStarts)
        return Array(first...max(first, last))
    }

    // The leading whitespace of a line, verbatim (so a tab-indented file keeps
    // its tabs when you press Return in it).
    static func leadingWhitespace(of line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    // MARK: - Auto-indent

    // What to insert for a Return pressed at `offset`.
    //
    // `indent` is the new line's leading whitespace. `closingLine` is non-nil
    // when the caret sat between a matching brace pair (`{|}`) — the editor then
    // opens a blank indented line and pushes the closer down onto its own line,
    // the behavior every code editor has and the single most-missed thing in a
    // plain NSTextView.
    struct NewlineIndent: Equatable {
        let indent: String
        let closingLine: String?
    }

    static func newlineIndent(text: String, offset: Int, language: EditorLanguage) -> NewlineIndent {
        let ns = text as NSString
        let starts = lineStarts(of: text)
        let index = lineIndex(forOffset: offset, lineStarts: starts)
        guard let range = lineRange(index, lineStarts: starts, length: ns.length) else {
            return NewlineIndent(indent: "", closingLine: nil)
        }
        var line = ns.substring(with: range)
        if line.hasSuffix("\n") { line = String(line.dropLast()) }

        let base = leadingWhitespace(of: line)
        // Only the text to the *left* of the caret decides whether we open a
        // block: pressing Return in the middle of `if x { foo() }` should indent
        // off `if x {`, not off the whole line.
        let column = max(0, min(offset - range.location, (line as NSString).length))
        let before = (line as NSString).substring(to: column).trimmingCharacters(in: .whitespaces)
        let after = (line as NSString).substring(from: column).trimmingCharacters(in: .whitespaces)

        let step = String(repeating: " ", count: language.indentWidth)
        let opensBlock: Bool = language.usesBraces
            ? (before.hasSuffix("{") || before.hasSuffix("[") || before.hasSuffix("("))
            : before.hasSuffix(":")

        guard opensBlock else { return NewlineIndent(indent: base, closingLine: nil) }

        // `{|}` — the closer goes to its own line at the original indent.
        if language.usesBraces, let opener = before.last, let closer = closingBracket(for: opener),
           after.first == closer {
            return NewlineIndent(indent: base + step, closingLine: base)
        }
        return NewlineIndent(indent: base + step, closingLine: nil)
    }

    // MARK: - Bracket & quote pairs

    static func closingBracket(for open: Character) -> Character? {
        switch open {
        case "{": return "}"
        case "[": return "]"
        case "(": return ")"
        default: return nil
        }
    }

    // The quote characters that auto-close as a pair. Backtick is in for JS
    // template literals and Markdown code spans; the apostrophe is *not*
    // excluded per-language, because the skip-over rule below makes a stray
    // `don't` cost at most one extra keystroke.
    static let quoteCharacters: Set<Character> = ["\"", "'", "`"]

    // What typing `character` at `offset` should do.
    enum TypingAction: Equatable {
        case insert(String)            // plain — let the text view handle it
        case insertPair(String)        // insert both halves, caret between them
        case skipOver                  // the closer is already there; step past it
    }

    static func typingAction(text: String, offset: Int, character: Character, language: EditorLanguage) -> TypingAction {
        let ns = text as NSString
        let nextChar: Character? = offset < ns.length ? Character(ns.substring(with: NSRange(location: offset, length: 1))) : nil
        let prevChar: Character? = offset > 0 ? Character(ns.substring(with: NSRange(location: offset - 1, length: 1))) : nil

        // Typing the closer that's already sitting under the caret steps over it
        // rather than doubling it — the other half of auto-close, and the thing
        // that makes auto-close tolerable instead of infuriating.
        if let nextChar, nextChar == character,
           character == ")" || character == "]" || character == "}" || quoteCharacters.contains(character) {
            return .skipOver
        }

        if let closer = closingBracket(for: character) {
            // Don't auto-close when the caret is immediately before a word: you
            // are almost always wrapping, e.g. typing `(` before `foo` to make
            // `(foo)` by hand.
            if let nextChar, isIdentifierCharacter(nextChar) { return .insert(String(character)) }
            return .insertPair(String(character) + String(closer))
        }

        if quoteCharacters.contains(character) {
            // An apostrophe right after a word character is a contraction or a
            // Rust lifetime, never an opening quote.
            if character == "'", let prevChar, isIdentifierCharacter(prevChar) { return .insert("'") }
            if let nextChar, isIdentifierCharacter(nextChar) { return .insert(String(character)) }
            // A third quote in a row is a Python docstring fence — don't pair it.
            if language == .python, offset >= 2,
               ns.substring(with: NSRange(location: offset - 2, length: 2)) == String(repeating: character, count: 2) {
                return .insert(String(character))
            }
            return .insertPair(String(repeating: character, count: 2))
        }

        return .insert(String(character))
    }

    // Typing an opener with text selected wraps the selection instead of
    // replacing it — nil when the character isn't a wrapping one.
    static func wrap(_ selection: String, with character: Character) -> String? {
        if let closer = closingBracket(for: character) {
            return String(character) + selection + String(closer)
        }
        if quoteCharacters.contains(character) {
            return String(character) + selection + String(character)
        }
        return nil
    }

    // Backspace between the two halves of a freshly-typed pair deletes both.
    static func shouldDeletePair(text: String, offset: Int) -> Bool {
        let ns = text as NSString
        guard offset > 0, offset < ns.length else { return false }
        let before = Character(ns.substring(with: NSRange(location: offset - 1, length: 1)))
        let after = Character(ns.substring(with: NSRange(location: offset, length: 1)))
        if let closer = closingBracket(for: before), closer == after { return true }
        return quoteCharacters.contains(before) && before == after
    }

    static func isIdentifierCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    // MARK: - Indent / outdent (⌃⌘] / ⌃⌘[)

    // A whole-line rewrite: the new text for each touched line, plus how much
    // the first and last line shifted so the caller can keep the selection
    // covering the same text.
    struct LineRewrite: Equatable {
        let lines: [String]         // replacements, one per touched line (no newlines)
        let firstLineDelta: Int     // UTF-16 units added (+) or removed (−) on the first line
        let totalDelta: Int         // ditto, summed over every line
    }

    static func indent(lines: [String], language: EditorLanguage) -> LineRewrite {
        let step = String(repeating: " ", count: language.indentWidth)
        var out: [String] = []
        var first = 0
        var total = 0
        for (i, line) in lines.enumerated() {
            // An empty line gains nothing — indenting blank lines leaves trailing
            // whitespace behind on every block you ever indent.
            if line.isEmpty {
                out.append(line)
                continue
            }
            out.append(step + line)
            if i == 0 { first = step.utf16.count }
            total += step.utf16.count
        }
        return LineRewrite(lines: out, firstLineDelta: first, totalDelta: total)
    }

    static func outdent(lines: [String], language: EditorLanguage) -> LineRewrite {
        var out: [String] = []
        var first = 0
        var total = 0
        for (i, line) in lines.enumerated() {
            let removed = removedIndent(from: line, width: language.indentWidth)
            out.append(String(line.dropFirst(removed)))
            let units = String(line.prefix(removed)).utf16.count
            if i == 0 { first = -units }
            total -= units
        }
        return LineRewrite(lines: out, firstLineDelta: first, totalDelta: total)
    }

    // How many leading characters one outdent step removes: a single tab, or up
    // to `width` spaces — never more indentation than the line actually has.
    private static func removedIndent(from line: String, width: Int) -> Int {
        if line.first == "\t" { return 1 }
        var count = 0
        for c in line {
            if c == " ", count < width { count += 1 } else { break }
        }
        return count
    }

    // MARK: - Comment toggling (⌘/)

    // Toggle line comments over a block. Uncomment when *every* non-blank line
    // is already commented (VS Code's rule) — a half-commented block comments
    // the rest rather than flip-flopping. The marker goes at the block's
    // shallowest indent so a commented block keeps its shape.
    static func toggleComment(lines: [String], language: EditorLanguage) -> LineRewrite? {
        guard let token = language.lineComment else { return nil }
        let meaningful = lines.enumerated().filter { !$0.element.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !meaningful.isEmpty else { return nil }

        let allCommented = meaningful.allSatisfy {
            $0.element.trimmingCharacters(in: .whitespaces).hasPrefix(token)
        }

        var out: [String] = []
        var first = 0
        var total = 0

        if allCommented {
            for (i, line) in lines.enumerated() {
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { out.append(line); continue }
                let indent = leadingWhitespace(of: line)
                var body = String(line.dropFirst(indent.count))
                body = String(body.dropFirst(token.count))
                // Remove the single space we (or a human) put after the marker,
                // but never a second one — that's the reader's own indentation.
                if body.hasPrefix(" ") { body = String(body.dropFirst()) }
                let rewritten = indent + body
                let delta = rewritten.utf16.count - line.utf16.count
                if i == 0 { first = delta }
                total += delta
                out.append(rewritten)
            }
        } else {
            let column = meaningful.map { leadingWhitespace(of: $0.element).count }.min() ?? 0
            for (i, line) in lines.enumerated() {
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { out.append(line); continue }
                let head = String(line.prefix(column))
                let rewritten = head + token + " " + String(line.dropFirst(column))
                let delta = rewritten.utf16.count - line.utf16.count
                if i == 0 { first = delta }
                total += delta
                out.append(rewritten)
            }
        }
        return LineRewrite(lines: out, firstLineDelta: first, totalDelta: total)
    }

    // MARK: - Multi-cursor: next occurrence (⌘D)

    // The word straddling `offset`, as a range — what the first ⌘D selects when
    // nothing is selected yet. nil when the caret isn't on a word.
    static func wordRange(in text: String, at offset: Int) -> NSRange? {
        let units = Array(text.utf16)
        guard offset >= 0, offset <= units.count else { return nil }
        func isUnit(_ i: Int) -> Bool {
            guard units.indices.contains(i) else { return false }
            let u = units[i]
            return (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || u == 0x5F
        }
        var anchor = offset
        if !isUnit(anchor) {
            guard anchor > 0, isUnit(anchor - 1) else { return nil }
            anchor -= 1
        }
        var start = anchor
        while start > 0, isUnit(start - 1) { start -= 1 }
        var end = anchor
        while isUnit(end) { end += 1 }
        guard start < end else { return nil }
        return NSRange(location: start, length: end - start)
    }

    // The next exact occurrence of `needle` at or after `from`, wrapping to the
    // top once. `excluding` holds the ranges already carrying a cursor, so a
    // repeated ⌘D walks forward through the file instead of re-finding one it
    // has. Returns nil when every occurrence is already selected.
    static func nextOccurrence(of needle: String, in text: String, from: Int, excluding: [NSRange]) -> NSRange? {
        guard !needle.isEmpty else { return nil }
        let ns = text as NSString
        let taken = Set(excluding.map { $0.location })

        func search(in range: NSRange) -> NSRange? {
            var cursor = range
            while cursor.length > 0 {
                let found = ns.range(of: needle, options: [.literal], range: cursor)
                if found.location == NSNotFound { return nil }
                if !taken.contains(found.location) { return found }
                let next = found.location + 1
                guard next < NSMaxRange(range) else { return nil }
                cursor = NSRange(location: next, length: NSMaxRange(range) - next)
            }
            return nil
        }

        let start = max(0, min(from, ns.length))
        if let found = search(in: NSRange(location: start, length: ns.length - start)) { return found }
        return search(in: NSRange(location: 0, length: start))
    }

    // Every occurrence of `needle` (Select All Occurrences, ⌃⌘G).
    static func allOccurrences(of needle: String, in text: String) -> [NSRange] {
        guard !needle.isEmpty else { return [] }
        let ns = text as NSString
        var result: [NSRange] = []
        var cursor = NSRange(location: 0, length: ns.length)
        while cursor.length > 0 {
            let found = ns.range(of: needle, options: [.literal], range: cursor)
            if found.location == NSNotFound { break }
            result.append(found)
            let next = NSMaxRange(found)
            guard next <= ns.length else { break }
            cursor = NSRange(location: next, length: ns.length - next)
        }
        return result
    }

    // MARK: - Column (box) selection

    // The per-line ranges of a rectangular selection between two document
    // offsets. Each line contributes the slice between the two *columns*,
    // clamped to that line's own length — so dragging a box past the end of a
    // short line yields a zero-length range there (a bare cursor), which is
    // exactly what makes ⌥-drag useful for appending to ragged lines.
    static func columnRanges(text: String, from: Int, to: Int) -> [NSRange] {
        let ns = text as NSString
        let starts = lineStarts(of: text)
        let anchorLine = lineIndex(forOffset: from, lineStarts: starts)
        let headLine = lineIndex(forOffset: to, lineStarts: starts)
        let anchorColumn = from - starts[anchorLine]
        let headColumn = to - starts[headLine]

        let (topLine, bottomLine) = anchorLine <= headLine ? (anchorLine, headLine) : (headLine, anchorLine)
        let left = min(anchorColumn, headColumn)
        let right = max(anchorColumn, headColumn)

        var ranges: [NSRange] = []
        for line in topLine...bottomLine {
            guard let full = lineRange(line, lineStarts: starts, length: ns.length) else { continue }
            // The line's own content width, newline excluded — a box selection
            // must never swallow a line break, or the lines would merge.
            var contentLength = full.length
            if full.length > 0, ns.substring(with: NSRange(location: NSMaxRange(full) - 1, length: 1)) == "\n" {
                contentLength -= 1
            }
            let start = full.location + min(left, contentLength)
            let end = full.location + min(right, contentLength)
            ranges.append(NSRange(location: start, length: max(0, end - start)))
        }
        return ranges
    }
}
