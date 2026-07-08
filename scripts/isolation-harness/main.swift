import Foundation

// Assertion driver for the Phase 31 pure logic: the per-task isolation
// decision (TaskLaunch) and the subagent tree (SubagentTree). Mirrors the
// mode-plan / feedback-routing harness convention — print OBSERVE lines, exit
// nonzero on the first failure.

var failures = 0
func check(_ condition: Bool, _ label: String) {
    if condition { print("OBSERVE ok: \(label)") }
    else { print("OBSERVE FAIL: \(label)"); failures += 1 }
}

// MARK: - Isolation decision (creates a task with isolation on and off,
// asserting the right checkout is used).

let repo = "/repo"
let taskWorktree = "/repo/.claude/worktrees/task-a"

check(TaskLaunch.usesWorktree(isolate: true), "isolate on → uses a worktree")
check(!TaskLaunch.usesWorktree(isolate: false), "isolate off → no worktree")

check(
    TaskLaunch.checkoutDirectory(isolate: true, currentRoot: repo, worktreeDirectory: taskWorktree) == taskWorktree,
    "isolate on → runs claude in the fresh worktree"
)
check(
    TaskLaunch.checkoutDirectory(isolate: false, currentRoot: repo, worktreeDirectory: nil) == repo,
    "isolate off → runs claude in the current checkout"
)
check(
    TaskLaunch.checkoutDirectory(isolate: true, currentRoot: repo, worktreeDirectory: nil) == repo,
    "isolate on but no worktree made → falls back to the checkout root"
)

// MARK: - Subagent tree (seed a session with two subagent worktrees; assert
// they render nested under the parent, and disappear when removed).

let sub1 = "/repo/.claude/worktrees/task-a/.claude/worktrees/sub1"
let sub2 = "/repo/.claude/worktrees/task-a/.claude/worktrees/sub2"

let parent = SubagentTreeSession(id: "parent", cwd: taskWorktree, state: "working")
// git worktree list reports the main checkout + the parent + both subagents.
let allWorktrees = [
    SubagentTreeWorktree(path: repo, branch: "main"),
    SubagentTreeWorktree(path: taskWorktree, branch: "task/task-a"),
    SubagentTreeWorktree(path: sub1, branch: "sub-1"),
    SubagentTreeWorktree(path: sub2, branch: "sub-2"),
]

let roots = SubagentTree.build(sessions: [parent], worktrees: allWorktrees)
check(roots.count == 1, "one root (the parent session; the main checkout is transparent)")
check(roots.first?.sessionId == "parent", "the root is the parent session, not the containing repo")
let children = roots.first?.children ?? []
check(children.count == 2, "two subagent worktrees nested under the parent")
check(children.map { $0.name }.sorted() == ["sub1", "sub2"], "both subagents present by name")
check(children.allSatisfy { $0.sessionId == nil }, "session-less subagent worktrees render as bare nodes")
check(children.first(where: { $0.name == "sub1" })?.branch == "sub-1", "a subagent carries its branch")

let flat = SubagentTree.flatten(roots)
check(flat.count == 3, "flatten yields parent + two subagents")
check(flat.first?.depth == 0, "parent at depth 0")
check(flat.filter { $0.node.sessionId == nil }.allSatisfy { $0.depth == 1 }, "subagents indented one level")

// Pruning: Claude Code auto-removes the finished subagent worktrees, so they
// drop out of the worktree list — and out of the tree.
let afterPrune = SubagentTree.build(
    sessions: [parent],
    worktrees: [
        SubagentTreeWorktree(path: repo, branch: "main"),
        SubagentTreeWorktree(path: taskWorktree, branch: "task/task-a"),
    ]
)
check(afterPrune.first?.children.isEmpty == true, "removed subagent worktrees disappear from the tree")

// A subagent that has its own live session nests as a session node (not bare).
let nestedSession = SubagentTreeSession(id: "child", cwd: sub1, state: "needs-input")
let withNested = SubagentTree.build(sessions: [parent, nestedSession], worktrees: allWorktrees)
let nestedChild = withNested.first?.children.first(where: { $0.name == "sub1" })
check(withNested.count == 1, "the child session does not appear as a second root")
check(nestedChild?.sessionId == "child", "a subagent with a session nests as that session")
check(nestedChild?.state == "needs-input", "the nested session carries its state")

// A session running in the main checkout with one subagent: the session is the
// root, the subagent its child.
let mainSession = SubagentTreeSession(id: "main", cwd: repo, state: "working")
let mainSub = "/repo/.claude/worktrees/solo"
let mainRoots = SubagentTree.build(
    sessions: [mainSession],
    worktrees: [SubagentTreeWorktree(path: repo, branch: "main"),
                SubagentTreeWorktree(path: mainSub, branch: "solo")]
)
check(mainRoots.count == 1 && mainRoots.first?.sessionId == "main", "a main-checkout session is a root")
check(mainRoots.first?.children.map { $0.name } == ["solo"], "its subagent nests under it")

if failures == 0 { print("OBSERVE ALL PASS"); exit(0) }
else { print("OBSERVE \(failures) FAILURE(S)"); exit(1) }
