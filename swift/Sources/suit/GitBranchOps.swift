import Foundation

// The UI-free half of the Files-tab branch actions: what "pull", "stash",
// "discard everything" and friends actually *are* as git argv, which of them
// need a confirmation before they destroy work, and how a branch's position
// relative to its upstream reads as a badge.
//
// It exists as its own Foundation-only file for the usual reason (see
// CLAUDE.md): the argv and the guard rails are the part worth testing, and a
// harness can compile this alone — no AppKit, no `runProcess`, no repo. The
// AppKit half (`ProjectHeaderView` for the menu, `TerminalWindowController+
// GitActions` for the running and the alerts) holds no policy of its own; it
// asks for a `Plan` and executes it.
//
// Two rules shape the argv choices here:
//
//   * Nothing silently rewrites history or merges. `pull` is `--ff-only`, so a
//     diverged branch fails loudly with git's own message instead of producing
//     a surprise merge commit; the rebase variant is a separate, explicit item.
//   * Anything that can lose uncommitted work carries a `Confirmation` with
//     `isDestructive` set. The caller may not skip it — that's the whole point
//     of the type — and the copy names what is about to be thrown away.
enum GitBranchOps {

    // MARK: - Upstream tracking

    // Where a branch sits relative to the remote branch it tracks. Built from
    // `%(upstream:short)` + `%(upstream:track,nobracket)` in one for-each-ref
    // pass — no rev-list per branch.
    struct SyncState: Equatable {
        var upstream: String?
        var ahead: Int
        var behind: Int
        // The upstream ref is configured but no longer exists on the remote
        // (git says "gone") — a branch whose remote was deleted after a merge.
        var isGone: Bool

        static let untracked = SyncState(upstream: nil, ahead: 0, behind: 0, isGone: false)

        var hasUpstream: Bool { upstream != nil }
        var hasDifference: Bool { ahead > 0 || behind > 0 }
        var isDiverged: Bool { ahead > 0 && behind > 0 }

        // The short label on the branch row's sync button. Arrows follow git's
        // own convention (↑ = commits only we have, ↓ = commits only they have).
        var badge: String {
            if isGone { return "gone" }
            guard hasUpstream else { return "no remote" }
            if ahead > 0 && behind > 0 { return "↑\(ahead) ↓\(behind)" }
            if ahead > 0 { return "↑\(ahead)" }
            if behind > 0 { return "↓\(behind)" }
            return "synced"
        }

        // The button's tooltip — the badge spelled out, plus what clicking does
        // when there is in fact a diff to show.
        func tooltip(branch: String) -> String {
            if isGone {
                return "\(branch) tracks \(upstream ?? "a remote branch"), which no longer exists on the remote."
            }
            guard let upstream else {
                return "\(branch) doesn’t track a remote branch yet — use Publish Branch to push it."
            }
            if !hasDifference {
                return "\(branch) is up to date with \(upstream)."
            }
            var parts: [String] = []
            if ahead > 0 { parts.append("\(ahead) commit\(ahead == 1 ? "" : "s") to push") }
            if behind > 0 { parts.append("\(behind) commit\(behind == 1 ? "" : "s") to pull") }
            return "\(branch) vs \(upstream): \(parts.joined(separator: ", ")) — click to see the diff."
        }
    }

