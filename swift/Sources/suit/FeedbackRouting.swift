import Foundation

// Phase 29 — Automated feedback-loop routing. When CI fails, a reviewer leaves
// PR comments, or a merge conflicts, the fix belongs in the exact Claude
// session that wrote the change. This file is the UI-free, deterministic core:
// the `FeedbackEvent` model, the pure parsers that turn `git`/`gh` output into
// events, the session-attribution rule, and the prompt each event composes for
// its session. The IO (running `gh`/`git`) lives in `FeedbackInbox` and the UI
// (the Git-tab section, the route action) in `GitView+Feedback` / `AppDelegate`;
// keeping this layer Foundation-only makes it standalone-compilable for the
// logic tests, exactly like `RoadmapParser` / `AutopilotScheduler` / `DiffReview`.

// The three kinds of machine feedback Suit routes.
enum FeedbackEventKind: String {
    case ciFailure = "ci"
    case prComment = "review"
    case mergeConflict = "conflict"

    // Row label / the noun used in the composed prompt.
    var label: String {
        switch self {
        case .ciFailure: return "CI failure"
        case .prComment: return "Review comments"
        case .mergeConflict: return "Merge conflict"
        }
    }

    // SF Symbol name for the Git-tab row (kept here as a plain string so this
    // file stays AppKit-free — the row view resolves it).
    var symbolName: String {
        switch self {
        case .ciFailure: return "xmark.octagon"
        case .prComment: return "text.bubble"
        case .mergeConflict: return "arrow.triangle.merge"
        }
    }
}

// One actionable feedback item: a kind, the worktree it belongs to, and the
// content that becomes the routed prompt. `sessionId` is the originating
// session resolved by attribution — nil means "ambiguous", so routing falls
// back to a picker rather than guessing (the phase's caveat).
struct FeedbackEvent {
    let kind: FeedbackEventKind
    let worktreePath: String
    let branch: String?
    let prNumber: Int?
    let title: String       // one-line row summary
    let detail: String      // failing-check list + logs / comment bodies / conflict files
    var sessionId: String?  // originating session; nil → picker

    // Stable identity for dedupe and row selection: kind + worktree + the PR or
    // branch discriminator. Two CI failures on the same PR collapse to one.
    var id: String {
        "\(kind.rawValue):\(worktreePath):\(prNumber.map(String.init) ?? branch ?? "")"
    }
}

enum FeedbackRouting {
    // MARK: - Conflict detection

    // The conflicted (unmerged) paths in a `git status --porcelain` dump. Git
    // marks unmerged entries with an XY status code where at least one side is
    // 'U', plus the both-added ('AA') and both-deleted ('DD') cases. The path
    // starts at column 3 ("XY <path>").
    static func conflictedFiles(porcelain: String) -> [String] {
        var files: [String] = []
        for rawLine in porcelain.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard line.count >= 4 else { continue }
            let chars = Array(line)
            let x = chars[0], y = chars[1]
            let code = "\(x)\(y)"
            let unmerged = x == "U" || y == "U" || code == "AA" || code == "DD"
            guard unmerged else { continue }
            // Skip "XY " → path at index 3, trimming any surrounding quotes git
            // adds for paths with unusual characters.
            let path = String(line.dropFirst(3)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !path.isEmpty { files.append(path) }
        }
        return files
    }

    // MARK: - gh JSON parsing

    // One reviewer note — a review body or a PR conversation comment.
    struct Comment {
        let author: String
        let body: String
    }

    // The reviewer feedback on a PR, from `gh pr view <n> --json reviews,comments`.
    struct PRFeedback {
        let reviews: [Comment]   // review summaries that carry a body
        let comments: [Comment]  // PR conversation comments

        var isEmpty: Bool { reviews.isEmpty && comments.isEmpty }
        var count: Int { reviews.count + comments.count }
    }

