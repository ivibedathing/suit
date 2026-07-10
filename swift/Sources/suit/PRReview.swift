import Foundation

// GitHub PR review inbox: the UI-free core (the
// Recipes / FeedbackRouting pattern — Foundation-only, no app or UI deps).
// Parses `gh pr list` JSON into inbox items, summarizes the check rollup to a
// glyph, and composes a `gh pr review` decision + body from a diff-review
// draft's line comments. The Cocoa `GitHubCLI` wrappers shell out; this decides
// what to parse and what argv to send. Verified by scripts/pr-review-test.sh.

// One open PR in the review inbox.
struct PRReviewItem: Equatable {
    // The check rollup collapsed to one traffic light (mirrors GitPRInfo.Checks,
    // plus an explicit `.none` for a PR with no checks configured).
    enum Checks: String, Equatable { case passing, failing, pending, none }

    var number: Int
    var title: String
    var author: String
    var branch: String     // headRefName
    var url: String
    var checks: Checks

    // The status glyph shown after the PR number, matching the Git tab's badge.
    var checksGlyph: String {
        switch checks {
        case .passing: return "✓"
        case .failing: return "✕"
        case .pending: return "•"
        case .none: return ""
        }
    }
}

enum PRReviewInbox {
    // Parse a `gh pr list --json number,title,author,headRefName,url,statusCheckRollup`
    // array. Missing scalar fields degrade to empty strings; a PR with no number
    // is skipped. Dedups by number, first occurrence wins, so the caller can union
    // several searches (authored / assigned / review-requested) freely. Returned
    // newest-first by PR number (highest = most recent).
    static func parseList(_ json: String) -> [PRReviewItem] {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        var seen = Set<Int>()
        var items: [PRReviewItem] = []
        for entry in array {
            guard let number = entry["number"] as? Int, !seen.contains(number) else { continue }
            seen.insert(number)
            // gh renders author as an object; fall back to a bare string just in case.
            let author = (entry["author"] as? [String: Any])?["login"] as? String
                ?? entry["author"] as? String ?? ""
            items.append(PRReviewItem(
                number: number,
                title: entry["title"] as? String ?? "",
                author: author,
                branch: entry["headRefName"] as? String ?? "",
                url: entry["url"] as? String ?? "",
                checks: summarizeChecks(entry["statusCheckRollup"] as? [[String: Any]])
            ))
        }
        return items.sorted { $0.number > $1.number }
    }

    // statusCheckRollup mixes CheckRun (status/conclusion) and StatusContext
    // (state) entries; collapse to one traffic light — any failure wins, then any
    // pending, else passing. Mirrors GitHubCLI.summarizeChecks.
    static func summarizeChecks(_ rollup: [[String: Any]]?) -> PRReviewItem.Checks {
        guard let rollup, !rollup.isEmpty else { return .none }
        var anyPending = false
        for check in rollup {
            let conclusion = (check["conclusion"] as? String)?.uppercased() ?? ""
            let state = (check["state"] as? String)?.uppercased() ?? ""
            let status = (check["status"] as? String)?.uppercased() ?? ""
            if ["FAILURE", "TIMED_OUT", "CANCELLED", "ERROR", "ACTION_REQUIRED"].contains(conclusion)
                || ["FAILURE", "ERROR"].contains(state) {
                return .failing
            }
            if (status != "COMPLETED" && !status.isEmpty) || state == "PENDING"
                || (conclusion.isEmpty && state.isEmpty && status.isEmpty) {
                anyPending = true
            }
        }
        return anyPending ? .pending : .passing
    }
}

// The review verdict → the gh flag it maps to.
enum PRReviewDecision: String, CaseIterable {
    case approve, requestChanges, comment

    var ghFlag: String {
        switch self {
        case .approve: return "--approve"
        case .requestChanges: return "--request-changes"
        case .comment: return "--comment"
        }
    }

    var label: String {
        switch self {
        case .approve: return "Approve"
        case .requestChanges: return "Request Changes"
        case .comment: return "Comment"
        }
    }

    // gh rejects an empty body on request-changes/comment; approve may stand alone.
    var requiresBody: Bool { self != .approve }
}

enum PRReviewComposer {
    // The review body: an optional overall note, then the draft's line comments
    // as a readable checklist grouped by file (first-appearance order) and sorted
    // by line. A single `gh pr review` can't post inline per-line comments, so
    // they're folded into the body — the reviewer's line context is preserved.
    static func composeBody(overall: String, comments: [DiffReviewComment]) -> String {
        let trimmedOverall = overall.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections: [String] = []
        if !trimmedOverall.isEmpty { sections.append(trimmedOverall) }

        if !comments.isEmpty {
            var fileOrder: [String] = []
            for c in comments where !fileOrder.contains(c.file) { fileOrder.append(c.file) }
            var body = "### Line comments\n"
            for file in fileOrder {
                body += "\n**\(file)**\n"
                for c in comments.filter({ $0.file == file }).sorted(by: { $0.line < $1.line }) {
                    let code = c.lineText.trimmingCharacters(in: .whitespaces)
                    if code.isEmpty {
                        body += "- Line \(c.line): \(c.text)\n"
                    } else {
                        body += "- Line \(c.line) `\(code)`: \(c.text)\n"
                    }
                }
            }
            sections.append(body.trimmingCharacters(in: .newlines))
        }
        return sections.joined(separator: "\n\n")
    }

    // The exact `gh pr review <number> <flag> [--body <body>]` argv (the gh
    // executable is prepended by the caller). An empty body omits --body, so a
    // bare approval is `pr review <n> --approve`.
    static func reviewArguments(number: Int, decision: PRReviewDecision, body: String) -> [String] {
        var args = ["pr", "review", "\(number)", decision.ghFlag]
        if !body.isEmpty {
            args += ["--body", body]
        }
        return args
    }
}
