import Cocoa

// Source Control refresh-gate test.
//
// The Git tab's branch list, feedback gather and two `gh pr list` passes all
// shell out — the gh ones over the network — and are drawn nowhere but that
// tab. They used to run off every filesystem event, so a build or a busy agent
// kept them permanently in flight; that was the app's largest CPU cost by a
// wide margin. They now run only when something happened that could have
// changed them: the tab was revealed, the repo or branch changed, or the user
// asked.
//
// That gate is only correct if the data still arrives, so this asserts both
// halves — the work that must NOT happen, and the data that must.
//
// Unlike the other harnesses this one drives the real AppDelegate offscreen
// (the pattern design/reference/main.swift uses): the behaviour under test is
// the wiring between FSEvents, FileIndex, GitStatusMonitor, SidebarView and
// GitView, which is precisely what a UI-free core extraction would throw away.
//
// argv: <repo path> <gh stub log path>

let repo = CommandLine.arguments[1]
let ghLog = CommandLine.arguments[2]

func ghCalls() -> Int {
    (try? String(contentsOfFile: ghLog, encoding: .utf8))?
        .split(separator: "\n").count ?? 0
}

func pump(_ seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
}

var failures = 0
func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    let suffix = detail.isEmpty ? "" : " (\(detail))"
    if condition {
        print("ok: \(label)\(suffix)")
    } else {
        failures += 1
        print("FAIL: \(label)\(suffix)")
    }
}

// Writes into the ignored build tree stand in for a compile; writes to files
// under src/ stand in for an agent editing code. Both happen constantly while
// several sessions share a checkout.
func churn(_ iterations: Int, sourceFile: String, objectFile: String) {
    for i in 1...iterations {
        try? "let v = \(i)\n".write(toFile: repo + "/src/" + sourceFile, atomically: true, encoding: .utf8)
        try? "obj \(i)\n".write(toFile: repo + "/build/" + objectFile, atomically: true, encoding: .utf8)
        pump(0.1)
    }
}

_ = NSApplication.shared
NSApp.appearance = NSAppearance(named: .darkAqua)

// A raw, unbundled binary's UserDefaults still resolve against the real home —
// NSHomeDirectory() reads the password database, not $HOME — so state left by a
// previous run, or by another agent's harness running right now, is visible
// here even though ~/.suit is sandboxed. A stale pinned sidebar root points the
// Files tree (and with it the Git tab) at somebody else's fixture, which shows
// up as "no repository" and would let every must-not-run assertion below pass
// for entirely the wrong reason. Clear what this test steers with.
UserDefaults.standard.removeObject(forKey: "sidebarPinnedRoot")
UserDefaults.standard.set(repo, forKey: "lastWorkingDirectory")
// The panel has to be open or every tab reads as hidden, and a broken gate
// would pass by accident.
UserDefaults.standard.set(true, forKey: "sidebarVisible")
// Start on Files so the Git tab is genuinely hidden for the first assertions.
UserDefaults.standard.set(SidebarView.Tab.files.rawValue, forKey: "sidebarTab")

let delegate = AppDelegate()
delegate.newWindow(nil)
guard let controller = NSApp.windows.compactMap({ $0.delegate as? TerminalWindowController }).first else {
    FileHandle.standardError.write(Data("no window controller\n".utf8))
    exit(1)
}
controller.window.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 800), display: true)
pump(3.0)

let git = controller.sidebar.gitView

// The tab is useless without a repo behind it, and "no repository" would make
// every no-work assertion below pass for the wrong reason.
check("tab resolved the fixture repo",
      git.gitRoot != nil,
      "gitRoot = \(git.gitRoot ?? "nil"), argv repo = \(repo),"
      + " FileIndex.gitRoot = \(FileIndex.gitRoot(of: repo) ?? "nil"),"
      + " browser root = \(controller.sidebar.fileBrowser.rootPath)")

// --- Hidden: none of the shelling-out happens -------------------------------
check("Git tab starts hidden", !git.isShowing)
check("hidden tab runs no gh passes", ghCalls() == 0, "gh calls = \(ghCalls())")

churn(20, sourceFile: "file1.swift", objectFile: "obj1.o")
pump(2.0)
check("file churn on a hidden tab runs no gh passes", ghCalls() == 0,
      "gh calls = \(ghCalls())")

// --- Revealed: the data the tab draws actually arrives -----------------------
controller.sidebar.select(tab: .git)
pump(4.0)
check("revealed tab is showing", git.isShowing)
check("reveal runs the gh passes exactly once", ghCalls() == 3,
      "gh calls = \(ghCalls()), want 3 — two inbox searches plus one pr list")
check("branch rows loaded on reveal", !git.branches.isEmpty,
      "branches = \(git.branches.count)")

// A brand-new file changes the file index's path list.
try? "brand new\n".write(toFile: repo + "/src/added.swift", atomically: true, encoding: .utf8)
pump(4.0)
check("new untracked file reaches the shown rows",
      git.unstagedPaths.contains("src/added.swift"),
      "unstaged = \(git.unstagedPaths.sorted())")

// --- The asymmetry that a naive "skip unchanged scans" gets wrong ------------
//
// src/file2.swift is already tracked and committed, so editing it changes
// `git status` while leaving the file index's list of paths identical. Gating
// the status monitor on "the file list moved" therefore stops Source Control
// noticing ordinary edits — the single most common thing that happens in a
// repo — and a new-file check sails straight past the bug. Hence both.
let ghBeforeReChurn = ghCalls()
churn(20, sourceFile: "file2.swift", objectFile: "obj2.o")

let settleStart = Date()
var settled = -1.0
while Date().timeIntervalSince(settleStart) < 15 {
    pump(0.25)
    if git.unstagedPaths.contains("src/file2.swift") {
        settled = Date().timeIntervalSince(settleStart)
        break
    }
}

check("churn on a visible tab does not re-run the gh passes",
      ghCalls() == ghBeforeReChurn,
      "gh calls \(ghBeforeReChurn) -> \(ghCalls())")
check("edits to an already-tracked file still reach the rows",
      settled >= 0,
      settled >= 0 ? String(format: "caught up %.1fs after churn stopped", settled)
                   : "never caught up in 15s; unstaged = \(git.unstagedPaths.sorted())")

print(failures == 0
      ? "\nall source-control gate assertions passed"
      : "\n\(failures) assertion(s) failed")
exit(failures == 0 ? 0 : 1)
