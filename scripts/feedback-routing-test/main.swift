import Foundation

// Standalone logic test for the Phase 29 feedback-routing core. Compiled with
// only swift/Sources/suit/FeedbackRouting.swift (Foundation-only, no app deps),
// the RoadmapParser/AutopilotScheduler pattern. Exercises the pure parsers,
// the session-attribution rule, and the composed prompts against fixtures with
// known answers. Prints PASS/FAIL lines and exits non-zero on any failure.

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}

// MARK: - Conflict parsing

do {
    let porcelain = """
    UU src/a.swift
    AA src/b.swift
    DD src/c.swift
     M src/clean.swift
    ?? untracked.txt
    AU src/d.swift
    M  staged.swift
    """
    let conflicts = FeedbackRouting.conflictedFiles(porcelain: porcelain)
    check("conflict: detects UU/AA/DD/AU", conflicts == ["src/a.swift", "src/b.swift", "src/c.swift", "src/d.swift"])
    check("conflict: excludes clean/staged/untracked", !conflicts.contains("src/clean.swift") && !conflicts.contains("staged.swift") && !conflicts.contains("untracked.txt"))
    check("conflict: empty status → no conflicts", FeedbackRouting.conflictedFiles(porcelain: "").isEmpty)
}

// MARK: - PR review/comment parsing

do {
    let json = """
    {
      "reviews": [
        {"author": {"login": "alice"}, "state": "CHANGES_REQUESTED", "body": "Please fix the null check."},
        {"author": {"login": "bob"}, "state": "APPROVED", "body": ""}
      ],
      "comments": [
        {"author": {"login": "carol"}, "body": "Nit: rename this."},
        {"author": {"login": "dave"}, "body": "   "}
      ]
    }
    """.data(using: .utf8)!
    let feedback = FeedbackRouting.parsePRFeedback(json: json)!
    check("prFeedback: keeps review with body", feedback.reviews.count == 1 && feedback.reviews[0].author == "alice")
    check("prFeedback: drops empty approval body", !feedback.reviews.contains { $0.author == "bob" })
    check("prFeedback: keeps non-empty comment", feedback.comments.count == 1 && feedback.comments[0].author == "carol")
    check("prFeedback: drops whitespace-only comment", !feedback.comments.contains { $0.author == "dave" })
    check("prFeedback: count is reviews+comments", feedback.count == 2)
    check("prFeedback: empty arrays → isEmpty", FeedbackRouting.parsePRFeedback(json: "{\"reviews\":[],\"comments\":[]}".data(using: .utf8)!)!.isEmpty)
    check("prFeedback: garbage → nil", FeedbackRouting.parsePRFeedback(json: "not json".data(using: .utf8)!) == nil)
}

// MARK: - Failing-check parsing

do {
    let json = """
    {
      "statusCheckRollup": [
        {"name": "build", "conclusion": "FAILURE", "detailsUrl": "https://ci/build"},
        {"name": "lint", "conclusion": "SUCCESS", "detailsUrl": "https://ci/lint"},
        {"context": "legacy-status", "state": "ERROR", "targetUrl": "https://ci/legacy"},
        {"name": "flaky", "conclusion": "TIMED_OUT"},
        {"name": "pending-check", "status": "IN_PROGRESS", "conclusion": ""}
      ]
    }
    """.data(using: .utf8)!
    let failing = FeedbackRouting.parseFailingChecks(json: json)
    let names = failing.map { $0.name }
    check("checks: FAILURE conclusion detected", names.contains("build"))
    check("checks: ERROR state detected", names.contains("legacy-status"))
    check("checks: TIMED_OUT detected", names.contains("flaky"))
    check("checks: SUCCESS excluded", !names.contains("lint"))
    check("checks: pending excluded", !names.contains("pending-check"))
    check("checks: detailsUrl carried", failing.first { $0.name == "build" }?.detailsURL == "https://ci/build")
    check("checks: targetUrl fallback", failing.first { $0.name == "legacy-status" }?.detailsURL == "https://ci/legacy")
    check("checks: missing url → nil", failing.first { $0.name == "flaky" }?.detailsURL == nil)
    check("checks: no rollup key → empty", FeedbackRouting.parseFailingChecks(json: "{}".data(using: .utf8)!).isEmpty)
}

