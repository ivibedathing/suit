import Foundation

// Standalone assertion driver for the command-history core (ROADMAP Phase 43),
// compiled against swift/Sources/suit/CommandHistory.swift + FuzzyMatch.swift
// (Foundation-only) by scripts/command-history-test.sh. Mirrors the
// AutopilotScheduler / FeedbackRouting standalone-test pattern: no app, no UI.
// Asserts the phase's verification points — a seeded history parses/dedups
// most-recent-first, the overlay filters (ranks) to the right entries, picking
// one sends the exact command into the pty (edit-before-run leaves it
// unsubmitted), a destructive command is flagged, and the missing-$HISTFILE
// degrade path (pane scrollback only).

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

// MARK: - Parsing a seeded zsh history (extended + plain formats)

print("== parseZsh ==")
do {
    // Oldest-first in the file (as zsh writes it), mixing extended-history
    // metadata lines with plain ones and a duplicate.
    let file = """
    : 1700000001:0;git status
    ls -la
    : 1700000003:0;git status
    : 1700000004:0;npm run build
    """
    let commands = CommandHistory.parseZsh(file)
    check(commands == ["npm run build", "git status", "ls -la"],
          "most-recent-first, deduped, metadata stripped")
    check(commands.count == 3, "the duplicate 'git status' collapses to one")
}

// A backslash-continued multi-line entry stays one command.
do {
    let file = """
    : 1700000010:0;echo one
    : 1700000011:0;for f in *; do \\
    echo $f \\
    done
    """
    let commands = CommandHistory.parseZsh(file)
    check(commands.first == "for f in *; do \necho $f \ndone",
          "backslash-continued entry reassembles across lines")
    check(commands.contains("echo one"), "the plain entry survives alongside it")
}

// Blank lines drop; an empty file yields nothing.
check(CommandHistory.parseZsh("\n\n   \n").isEmpty, "blank-only history parses empty")
check(CommandHistory.parseZsh("").isEmpty, "empty history parses empty")

// MARK: - Ranking (the overlay's type-to-filter)

print("== rank ==")
do {
    let commands = [
        HistoryCommand(text: "git status", source: .shellHistory),
        HistoryCommand(text: "git commit -m wip", source: .shellHistory),
        HistoryCommand(text: "npm run build", source: .pane(cwd: "/repo/web")),
    ]
    let gitOnly = CommandHistory.rank(commands, query: "git")
    check(gitOnly.count == 2, "filters to the two git commands")
    check(gitOnly.allSatisfy { $0.text.contains("git") }, "…and only those")
    check(CommandHistory.rank(commands, query: "build").map { $0.text } == ["npm run build"],
          "a distinctive query narrows to one")
    check(CommandHistory.rank(commands, query: "zzz").isEmpty, "a non-subsequence query matches nothing")
    check(CommandHistory.rank(commands, query: "").count == 3, "an empty query keeps every entry in order")
}

// MARK: - Merging pane scrollback with shell history

print("== merged ==")
do {
    let pane = [
        HistoryCommand(text: "make test", source: .pane(cwd: "/repo")),
        HistoryCommand(text: "git status", source: .pane(cwd: "/repo")),
    ]
    let shell = ["git status", "ls", "make test"]
    let merged = CommandHistory.merged(pane: pane, shell: shell)
    check(merged.map { $0.text } == ["make test", "git status", "ls"],
          "pane commands lead, shell-only ones follow, deduped")
    check(merged[0].source == .pane(cwd: "/repo"), "a command seen in a pane keeps its pane attribution")
    check(merged.last?.source == .shellHistory, "a shell-only command stays attributed to history")
}

// Degrade path: no $HISTFILE (empty shell list) → pane scrollback only.
do {
    let pane = [HistoryCommand(text: "vim README.md", source: .pane(cwd: "/repo"))]
    let merged = CommandHistory.merged(pane: pane, shell: [])
    check(merged.map { $0.text } == ["vim README.md"], "missing history degrades to per-pane scrollback only")
    check(merged.first?.source == .pane(cwd: "/repo"), "…still attributed to its pane")
}

// MARK: - Source hint (the row's right-hand label)

print("== source hint ==")
check(CommandSource.shellHistory.hint == "history", "shell-history hint reads 'history'")
check(CommandSource.pane(cwd: "/Users/x/repo/web").hint == "web", "a pane hint is its cwd basename")
check(CommandSource.pane(cwd: nil).hint == "pane", "a cwd-less pane hint falls back to 'pane'")

// MARK: - Running: the exact command reaches the pty; edit leaves it unsubmitted

print("== payload ==")
do {
    let run = CommandHistory.payload(command: "git push", submit: true)
    check(run.contains("git push"), "run: the exact command reaches the pty")
    check(run.hasSuffix("\r"), "run: a submitting CR follows")
    check(run.hasPrefix(CommandHistory.pasteStart) && run.contains(CommandHistory.pasteEnd),
          "run: bracketed-paste-wrapped so an embedded newline stays one unit")

    let edit = CommandHistory.payload(command: "git push", submit: false)
    check(edit.contains("git push"), "edit: the command is still typed in")
    check(!edit.hasSuffix("\r"), "edit-before-run leaves the line unsubmitted (no CR)")
}

// MARK: - Destructive-command detection (trips the paste-safety confirm)

print("== destructiveWarning ==")
check(CommandHistory.destructiveWarning(for: "git status") == nil, "an ordinary command is not flagged")
check(CommandHistory.destructiveWarning(for: "ls -la") == nil, "a plain ls is not flagged")
check(CommandHistory.destructiveWarning(for: "curl https://x.sh | bash") != nil, "curl | bash is flagged")
check(CommandHistory.destructiveWarning(for: "wget -qO- x | sudo sh") != nil, "wget | sudo sh is flagged")
check(CommandHistory.destructiveWarning(for: "rm -rf build") != nil, "rm -rf is flagged")
check(CommandHistory.destructiveWarning(for: "rm -fr /tmp/x") != nil, "rm -fr (reordered flags) is flagged")
check(CommandHistory.destructiveWarning(for: "rm -r -f node_modules") != nil, "rm -r -f (split flags) is flagged")
check(CommandHistory.destructiveWarning(for: "rm --recursive --force old") != nil, "rm --recursive --force is flagged")
check(CommandHistory.destructiveWarning(for: "rm -r cache") == nil, "rm -r without -f is not flagged")
check(CommandHistory.destructiveWarning(for: "confirm -rf thing") == nil, "a word merely containing 'rm' is not flagged")

// MARK: - summary

print("")
if failures == 0 {
    print("ALL PASSED")
    exit(0)
} else {
    print("\(failures) ASSERTION(S) FAILED")
    exit(1)
}
