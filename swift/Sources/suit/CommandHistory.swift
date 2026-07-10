import Foundation

// Command history search — the shell's reverse-i-search made
// native and cross-pane: search past commands from any pane, pick one, and
// re-run it in a pane of your choice.
//
// This file is the UI-free, standalone-compilable core (the RoadmapParser /
// FeedbackRouting / Recipes / Activity pattern, Foundation-only, no AppKit and
// no app deps), so scripts/command-history-test.sh can compile it in isolation
// (alongside FuzzyMatch.swift, the shared scorer the overlay ranks with) and
// assert the parse/dedup, the fuzzy ranking, the destructive-command detection,
// and the send-vs-edit pty payload — without any UI. The AppKit halves are
// CommandHistoryStore.swift (loads $HISTFILE + the per-pane recorder) and the
// ⌃R overlay in AppDelegate+CommandHistory.swift.

// Where a remembered command came from: the global shell history, or a specific
// pane's own scrollback (so an overlay row can show its source pane/cwd).
enum CommandSource: Equatable {
    case shellHistory
    case pane(cwd: String?)

    // The right-hand hint shown on the overlay row.
    var hint: String {
        switch self {
        case .shellHistory:
            return "history"
        case .pane(let cwd):
            if let cwd, !cwd.isEmpty { return (cwd as NSString).lastPathComponent }
            return "pane"
        }
    }
}

// One remembered command: the exact text plus where it was seen. Deduped by
// text across sources when the store merges them.
struct HistoryCommand: Equatable {
    let text: String
    let source: CommandSource
}

enum CommandHistory {
    // MARK: - Parsing zsh history

    // Parse a zsh history file into commands, most-recent-first, deduped
    // (keeping the most-recent occurrence). Handles the extended-history
    // `: <start>:<elapsed>;<command>` prefix and backslash-continued multi-line
    // entries; blank lines are dropped.
    static func parseZsh(_ text: String) -> [String] {
        var entries: [String] = []
        var current = ""
        var continuing = false

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { entries.append(trimmed) }
            current = ""
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if continuing {
                current += "\n" + line
            } else {
                current = stripExtendedPrefix(line)
            }
            // A logical zsh history entry spanning newlines escapes each with a
            // trailing backslash; strip it and keep gathering.
            if line.hasSuffix("\\") {
                current = String(current.dropLast())
                continuing = true
            } else {
                continuing = false
                flush()
            }
        }
        if continuing { flush() }

        return dedupMostRecentFirst(entries)
    }

    // ": 1700000000:0;git status" → "git status"; a plain line is returned as-is.
    // The metadata segment never contains ';', so the first one delimits it.
    static func stripExtendedPrefix(_ line: String) -> String {
        guard line.hasPrefix(":"), let semi = line.firstIndex(of: ";") else { return line }
        return String(line[line.index(after: semi)...])
    }

    // File order is oldest-first, so reverse it (newest-first) and drop later
    // duplicates — each command appears once, at its most-recent position.
    static func dedupMostRecentFirst(_ entries: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in entries.reversed() where seen.insert(entry).inserted {
            out.append(entry)
        }
        return out
    }

    // MARK: - Merging sources

    // Merge per-pane recorded commands (already most-recent-first) with the
    // global shell history into one deduped, most-recent-first list. A command
    // seen in a pane keeps that (more specific) attribution; the pane list leads
    // because those are the commands from this session, freshest of all.
    static func merged(pane: [HistoryCommand], shell: [String]) -> [HistoryCommand] {
        var seen = Set<String>()
        var out: [HistoryCommand] = []
        for command in pane where seen.insert(command.text).inserted {
            out.append(command)
        }
        for text in shell where seen.insert(text).inserted {
            out.append(HistoryCommand(text: text, source: .shellHistory))
        }
        return out
    }

    // MARK: - Ranking (the overlay's type-to-filter)

    // Rank commands against a query with the shared fuzzy scorer — the exact
    // ranking the palette-backed overlay shows. Ties keep input order (so an
    // empty query stays most-recent-first). Non-matches drop out.
    static func rank(_ commands: [HistoryCommand], query: String) -> [HistoryCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        var scored: [(command: HistoryCommand, score: Int, order: Int)] = []
        for (order, command) in commands.enumerated() {
            if let score = fuzzyScore(query: trimmed, candidate: command.text) {
                scored.append((command, score, order))
            }
        }
        scored.sort { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }
        return scored.map { $0.command }
    }

    // MARK: - Destructive-command detection

    // curl/wget piped straight into a shell — the same bar as the terminal's
    // paste-safety check (PaneTerminalView), so pulling such a line out of
    // history and running it prompts just as a paste would.
    private static let pipeToShellPattern = try? NSRegularExpression(
        pattern: #"\b(curl|wget)\b[^\n]*\|\s*(sudo\s+)?(sh|bash|zsh|python[0-9.]*|perl|ruby|node)\b"#,
        options: [.caseInsensitive]
    )

    // A human reason when a command looks dangerous enough to confirm before
    // submitting, else nil: curl/wget-into-a-shell, or a recursive-and-forced
    // remove (`rm -rf` in any flag spelling). Edit-before-run never trips this —
    // nothing is submitted, so there's nothing to guard.
    static func destructiveWarning(for command: String) -> String? {
        let range = NSRange(command.startIndex..., in: command)
        if let pipeToShellPattern,
           pipeToShellPattern.firstMatch(in: command, range: range) != nil {
            return "This downloads and immediately runs a script (curl/wget piped into a shell)."
        }
        if looksLikeRecursiveForceRemove(command) {
            return "This looks like a recursive, forced delete (rm -rf) — it can wipe a directory tree with no undo."
        }
        return nil
    }

    // `rm` invoked with both a recursive (-r/-R/--recursive) and a force
    // (-f/--force) flag, however the flags are spelled or bundled (`rm -rf`,
    // `rm -fr`, `rm -r -f`, `rm --recursive --force`). Scans whitespace tokens
    // so it doesn't false-positive on words merely containing "rm".
    static func looksLikeRecursiveForceRemove(_ command: String) -> Bool {
        let tokens = command.split { $0 == " " || $0 == "\t" }.map(String.init)
        guard let rm = tokens.firstIndex(where: { $0 == "rm" || $0.hasSuffix("/rm") }) else { return false }
        var recursive = false
        var force = false
        for token in tokens[(rm + 1)...] {
            guard token.hasPrefix("-") else { continue }
            if token == "--recursive" { recursive = true; continue }
            if token == "--force" { force = true; continue }
            guard token.hasPrefix("-"), !token.hasPrefix("--") else { continue }
            let flags = token.dropFirst()
            if flags.contains("r") || flags.contains("R") { recursive = true }
            if flags.contains("f") { force = true }
        }
        return recursive && force
    }

    // MARK: - Running a picked command

    // Bracketed-paste framing, shared with SessionControl.send: an embedded
    // newline stays one input-box unit rather than submitting at the first \n.
    static let pasteStart = "\u{1b}[200~"
    static let pasteEnd = "\u{1b}[201~"

    // The exact byte string typed into the target pty for a picked command:
    // bracketed-paste-wrapped, followed by a CR only when submitting. Run
    // (submit == true) appends the CR so the command executes; edit-before-run
    // (⇧Enter, submit == false) omits it, leaving the command in the input box
    // unsubmitted — the SSH-restore pre-type path.
    static func payload(command: String, submit: Bool) -> String {
        pasteStart + command + pasteEnd + (submit ? "\r" : "")
    }
}