    // "ahead 2, behind 1" / "ahead 3" / "behind 2" / "gone" / "" → counts.
    // git prints this with brackets unless `nobracket` is asked for; strip them
    // anyway so either form parses.
    static func parseTrack(_ track: String) -> (ahead: Int, behind: Int, isGone: Bool) {
        let cleaned = track.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t\n"))
        if cleaned == "gone" { return (0, 0, true) }
        var ahead = 0, behind = 0
        for part in cleaned.components(separatedBy: ",") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            if piece.hasPrefix("ahead ") { ahead = Int(piece.dropFirst(6)) ?? 0 }
            else if piece.hasPrefix("behind ") { behind = Int(piece.dropFirst(7)) ?? 0 }
        }
        return (ahead, behind, false)
    }

    static func syncState(upstream: String?, track: String) -> SyncState {
        guard let upstream, !upstream.isEmpty else { return .untracked }
        let parsed = parseTrack(track)
        return SyncState(upstream: upstream, ahead: parsed.ahead, behind: parsed.behind, isGone: parsed.isGone)
    }

    // MARK: - Actions

    enum Action: Equatable {
        case fetch
        case pull                                   // fast-forward only
        case pullRebase
        case push
        case publish(branch: String)                // first push, sets upstream
        case stash
        case stashPop
        case discardAll
        case deleteBranch(name: String, force: Bool)
        case createBranch(name: String)
    }

    // What the caller needs to run one action: the git argv (everything after
    // `git -C <root>`), the alert title to use if it fails, and the
    // confirmation to put in front of it when it can destroy work.
    struct Plan: Equatable {
        // Run in order; stop at the first failure. Only `discardAll` needs
        // more than one — a reset alone leaves untracked files behind.
        let commands: [[String]]
        // "Pull Failed" — the alert's messageText on a non-zero exit.
        let failureTitle: String
        let confirmation: Confirmation?
        // Whether the action can change which files are on disk, and so should
        // kick a file-index rescan rather than only a git-status refresh.
        let touchesWorkingTree: Bool
    }

    struct Confirmation: Equatable {
        let messageText: String
        let informativeText: String
        let confirmButton: String
        // Renders as a destructive (red) button and makes Cancel the default,
        // so Return doesn't throw work away.
        let isDestructive: Bool
    }

    static func plan(for action: Action) -> Plan {
        switch action {
        case .fetch:
            return Plan(
                commands: [["fetch", "--prune"]],
                failureTitle: "Fetch Failed", confirmation: nil, touchesWorkingTree: false
            )

        // --ff-only on purpose: a diverged branch stops with git's own
        // "not possible to fast-forward" rather than quietly merging.
        case .pull:
            return Plan(
                commands: [["pull", "--ff-only"]],
                failureTitle: "Pull Failed", confirmation: nil, touchesWorkingTree: true
            )

        case .pullRebase:
            return Plan(
                commands: [["pull", "--rebase"]],
                failureTitle: "Pull (Rebase) Failed", confirmation: nil, touchesWorkingTree: true
            )

        case .push:
            return Plan(
                commands: [["push"]],
                failureTitle: "Push Failed", confirmation: nil, touchesWorkingTree: false
            )

        // -u, never --force: publishing is for a branch that has no upstream
        // yet, and a plain push is the only safe way to make one.
        case .publish(let branch):
            return Plan(
                commands: [["push", "--set-upstream", "origin", branch]],
                failureTitle: "Publish Failed", confirmation: nil, touchesWorkingTree: false
            )

        // -u so untracked files ride along; without it a stash "to get clean"
        // leaves the new files sitting there and the next checkout still fails.
        case .stash:
            return Plan(
                commands: [["stash", "push", "--include-untracked"]],
                failureTitle: "Stash Failed", confirmation: nil, touchesWorkingTree: true
            )

        case .stashPop:
            return Plan(
                commands: [["stash", "pop"]],
                failureTitle: "Pop Stash Failed", confirmation: nil, touchesWorkingTree: true
            )

        // Two commands: reset --hard reverts tracked files, clean -fd removes
        // the untracked ones. Neither is recoverable, hence the confirmation.
        case .discardAll:
            return Plan(
                commands: [["reset", "--hard", "HEAD"], ["clean", "-fd"]],
                failureTitle: "Discard Failed",
                confirmation: Confirmation(
                    messageText: "Discard all local changes?",
                    informativeText: "Every uncommitted change in this worktree is reverted and every untracked file is deleted. This cannot be undone — stash instead if you might want them back.",
                    confirmButton: "Discard Changes", isDestructive: true
                ),
                touchesWorkingTree: true
            )

        // -d refuses to drop an unmerged branch, so the plain form needs no
        // confirmation; -D overrides that check and does need one.
        case .deleteBranch(let name, let force):
            return Plan(
                commands: [["branch", force ? "-D" : "-d", name]],
                failureTitle: "Delete Branch Failed",
                confirmation: force
                    ? Confirmation(
                        messageText: "Force-delete “\(name)”?",
                        informativeText: "This branch has commits that aren’t merged anywhere else. Deleting it leaves them unreachable.",
                        confirmButton: "Force Delete", isDestructive: true
                    )
                    : nil,
                touchesWorkingTree: false
            )

        case .createBranch(let name):
            return Plan(
                commands: [["checkout", "-b", name]],
                failureTitle: "New Branch Failed", confirmation: nil, touchesWorkingTree: true
            )
        }
    }

    // MARK: - Guard rails

    // git's own ref-name rules, checked up front so a typo produces a readable
    // sentence instead of `fatal: 'foo bar' is not a valid branch name`.
    // Returns the complaint, or nil when the name is usable.
    static func validateBranchName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Enter a branch name." }
        if name.hasPrefix("-") { return "A branch name can’t start with “-”." }
        if name.hasPrefix("/") || name.hasSuffix("/") { return "A branch name can’t start or end with “/”." }
        if name.hasSuffix(".") { return "A branch name can’t end with “.”." }
        if name.hasSuffix(".lock") { return "A branch name can’t end with “.lock”." }
        if name.contains("..") { return "A branch name can’t contain “..”." }
        if name.contains("//") { return "A branch name can’t contain “//”." }
        if name.contains("@{") { return "A branch name can’t contain “@{”." }
        if name.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return "A branch name can’t contain spaces."
        }
        for bad in ["~", "^", ":", "?", "*", "[", "\\"] where name.contains(bad) {
            return "A branch name can’t contain “\(bad)”."
        }
        return nil
    }

    // Which branches the Delete Branch submenu may offer. git refuses to delete
    // a branch that any worktree has checked out, so those are filtered out
    // here rather than surfaced as an action that always fails.
    static func deletableBranches(all: [String], current: String?, checkedOutElsewhere: Set<String>) -> [String] {
        all.filter { $0 != current && !checkedOutElsewhere.contains($0) }
    }

    // The remote-comparison range for the "diff vs upstream" tab:
    // `upstream...branch` (three dots) so the diff is against the merge base —
    // commits the remote has that we don't show up as *ours to pull*, not as
    // reversed deletions of our own work.
    static func upstreamDiffArguments(branch: String, upstream: String) -> [String] {
        ["diff", "--stat", "--patch", "\(upstream)...\(branch)"]
    }

    // The title of that tab, e.g. "origin/main…main ↑2 ↓1".
    static func upstreamDiffTitle(branch: String, state: SyncState) -> String {
        guard let upstream = state.upstream else { return "diff: \(branch)" }
        let suffix = state.hasDifference ? " \(state.badge)" : ""
        return "\(upstream)…\(branch)\(suffix)"
    }
}
