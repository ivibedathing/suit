import Foundation

// Standalone assertion driver for the PR-review core (ROADMAP Phase 39),
// compiled against swift/Sources/suit/PRReview.swift + DiffReview.swift
// (both Foundation-only) by scripts/pr-review-test.sh. Mirrors the Recipes /
// FeedbackRouting standalone-test pattern: no app, no UI — the `gh pr list`
// JSON parse (fields, author.login, dedup, newest-first, check summary), and
// the `gh pr review` decision/body/argv composition from a diff-review draft.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

// MARK: - parseList

print("== PRReviewInbox.parseList ==")
let listJSON = """
[
  {"number": 7, "title": "Add widget", "author": {"login": "alice"}, "headRefName": "feat/widget",
   "url": "https://github.com/o/r/pull/7",
   "statusCheckRollup": [{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]},
  {"number": 12, "title": "Fix crash", "author": {"login": "bob"}, "headRefName": "fix/crash",
   "url": "https://github.com/o/r/pull/12",
   "statusCheckRollup": [{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]},
  {"number": 7, "title": "Add widget (dup)", "author": {"login": "alice"}, "headRefName": "feat/widget",
   "url": "https://github.com/o/r/pull/7", "statusCheckRollup": []}
]
"""
let items = PRReviewInbox.parseList(listJSON)
check(items.count == 2, "three entries with a duplicate number dedup to two")
check(items.map { $0.number } == [12, 7], "sorted newest-first by PR number")
check(items[0].title == "Fix crash" && items[0].author == "bob" && items[0].branch == "fix/crash",
      "title / author.login / headRefName parsed")
check(items[0].url == "https://github.com/o/r/pull/12", "url parsed")
check(items[0].checks == .failing, "a FAILURE check rollup → failing")
check(items[1].checks == .passing, "a SUCCESS-only rollup → passing")
check(items[1].checksGlyph == "✓" && items[0].checksGlyph == "✕", "glyphs match the state")

check(PRReviewInbox.parseList("not json").isEmpty, "garbage JSON → empty (graceful)")
check(PRReviewInbox.parseList("[]").isEmpty, "empty array → empty")

// MARK: - summarizeChecks

print("== PRReviewInbox.summarizeChecks ==")
check(PRReviewInbox.summarizeChecks(nil) == .none, "no rollup → none")
check(PRReviewInbox.summarizeChecks([]) == .none, "empty rollup → none")
check(PRReviewInbox.summarizeChecks([["status": "IN_PROGRESS"]]) == .pending, "an in-progress run → pending")
check(PRReviewInbox.summarizeChecks([["state": "PENDING"]]) == .pending, "a pending status context → pending")
check(PRReviewInbox.summarizeChecks(
    [["status": "COMPLETED", "conclusion": "SUCCESS"], ["state": "FAILURE"]]) == .failing,
    "any failure wins over a success")

// MARK: - decision → flag

print("== PRReviewDecision ==")
check(PRReviewDecision.approve.ghFlag == "--approve", "approve → --approve")
check(PRReviewDecision.requestChanges.ghFlag == "--request-changes", "requestChanges → --request-changes")
check(PRReviewDecision.comment.ghFlag == "--comment", "comment → --comment")
check(!PRReviewDecision.approve.requiresBody, "approve may stand alone")
check(PRReviewDecision.requestChanges.requiresBody && PRReviewDecision.comment.requiresBody,
      "request-changes and comment require a body")

// MARK: - composeBody

print("== PRReviewComposer.composeBody ==")
let comments = [
    DiffReviewComment(file: "a.swift", side: .new, line: 20, lineText: "let x = 1", text: "rename x"),
    DiffReviewComment(file: "b.swift", side: .new, line: 5, lineText: "", text: "nit"),
    DiffReviewComment(file: "a.swift", side: .new, line: 3, lineText: "import Foo", text: "unused?"),
]
let body = PRReviewComposer.composeBody(overall: "Overall looks good.", comments: comments)
check(body.contains("Overall looks good."), "overall note leads the body")
check(body.contains("**a.swift**") && body.contains("**b.swift**"), "grouped by file")
let aFirst = body.range(of: "**a.swift**")!.lowerBound
let bFirst = body.range(of: "**b.swift**")!.lowerBound
check(aFirst < bFirst, "files kept in first-appearance order (a before b)")
let l3 = body.range(of: "Line 3")!.lowerBound
let l20 = body.range(of: "Line 20")!.lowerBound
check(l3 < l20, "within a file, comments sorted by line (3 before 20)")
check(body.contains("Line 20 `let x = 1`: rename x"), "line + code + note formatted")
check(body.contains("- Line 5: nit"), "a blank code line omits the backticks")

check(PRReviewComposer.composeBody(overall: "", comments: []).isEmpty, "no overall + no comments → empty body")
check(PRReviewComposer.composeBody(overall: "  ", comments: []).isEmpty, "whitespace overall → empty body")

// MARK: - reviewArguments

print("== PRReviewComposer.reviewArguments ==")
check(PRReviewComposer.reviewArguments(number: 12, decision: .approve, body: "")
      == ["pr", "review", "12", "--approve"], "bare approve omits --body")
check(PRReviewComposer.reviewArguments(number: 12, decision: .approve, body: "LGTM")
      == ["pr", "review", "12", "--approve", "--body", "LGTM"], "approve with a body")
check(PRReviewComposer.reviewArguments(number: 3, decision: .requestChanges, body: "fix it")
      == ["pr", "review", "3", "--request-changes", "--body", "fix it"], "request-changes argv")
check(PRReviewComposer.reviewArguments(number: 9, decision: .comment, body: "note")
      == ["pr", "review", "9", "--comment", "--body", "note"], "comment argv")

// MARK: - summary

print("")
if failures == 0 {
    print("ALL PASSED")
    exit(0)
} else {
    print("\(failures) ASSERTION(S) FAILED")
    exit(1)
}
