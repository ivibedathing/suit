import Foundation

// Phase 29 IO layer: gathers the actual feedback events for a repo by running
// git (conflict state per worktree) and gh (CI failures + PR review comments
// per open PR), then attributing each to its originating session. Runs off the
// main thread — GitView calls it like `loadBranchData` — so it takes a session
// snapshot the caller reads on the main thread rather than touching
// ClaudeSessionMonitor off-thread. The model, parsing, attribution and prompt
// composition live in the UI-free `FeedbackRouting`.
enum FeedbackInbox {
    private static let git = "/usr/bin/git"

    // A live session, as the caller hands it in (read on the main thread).
    struct SessionRef {
        let id: String
        let cwd: String?
        let displayName: String
    }

    // Every actionable feedback event across the repo's worktrees. `prByBranch`
    // is reused from the branch/PR pass so this doesn't re-list PRs; gh is only
    // consulted for open PRs whose branch has a worktree (few), and only for the
    // failing-check / review detail behind them.
    static func gather(root: String, prByBranch: [String: GitPRInfo], sessions: [SessionRef]) -> [FeedbackEvent] {
        let sessionPairs = sessions.map { (id: $0.id, cwd: $0.cwd) }
        func attribute(_ worktreePath: String) -> String? {
            FeedbackRouting.attributeSession(worktreePath: worktreePath, sessions: sessionPairs)
        }

        var events: [FeedbackEvent] = []
        for worktree in listWorktrees(root: root) {
            // Merge conflicts: read the worktree's own working-tree state.
            if let porcelain = runProcess(git, ["-C", worktree.path, "status", "--porcelain"]) {
                let conflicts = FeedbackRouting.conflictedFiles(porcelain: porcelain)
                if !conflicts.isEmpty {
                    events.append(FeedbackEvent(
                        kind: .mergeConflict, worktreePath: worktree.path, branch: worktree.branch,
                        prNumber: nil,
                        title: "\(conflicts.count) conflicted file\(conflicts.count == 1 ? "" : "s")",
                        detail: conflicts.map { "- \($0)" }.joined(separator: "\n"),
                        sessionId: attribute(worktree.path)
                    ))
                }
            }

            // CI + review feedback both need an open PR for the branch.
            guard let branch = worktree.branch,
                  let pr = prByBranch[branch], pr.state == .open else { continue }

            if pr.checks == .failing {
                let checks = GitHubCLI.failingChecks(root: root, number: pr.number)
                var lines = checks.map { check -> String in
                    check.detailsURL.map { "- \(check.name) — \($0)" } ?? "- \(check.name)"
                }
                let log = GitHubCLI.failedRunLog(root: root, branch: branch)
                if !log.isEmpty {
                    lines.append("")
                    lines.append(log)
                }
                events.append(FeedbackEvent(
                    kind: .ciFailure, worktreePath: worktree.path, branch: branch, prNumber: pr.number,
                    title: checks.isEmpty ? "Checks failing" : "\(checks.count) check\(checks.count == 1 ? "" : "s") failing",
                    detail: lines.joined(separator: "\n"),
                    sessionId: attribute(worktree.path)
                ))
            }

            if let feedback = GitHubCLI.prFeedback(root: root, number: pr.number), !feedback.isEmpty {
                let detail = (feedback.reviews + feedback.comments)
                    .map { "@\($0.author): \($0.body)" }
                    .joined(separator: "\n\n")
                events.append(FeedbackEvent(
                    kind: .prComment, worktreePath: worktree.path, branch: branch, prNumber: pr.number,
                    title: "\(feedback.count) review comment\(feedback.count == 1 ? "" : "s")",
                    detail: detail,
                    sessionId: attribute(worktree.path)
                ))
            }
        }
        return events
    }

    // `git worktree list --porcelain`: "worktree <path>" then "branch
    // refs/heads/<name>" (or "detached") per block. (GitView+Worktrees has a
    // private twin; this copy keeps the inbox self-contained.)
    private static func listWorktrees(root: String) -> [(path: String, branch: String?)] {
        guard let output = runProcess(git, ["-C", root, "worktree", "list", "--porcelain"]) else { return [] }
        var result: [(path: String, branch: String?)] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("worktree ") {
                result.append((path: String(line.dropFirst("worktree ".count)), branch: nil))
            } else if line.hasPrefix("branch refs/heads/"), !result.isEmpty {
                result[result.count - 1].branch = String(line.dropFirst("branch refs/heads/".count))
            }
        }
        return result
    }
}