// MARK: - Session attribution

do {
    let wt = "/repo/.claude/worktrees/task-a"
    // Exactly one session in the worktree → attributed.
    let one: [(id: String, cwd: String?)] = [("s1", wt), ("s2", "/repo/other")]
    check("attribute: single match → id", FeedbackRouting.attributeSession(worktreePath: wt, sessions: one) == "s1")
    // Trailing slash on one side still matches.
    let slash: [(id: String, cwd: String?)] = [("s1", wt + "/")]
    check("attribute: trailing slash ignored", FeedbackRouting.attributeSession(worktreePath: wt, sessions: slash) == "s1")
    // No session in the worktree → nil (picker).
    let none: [(id: String, cwd: String?)] = [("s2", "/repo/other")]
    check("attribute: no match → nil", FeedbackRouting.attributeSession(worktreePath: wt, sessions: none) == nil)
    // Two sessions in the same worktree → ambiguous → nil (picker).
    let two: [(id: String, cwd: String?)] = [("s1", wt), ("s3", wt)]
    check("attribute: ambiguous → nil", FeedbackRouting.attributeSession(worktreePath: wt, sessions: two) == nil)
    // A nil-cwd session never spuriously matches.
    let nilCwd: [(id: String, cwd: String?)] = [("s1", nil)]
    check("attribute: nil cwd never matches", FeedbackRouting.attributeSession(worktreePath: wt, sessions: nilCwd) == nil)
}

// MARK: - Prompt composition

do {
    let ci = FeedbackEvent(kind: .ciFailure, worktreePath: "/repo/wt", branch: "task/x", prNumber: 42,
                           title: "1 check failing", detail: "- build — https://ci/build", sessionId: "s1")
    let ciPrompt = FeedbackRouting.composePrompt(for: ci)
    check("prompt(ci): names branch + PR", ciPrompt.contains("branch `task/x`") && ciPrompt.contains("PR #42"))
    check("prompt(ci): embeds detail verbatim", ciPrompt.contains("- build — https://ci/build"))
    check("prompt(ci): fenced for bracketed paste", ciPrompt.contains("```"))

    let review = FeedbackEvent(kind: .prComment, worktreePath: "/repo/wt", branch: "task/x", prNumber: 42,
                               title: "2 review comments", detail: "@alice: fix it", sessionId: nil)
    let reviewPrompt = FeedbackRouting.composePrompt(for: review)
    check("prompt(review): mentions reviewer feedback", reviewPrompt.lowercased().contains("reviewer left feedback"))
    check("prompt(review): embeds comment", reviewPrompt.contains("@alice: fix it"))

    let conflict = FeedbackEvent(kind: .mergeConflict, worktreePath: "/repo/wt", branch: nil, prNumber: nil,
                                 title: "2 conflicted files", detail: "- a\n- b", sessionId: "s1")
    let conflictPrompt = FeedbackRouting.composePrompt(for: conflict)
    check("prompt(conflict): asks to resolve", conflictPrompt.lowercased().contains("merge conflicts") && conflictPrompt.lowercased().contains("resolve"))
    check("prompt(conflict): no PR/branch when absent", !conflictPrompt.contains("PR #"))

    // Event identity dedupes CI failures on the same PR/worktree.
    let ciDup = FeedbackEvent(kind: .ciFailure, worktreePath: "/repo/wt", branch: "task/x", prNumber: 42,
                              title: "different title", detail: "different", sessionId: nil)
    check("event.id: same kind+worktree+PR collapses", ci.id == ciDup.id)
    check("event.id: kind distinguishes", ci.id != review.id)
}

print(failures == 0 ? "ALL PASS" : "FAILED (\(failures))")
exit(failures == 0 ? 0 : 1)
