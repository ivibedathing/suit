import Foundation

// Standalone assertion driver for the branch-actions core
// (swift/Sources/suit/GitBranchOps.swift, Foundation-only, no app deps),
// compiled and run by scripts/git-branch-ops-test.sh. Mirrors the
// RoadmapParser / FeedbackRouting / Recipes standalone-test pattern: no app,
// no UI, no repo on disk — just the argv composition and the guard rails.
//
// What matters here is that the argv can't drift into something destructive by
// accident: the assertions pin --ff-only on pull, the confirmations on the two
// actions that can lose work, and the exclusion rules that keep the delete menu
// from offering a branch git would refuse.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

// MARK: - parseTrack

print("== GitBranchOps.parseTrack ==")
let both = GitBranchOps.parseTrack("ahead 2, behind 1")
check(both.ahead == 2 && both.behind == 1 && !both.isGone, "\"ahead 2, behind 1\" → 2/1")
let aheadOnly = GitBranchOps.parseTrack("ahead 3")
check(aheadOnly.ahead == 3 && aheadOnly.behind == 0, "\"ahead 3\" → 3/0")
let behindOnly = GitBranchOps.parseTrack("behind 12")
check(behindOnly.ahead == 0 && behindOnly.behind == 12, "\"behind 12\" → 0/12")
check(GitBranchOps.parseTrack("").ahead == 0, "empty track → 0/0")
check(GitBranchOps.parseTrack("gone").isGone, "\"gone\" → isGone")
// git brackets the field unless nobracket is asked for; both forms must parse.
let bracketed = GitBranchOps.parseTrack("[ahead 1, behind 4]")
check(bracketed.ahead == 1 && bracketed.behind == 4, "bracketed form parses the same")
check(GitBranchOps.parseTrack("[gone]").isGone, "bracketed \"gone\" → isGone")

// MARK: - SyncState

print("== GitBranchOps.SyncState ==")
check(GitBranchOps.syncState(upstream: nil, track: "ahead 2") == .untracked,
      "no upstream → untracked regardless of the track field")
check(GitBranchOps.syncState(upstream: "", track: "") == .untracked, "empty upstream → untracked")

let diverged = GitBranchOps.syncState(upstream: "origin/main", track: "ahead 2, behind 1")
check(diverged.badge == "↑2 ↓1", "diverged badge is ↑2 ↓1")
check(diverged.isDiverged && diverged.hasDifference && diverged.hasUpstream, "diverged flags")

let ahead = GitBranchOps.syncState(upstream: "origin/main", track: "ahead 2")
check(ahead.badge == "↑2", "ahead-only badge is ↑2")
check(!ahead.isDiverged, "ahead-only is not diverged")

let behind = GitBranchOps.syncState(upstream: "origin/main", track: "behind 5")
check(behind.badge == "↓5", "behind-only badge is ↓5")

let synced = GitBranchOps.syncState(upstream: "origin/main", track: "")
check(synced.badge == "synced" && !synced.hasDifference, "in-sync badge is \"synced\"")

let gone = GitBranchOps.syncState(upstream: "origin/old", track: "gone")
check(gone.badge == "gone", "deleted upstream badge is \"gone\"")

check(GitBranchOps.SyncState.untracked.badge == "no remote", "untracked badge is \"no remote\"")
check(diverged.tooltip(branch: "main").contains("2 commits to push"), "tooltip spells out the push count")
check(diverged.tooltip(branch: "main").contains("1 commit to pull"), "tooltip singularizes one commit")
check(synced.tooltip(branch: "main").contains("up to date"), "in-sync tooltip says up to date")

// MARK: - Plans

print("== GitBranchOps.plan — argv ==")
check(GitBranchOps.plan(for: .fetch).commands == [["fetch", "--prune"]], "fetch prunes")
// The load-bearing one: a plain `git pull` on a diverged branch would create a
// merge commit nobody asked for. --ff-only makes it fail loudly instead.
check(GitBranchOps.plan(for: .pull).commands == [["pull", "--ff-only"]], "pull is fast-forward only")
check(GitBranchOps.plan(for: .pullRebase).commands == [["pull", "--rebase"]], "rebase pull is its own action")
check(GitBranchOps.plan(for: .push).commands == [["push"]], "push takes no refspec")
check(GitBranchOps.plan(for: .publish(branch: "feature/x")).commands
        == [["push", "--set-upstream", "origin", "feature/x"]], "publish sets the upstream")
// Untracked files must ride along, or a "get clean" stash leaves them behind.
check(GitBranchOps.plan(for: .stash).commands == [["stash", "push", "--include-untracked"]],
      "stash includes untracked files")
check(GitBranchOps.plan(for: .stashPop).commands == [["stash", "pop"]], "pop is a plain pop")
check(GitBranchOps.plan(for: .discardAll).commands == [["reset", "--hard", "HEAD"], ["clean", "-fd"]],
      "discard is reset --hard then clean -fd")
check(GitBranchOps.plan(for: .deleteBranch(name: "old", force: false)).commands == [["branch", "-d", "old"]],
      "safe delete uses -d")
check(GitBranchOps.plan(for: .deleteBranch(name: "old", force: true)).commands == [["branch", "-D", "old"]],
      "force delete uses -D")