    // Parses `{ "reviews": [...], "comments": [...] }`. Only notes that carry a
    // non-empty body count — a bare "APPROVED" review with no text isn't
    // actionable feedback, so it's dropped by the body check.
    static func parsePRFeedback(json: Data) -> PRFeedback? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        func comments(_ key: String) -> [Comment] {
            guard let array = object[key] as? [[String: Any]] else { return [] }
            var out: [Comment] = []
            for entry in array {
                let body = (entry["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !body.isEmpty else { continue }
                let author = ((entry["author"] as? [String: Any])?["login"] as? String) ?? "reviewer"
                out.append(Comment(author: author, body: body))
            }
            return out
        }
        return PRFeedback(reviews: comments("reviews"), comments: comments("comments"))
    }

    // One check that isn't passing.
    struct CheckFailure {
        let name: String
        let detailsURL: String?
    }

    // The failing checks from `gh pr view <n> --json statusCheckRollup`. The
    // rollup mixes CheckRun (name/conclusion/detailsUrl) and StatusContext
    // (context/state/targetUrl) entries; a check is failing when its conclusion
    // or state is one of the terminal-bad values.
    static func parseFailingChecks(json: Data) -> [CheckFailure] {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let rollup = object["statusCheckRollup"] as? [[String: Any]] else { return [] }
        let badConclusions: Set<String> = ["FAILURE", "TIMED_OUT", "CANCELLED", "ERROR", "ACTION_REQUIRED", "STARTUP_FAILURE"]
        let badStates: Set<String> = ["FAILURE", "ERROR"]
        var out: [CheckFailure] = []
        for check in rollup {
            let conclusion = (check["conclusion"] as? String)?.uppercased() ?? ""
            let state = (check["state"] as? String)?.uppercased() ?? ""
            guard badConclusions.contains(conclusion) || badStates.contains(state) else { continue }
            let name = (check["name"] as? String)
                ?? (check["context"] as? String)
                ?? (check["workflowName"] as? String)
                ?? "check"
            let url = (check["detailsUrl"] as? String) ?? (check["targetUrl"] as? String)
            out.append(CheckFailure(name: name, detailsURL: (url?.isEmpty == false) ? url : nil))
        }
        return out
    }

    // MARK: - Session attribution

    // The session whose cwd is this worktree, for routing. Returns a single id
    // only when exactly one live session matches — 0 or >1 matches yield nil so
    // the caller shows a picker rather than guessing (the phase's caveat that
    // routing is only as reliable as the session↔worktree map). Paths are
    // compared physically (symlinks resolved, trailing slash ignored) because a
    // session's recorded cwd and the worktree path can differ only by
    // /tmp→/private/tmp-style symlinks.
    static func attributeSession(worktreePath: String, sessions: [(id: String, cwd: String?)]) -> String? {
        let target = normalize(worktreePath)
        let matches = sessions.filter { normalize($0.cwd) == target && $0.cwd != nil }
        return matches.count == 1 ? matches[0].id : nil
    }

    private static func normalize(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let resolved = (path as NSString).resolvingSymlinksInPath as NSString
        let standardized = resolved.standardizingPath
        return standardized.hasSuffix("/") && standardized.count > 1
            ? String(standardized.dropLast()) : standardized
    }

    // MARK: - Prompt composition

    // The structured prompt routed into the originating session's pty. Frames
    // the event so Claude knows what came back and what to do, then embeds the
    // machine detail verbatim (fenced so bracketed paste keeps it one input
    // unit — mirrors the Autopilot feedback messages).
    static func composePrompt(for event: FeedbackEvent) -> String {
        let where_ = event.branch.map { "branch `\($0)`" } ?? "this worktree"
        let pr = event.prNumber.map { " (PR #\($0))" } ?? ""
        switch event.kind {
        case .ciFailure:
            return """
            CI checks failed on \(where_)\(pr). Please investigate and fix the failures, then commit and push.

            ```
            \(event.detail)
            ```
            """
        case .prComment:
            return """
            A reviewer left feedback on \(where_)\(pr). Please address each point, then commit and push.

            ```
            \(event.detail)
            ```
            """
        case .mergeConflict:
            return """
            \(where_.prefix(1).uppercased() + where_.dropFirst()) has merge conflicts. Please resolve the conflicts in these files, then stage and continue the merge/rebase:

            ```
            \(event.detail)
            ```
            """
        }
    }

    // The instruction that primes a dedicated review-pass session (Phase 29's
    // optional reviewer lane): review the branch's changes with the machine
    // feedback as context, then report — deliberately read-only ("don't edit
    // yet"), in keeping with the review pillar.
    static func reviewPassPrompt(for event: FeedbackEvent) -> String {
        let where_ = event.branch.map { "branch `\($0)`" } ?? "this worktree"
        return """
        Please review the changes on \(where_) for correctness and quality. Here is the machine feedback that prompted this review:

        ```
        \(event.detail)
        ```

        Summarize the concrete problems you find and what should change. Don't edit files yet — just report.
        """
    }
}
