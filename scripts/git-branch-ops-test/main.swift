import Foundation

// Standalone assertion driver for the branch-actions core
// (swift/Sources/suit/GitBranchOps.swift, Foundation-only, no app deps),
// compiled and run by scripts/git-branch-ops-test.sh. Mirrors the
// FeedbackRouting / Recipes standalone-test pattern: no app,
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

// MARK: - Staging (the Source Control tab's index actions)

print("== GitBranchOps.plan — staging ==")
// Every pathspec-carrying action puts `--` before the paths, or a file named
// "-f" would be read as a flag by the command about to act on it.
check(GitBranchOps.plan(for: .stage(paths: ["a.swift", "b.swift"])).commands
        == [["add", "--", "a.swift", "b.swift"]], "stage adds after a -- separator")
check(GitBranchOps.plan(for: .unstage(paths: ["a.swift"])).commands
        == [["restore", "--staged", "--", "a.swift"]], "unstage touches the index only")
check(GitBranchOps.plan(for: .stageAll).commands == [["add", "-A"]], "stage-all is add -A")
// A bare mixed reset: no --hard anywhere near it, or unstaging would silently
// throw the edits away.
check(GitBranchOps.plan(for: .unstageAll).commands == [["reset", "--quiet"]], "unstage-all is a mixed reset")
check(!GitBranchOps.plan(for: .unstageAll).commands.flatMap { $0 }.contains("--hard"),
      "unstage-all never resets --hard")
for action in [GitBranchOps.Action.stage(paths: ["a"]), .unstage(paths: ["a"]), .stageAll, .unstageAll] {
    check(GitBranchOps.plan(for: action).confirmation == nil, "\(action) runs without a prompt")
    check(!GitBranchOps.plan(for: action).touchesWorkingTree, "\(action) leaves the tree alone")
}

print("== GitBranchOps.plan — per-file discard ==")
// Tracked files are restored, untracked ones deleted — two different commands,
// and asking `restore` for a path it has never seen would fail the whole plan.
let discardTracked = GitBranchOps.plan(for: .discardPaths(tracked: ["a.swift"], untracked: []))
check(discardTracked.commands == [["restore", "--staged", "--worktree", "--", "a.swift"]],
      "a tracked discard restores index and worktree")
let discardUntracked = GitBranchOps.plan(for: .discardPaths(tracked: [], untracked: ["new.swift"]))
check(discardUntracked.commands == [["clean", "-fd", "--", "new.swift"]],
      "an untracked discard cleans just that path")
let discardBoth = GitBranchOps.plan(for: .discardPaths(tracked: ["a.swift"], untracked: ["new.swift"]))
check(discardBoth.commands.count == 2, "a mixed discard runs both commands")
// The load-bearing one: an empty list must compose *no* command, because a
// pathspec-less `clean -fd` would wipe every untracked file in the repo.
check(GitBranchOps.plan(for: .discardPaths(tracked: [], untracked: [])).commands.isEmpty,
      "discarding nothing composes no command at all")
check(discardTracked.confirmation?.isDestructive == true, "a per-file discard is confirmed as destructive")
check(discardTracked.confirmation?.messageText.contains("a.swift") == true,
      "the confirmation names the file it is about to revert")
check(discardBoth.confirmation?.messageText.contains("2 files") == true,
      "a multi-file discard counts them instead")
check(discardTracked.touchesWorkingTree, "a discard rescans the file index")

// MARK: - Commit

print("== GitBranchOps.plan — commit ==")
check(GitBranchOps.plan(for: .commit(.init(message: "Fix the thing"))).commands
        == [["commit", "-m", "Fix the thing"]], "a plain commit is commit -m")
check(GitBranchOps.plan(for: .commit(.init(message: "msg", stageAll: true))).commands
        == [["add", "-A"], ["commit", "-m", "msg"]], "stageAll stages before committing")
check(GitBranchOps.plan(for: .commit(.init(message: "msg", push: true))).commands
        == [["commit", "-m", "msg"], ["push"]], "push follows the commit")
check(GitBranchOps.plan(for: .commit(.init(message: "msg", stageAll: true, push: true))).commands
        == [["add", "-A"], ["commit", "-m", "msg"], ["push"]], "the full sequence keeps its order")
check(GitBranchOps.plan(for: .commit(.init(message: "new subject", amend: true))).commands
        == [["commit", "--amend", "-m", "new subject"]], "amend with a message rewrites it")
// Empty + amend means "keep the previous message" — the one case where an
// empty message is legal, and --no-edit is what stops git opening an editor
// this app has no terminal to host.
check(GitBranchOps.plan(for: .commit(.init(message: "  ", amend: true))).commands
        == [["commit", "--amend", "--no-edit"]], "an empty amend keeps the previous message")
check(GitBranchOps.plan(for: .commit(.init(message: "  padded  "))).commands
        == [["commit", "-m", "padded"]], "the message is trimmed before it becomes argv")