check(GitBranchOps.plan(for: .createBranch(name: "feature/y")).commands == [["checkout", "-b", "feature/y"]],
      "new branch checks itself out")

// Nothing anywhere in the action set force-pushes or rewrites history.
print("== GitBranchOps.plan — no force-push, ever ==")
let everyAction: [GitBranchOps.Action] = [
    .fetch, .pull, .pullRebase, .push, .publish(branch: "b"), .stash, .stashPop,
    .discardAll, .deleteBranch(name: "b", force: true), .createBranch(name: "b"),
]
for action in everyAction {
    let flat = GitBranchOps.plan(for: action).commands.flatMap { $0 }
    check(!flat.contains("--force") && !flat.contains("-f") && !flat.contains("--force-with-lease"),
          "\(flat.first ?? "?") carries no force flag")
}

print("== GitBranchOps.plan — confirmations ==")
// The two that can destroy work must ask; nothing else may.
let mustConfirm: [GitBranchOps.Action] = [.discardAll, .deleteBranch(name: "old", force: true)]
for action in mustConfirm {
    let confirmation = GitBranchOps.plan(for: action).confirmation
    check(confirmation != nil, "\(action) is confirmed")
    check(confirmation?.isDestructive == true, "\(action) is flagged destructive")
    check(confirmation?.confirmButton.isEmpty == false, "\(action) names its confirm button")
}
let mustNotConfirm: [GitBranchOps.Action] = [
    .fetch, .pull, .pullRebase, .push, .publish(branch: "b"), .stash, .stashPop,
    .deleteBranch(name: "old", force: false), .createBranch(name: "b"),
]
for action in mustNotConfirm {
    check(GitBranchOps.plan(for: action).confirmation == nil, "\(action) runs without a prompt")
}
check(GitBranchOps.plan(for: .discardAll).confirmation?.informativeText.contains("stash") == true,
      "the discard warning points at stashing instead")

print("== GitBranchOps.plan — working-tree flag ==")
for action in [GitBranchOps.Action.pull, .stash, .stashPop, .discardAll, .createBranch(name: "b")] {
    check(GitBranchOps.plan(for: action).touchesWorkingTree, "\(action) rescans the file index")
}
for action in [GitBranchOps.Action.fetch, .push, .publish(branch: "b"), .deleteBranch(name: "b", force: false)] {
    check(!GitBranchOps.plan(for: action).touchesWorkingTree, "\(action) leaves the tree alone")
}

// MARK: - Branch-name validation

print("== GitBranchOps.validateBranchName ==")
for good in ["main", "feature/tab-drag", "bugfix/issue-12", "v2.1", "a_b-c"] {
    check(GitBranchOps.validateBranchName(good) == nil, "\"\(good)\" is accepted")
}
for bad in ["", "   ", "-x", "/x", "x/", "x.", "x.lock", "a..b", "a//b", "a@{b", "a b", "a~b", "a^b",
            "a:b", "a?b", "a*b", "a[b", "a\\b"] {
    check(GitBranchOps.validateBranchName(bad) != nil, "\"\(bad)\" is rejected")
}
check(GitBranchOps.validateBranchName("  main  ") == nil, "surrounding whitespace is trimmed, not rejected")

// MARK: - Deletable branches

print("== GitBranchOps.deletableBranches ==")
// git refuses to delete a branch any worktree has checked out, so neither the
// current branch nor one held by a sibling worktree may reach the menu.
let deletable = GitBranchOps.deletableBranches(
    all: ["main", "feature/a", "feature/b", "feature/c"],
    current: "main", checkedOutElsewhere: ["feature/b"]
)
check(deletable == ["feature/a", "feature/c"], "current and worktree-held branches are excluded")
check(GitBranchOps.deletableBranches(all: ["main"], current: "main", checkedOutElsewhere: []).isEmpty,
      "a single checked-out branch leaves nothing deletable")
check(GitBranchOps.deletableBranches(all: ["main", "x"], current: nil, checkedOutElsewhere: [])
        == ["main", "x"], "detached HEAD excludes nothing but the worktree-held set")
check(GitBranchOps.deletableBranches(all: [], current: "main", checkedOutElsewhere: []).isEmpty,
      "no branches → nothing to delete")

// MARK: - Upstream diff

print("== GitBranchOps.upstreamDiff ==")
// Three dots, upstream first: the diff is against the merge base, so upstream
// commits read as work to pull rather than as reverted local changes.
check(GitBranchOps.upstreamDiffArguments(branch: "main", upstream: "origin/main")
        == ["diff", "--stat", "--patch", "origin/main...main"], "diff range is upstream...branch")
check(GitBranchOps.upstreamDiffTitle(branch: "main", state: diverged) == "origin/main…main ↑2 ↓1",
      "the diff tab title carries the badge")
check(GitBranchOps.upstreamDiffTitle(branch: "main", state: synced) == "origin/main…main",
      "an in-sync title drops the badge")
check(GitBranchOps.upstreamDiffTitle(branch: "main", state: .untracked) == "diff: main",
      "no upstream falls back to a plain title")

print(failures == 0 ? "\nAll branch-ops assertions passed." : "\n\(failures) assertion(s) FAILED.")
exit(failures == 0 ? 0 : 1)
