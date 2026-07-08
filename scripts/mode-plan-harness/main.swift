import Foundation

// Mode + plan-approval logic harness (ROADMAP Phase 26). Compiled by
// scripts/mode-plan-harness.sh against the real ClaudeMode.swift and
// PlanParsing.swift plus a tiny ClaudeSession stub, so the pure control logic
// the phase rests on is asserted directly:
//
//   - the Shift+Tab payload that switches modes (readback + send),
//   - the plan parsed from a transcript renders every step in order,
//   - each approval button injects the correct pty payload.
//
// Prints "OBSERVE …" lines and exits nonzero on the first failed assertion.

var failures = 0
func check(_ condition: Bool, _ label: String) {
    if condition {
        print("OBSERVE ok: \(label)")
    } else {
        print("OBSERVE FAIL: \(label)")
        failures += 1
    }
}

// MARK: - Mode switch: payload + cycle correctness

// The Shift+Tab back-tab sequence, repeated once per cycle step.
let st = "\u{1b}[Z"
check(ClaudeModeControl.payload(from: .ask, to: .ask) == "", "no presses when already in the target mode")
check(ClaudeModeControl.payload(from: .ask, to: .agent) == st, "ask→agent is one Shift+Tab")
check(ClaudeModeControl.payload(from: .ask, to: .plan) == st + st, "ask→plan is two Shift+Tabs")
check(ClaudeModeControl.payload(from: .plan, to: .ask) == st, "plan→ask wraps to one Shift+Tab")
check(ClaudeModeControl.payload(from: .agent, to: .plan) == st, "agent→plan is one Shift+Tab")
check(ClaudeModeControl.payload(from: .plan, to: .agent) == st + st, "plan→agent is two Shift+Tabs")

// Cycling `presses` times from any mode must land exactly on the target — the
// invariant that makes the believed-state model self-consistent.
let order: [ClaudeMode] = [.ask, .agent, .plan] // Claude Code's Shift+Tab cycle
func advance(_ mode: ClaudeMode, by steps: Int) -> ClaudeMode {
    let i = order.firstIndex(of: mode)!
    return order[(i + steps) % order.count]
}
for from in ClaudeMode.allCases {
    for to in ClaudeMode.allCases {
        let steps = ClaudeModeControl.presses(from: from, to: to)
        check(advance(from, by: steps) == to, "cycle \(from.rawValue)→\(to.rawValue) lands right (\(steps) presses)")
    }
}

// MARK: - Mode readback mapping + tracker precedence

check(ClaudeMode.fromRawMode("plan") == .plan, "readback: plan")
check(ClaudeMode.fromRawMode("acceptEdits") == .agent, "readback: acceptEdits→agent")
check(ClaudeMode.fromRawMode("bypassPermissions") == .agent, "readback: bypassPermissions→agent")
check(ClaudeMode.fromRawMode("default") == .ask, "readback: default→ask")
check(ClaudeMode.fromRawMode("nonsense") == nil, "readback: unknown→nil")

let tracker = ClaudeModeTracker.shared
let readbackSession = ClaudeSession(id: "rb", permissionMode: .plan)
check(tracker.effectiveMode(for: readbackSession) == .plan, "readback wins over tracker/default")
let noReadback = ClaudeSession(id: "s1", permissionMode: nil)
check(tracker.effectiveMode(for: noReadback) == .agent, "no readback + never sent → agent default")
tracker.record(.ask, forSessionId: "s1")
check(tracker.effectiveMode(for: noReadback) == .ask, "no readback → last mode Suit sent")

// MARK: - Plan parsing: latest plan, steps in order

// A transcript with two ExitPlanMode calls — the freshest plan wins, and its
// numbered steps parse in order.
func assistantExitPlan(_ plan: String) -> String {
    let obj: [String: Any] = [
        "type": "assistant",
        "message": ["content": [["type": "tool_use", "name": "ExitPlanMode", "input": ["plan": plan]]]],
    ]
    let data = try! JSONSerialization.data(withJSONObject: obj)
    return String(data: data, encoding: .utf8)!
}

let stalePlan = "Old plan\n1. throwaway"
let freshPlan = "Refactor the parser\n\n1. Extract the tokenizer\n2. Add the AST builder\n3. Wire up tests"
let lines = [
    "{\"type\":\"user\",\"message\":{\"content\":\"go\"}}",
    assistantExitPlan(stalePlan),
    "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"thinking\"}]}}",
    assistantExitPlan(freshPlan),
]
guard let parsed = PlanParser.latestPlan(inTranscriptLines: lines) else {
    print("OBSERVE FAIL: expected a parsed plan")
    exit(1)
}
check(parsed.rawMarkdown == freshPlan, "latest ExitPlanMode plan wins over an earlier one")
check(parsed.steps == ["Extract the tokenizer", "Add the AST builder", "Wire up tests"], "numbered steps parse in order, markers stripped")

// Bulleted plans and prose fallback.
check(PlanParser.steps(fromMarkdown: "- a\n- b\n- c") == ["a", "b", "c"], "bulleted steps parse in order")
check(PlanParser.steps(fromMarkdown: "# Heading\nJust prose here.\nAnd more.") == ["Just prose here.", "And more."], "prose fallback drops headings, keeps order")

// No ExitPlanMode anywhere → no plan.
check(PlanParser.latestPlan(inTranscriptLines: ["{\"type\":\"user\",\"message\":{\"content\":\"hi\"}}"]) == nil, "no ExitPlanMode → nil plan")

// MARK: - Approval payloads

check(PlanApprovalAction.approveAndRun.ptyPayload == "1", "Approve & Run injects '1'")
check(PlanApprovalAction.edit.ptyPayload == "2", "Edit injects '2'")
check(PlanApprovalAction.discard.ptyPayload == "3", "Discard injects '3'")

if failures == 0 {
    print("OBSERVE ALL PASS")
    exit(0)
} else {
    print("OBSERVE \(failures) FAILURE(S)")
    exit(1)
}