check(GitBranchOps.plan(for: .commit(.init(message: "m"))).confirmation == nil, "committing asks nothing")
check(GitBranchOps.plan(for: .commit(.init(message: "m", amend: true))).failureTitle == "Amend Failed",
      "an amend failure is named as one")
// Nothing in the commit path may force: an amend of something already pushed
// must fail at the push, loudly, rather than rewrite the remote.
let commitArgv = GitBranchOps.plan(for: .commit(.init(message: "m", amend: true, push: true)))
    .commands.flatMap { $0 }
check(!commitArgv.contains("--force") && !commitArgv.contains("--force-with-lease") && !commitArgv.contains("-f"),
      "amend + push never forces")

print("== GitBranchOps.validateCommitMessage ==")
check(GitBranchOps.validateCommitMessage("Fix it") == nil, "a real message passes")
check(GitBranchOps.validateCommitMessage("") != nil, "an empty message is refused")
check(GitBranchOps.validateCommitMessage("   \n\t ") != nil, "whitespace is not a message")
check(GitBranchOps.validateCommitMessage("", amend: true) == nil, "amending may leave it empty")

print("== GitBranchOps.commitButtonTitle ==")
// The title has to carry the behaviour: with nothing staged, committing stages
// everything, and the button says so rather than looking like a no-op.
check(GitBranchOps.commitButtonTitle(stagedCount: 3, unstagedCount: 0, amend: false) == "Commit 3",
      "staged files are counted")
check(GitBranchOps.commitButtonTitle(stagedCount: 0, unstagedCount: 5, amend: false) == "Commit All 5",
      "nothing staged reads as commit-all")
check(GitBranchOps.commitButtonTitle(stagedCount: 0, unstagedCount: 0, amend: false) == "Commit",
      "a clean tree leaves a bare title")
check(GitBranchOps.commitButtonTitle(stagedCount: 2, unstagedCount: 0, amend: true) == "Amend Commit",
      "amend renames the button")
check(GitBranchOps.commitButtonTitle(stagedCount: 0, unstagedCount: 0, amend: true) == "Amend Message",
      "amending a clean tree only touches the message")

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

// MARK: - Remote state

print("== GitBranchOps.remoteState ==")
// The real shape of `for-each-ref --format=%(refname:short) refs/remotes`:
// short names, and refs/remotes/origin/HEAD collapses to a bare "origin".
let refs: Set<String> = ["origin", "origin/main", "origin/feature/a", "upstream/main"]
check(GitBranchOps.remoteState(branch: "main", upstream: "origin/main", remoteRefs: refs) == .published,
      "a tracked branch whose upstream ref exists is published")
// The whole reason this reads refs rather than tracking config: pushed without
// -u, or cloned by someone else, and the branch is still on the remote.
check(GitBranchOps.remoteState(branch: "feature/a", upstream: nil, remoteRefs: refs) == .published,
      "an untracked branch matching a remote ref is published")
check(GitBranchOps.remoteState(branch: "feature/b", upstream: nil, remoteRefs: refs) == .localOnly,
      "an untracked branch with no matching ref is local-only")
check(GitBranchOps.remoteState(branch: "old", upstream: "origin/old", remoteRefs: refs) == .gone,
      "a configured upstream with no ref is gone")
// The remote is split off at the first slash, so a short branch name can't
// claim a nested ref by suffix.
check(GitBranchOps.remoteState(branch: "a", upstream: nil, remoteRefs: refs) == .localOnly,
      "branch \"a\" does not match origin/feature/a")
check(GitBranchOps.remoteState(branch: "main", upstream: nil, remoteRefs: ["upstream/main"]) == .published,
      "any remote counts, not just origin")
check(GitBranchOps.remoteState(branch: "main", upstream: "", remoteRefs: refs) == .published,
      "an empty upstream string is treated as untracked, not as a missing ref")
check(GitBranchOps.remoteState(branch: "main", upstream: nil, remoteRefs: []) == .localOnly,
      "no remotes at all → local-only")
// The bare "origin" HEAD alias has no slash to split on; it must not crash or
// claim a local branch called "origin".
check(GitBranchOps.remoteState(branch: "origin", upstream: nil, remoteRefs: refs) == .localOnly,
      "the bare \"origin\" HEAD alias matches no branch")

print("== GitBranchOps.remoteStatePhrase ==")
check(GitBranchOps.remoteStatePhrase(.published, upstream: "origin/main") == "on origin/main",
      "a tracked published branch names its upstream")
check(GitBranchOps.remoteStatePhrase(.published, upstream: nil).contains("not tracked"),
      "a published branch with no upstream says so")
check(GitBranchOps.remoteStatePhrase(.localOnly, upstream: nil).contains("never pushed"),
      "local-only reads as never pushed")
check(GitBranchOps.remoteStatePhrase(.gone, upstream: "origin/old").hasPrefix("origin/old"),
      "gone names the upstream that vanished")

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
