import Foundation

// Standalone assertion driver for the budget-guardrails core (ROADMAP Phase 42),
// compiled against swift/Sources/suit/BudgetGuardrails.swift (Foundation-only)
// by scripts/budget-test.sh. Mirrors the AutopilotScheduler / FeedbackRouting
// standalone-test pattern: no app, no UI. Asserts the trip logic the phase's
// verification calls for — a cap crossing notifies once at the threshold, an
// Esc reaches the right pty under auto-interrupt, and staying under a cap
// never trips — plus cap resolution and the fall-back-and-re-cross case.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

// MARK: - BudgetCaps.cap resolution

print("== BudgetCaps.cap(forSessionId:) ==")
let caps = BudgetCaps(sessionCap: 5, taskCap: 20, perSession: ["s-vip": 2, "s-off": 0])
check(caps.cap(forSessionId: "s-plain") == 5, "unlisted session falls back to the default cap")
check(caps.cap(forSessionId: "s-vip") == 2, "a per-session override wins over the default")
check(caps.cap(forSessionId: "s-off") == 5, "a ≤ 0 override is ignored, default applies")
check(BudgetCaps(sessionCap: nil).cap(forSessionId: "x") == nil, "no default and no override → no ceiling")
check(BudgetCaps(sessionCap: 0).cap(forSessionId: "x") == nil, "a ≤ 0 default → no ceiling")

check(BudgetCaps().isActive == false, "empty caps are inactive")
check(BudgetCaps(sessionCap: 5).isActive, "a session cap makes caps active")
check(BudgetCaps(taskCap: 5).isActive, "a task cap makes caps active")
check(BudgetCaps(perSession: ["a": 3]).isActive, "a per-session override makes caps active")

// MARK: - Staying under a cap never trips

print("== under cap ==")
do {
    let monitor = BudgetMonitor()
    let sample = BudgetSample(scope: .session, key: "s1", sessionId: "s1", title: "Fix",
                              repo: "suit", worktree: nil, spendUSD: 3.0, cap: 5.0)
    let a = monitor.evaluate([sample], autoInterrupt: false)
    check(a.isEmpty, "spend under cap → no trip")
    var creeping = sample; creeping.spendUSD = 4.99
    check(monitor.evaluate([creeping], autoInterrupt: false).isEmpty, "still under cap after creeping up → no trip")
    check(monitor.tripped.isEmpty, "nothing marked tripped while under cap")
}

// MARK: - Crossing the cap notifies exactly once

print("== fires once at the threshold ==")
do {
    let monitor = BudgetMonitor()
    let over = BudgetSample(scope: .session, key: "s1", sessionId: "s1", title: "Fix",
                            repo: "suit", worktree: nil, spendUSD: 5.0, cap: 5.0)
    let first = monitor.evaluate([over], autoInterrupt: false)
    check(first.count == 1, "crossing the cap (spend == cap) trips once")
    check(first.first?.sessionId == "s1", "the trip carries the session's pty id")
    check(first.first?.detail == "$5.00 ≥ $5.00 session cap", "detail reads spend vs cap")

    var higher = over; higher.spendUSD = 9.0
    check(monitor.evaluate([higher], autoInterrupt: false).isEmpty,
          "a sustained overage on the next heartbeat does not re-fire")
    check(monitor.evaluate([higher], autoInterrupt: false).isEmpty,
          "…nor the one after that")
}

// MARK: - Auto-interrupt folds into the trip

print("== auto-interrupt reaches the right pty ==")
do {
    let sample = BudgetSample(scope: .task, key: "suit/task-x", sessionId: "s-rep", title: "task-x",
                              repo: "suit", worktree: "task-x", spendUSD: 25.0, cap: 20.0)
    let off = BudgetMonitor().evaluate([sample], autoInterrupt: false)
    check(off.first?.shouldInterrupt == false, "auto-interrupt off → the trip does not interrupt")

    let on = BudgetMonitor().evaluate([sample], autoInterrupt: true)
    check(on.first?.shouldInterrupt == true, "auto-interrupt on → the trip interrupts")
    check(on.first?.sessionId == "s-rep", "…the Esc targets the task's representative pty")
    check(on.first?.scope == .task, "the trip keeps its task scope")
}

// MARK: - Falling back under, then re-crossing, trips again

print("== fall back then re-cross ==")
do {
    let monitor = BudgetMonitor()
    let over = BudgetSample(scope: .session, key: "s1", sessionId: "s1", title: "Fix",
                            repo: nil, worktree: nil, spendUSD: 6.0, cap: 5.0)
    check(monitor.evaluate([over], autoInterrupt: false).count == 1, "first crossing trips")
    // Cap raised above current spend (Set Budget… → higher ceiling): clears.
    var raised = over; raised.cap = 10.0
    check(monitor.evaluate([raised], autoInterrupt: false).isEmpty, "raising the cap above spend clears the trip")
    // Spend climbs past the new, higher cap: trips again (fresh news).
    var reCross = raised; reCross.spendUSD = 11.0
    let again = monitor.evaluate([reCross], autoInterrupt: false)
    check(again.count == 1, "climbing past the raised cap trips again")
    check(again.first?.cap == 10.0, "…against the new cap")

    // An ended session (absent from the batch) drops its mark so the set is bounded.
    _ = monitor.evaluate([], autoInterrupt: false)
    check(monitor.tripped.isEmpty, "a vanished session drops its tripped mark")
}

// MARK: - Trip id folds the cap in (dedup across cap changes)

print("== trip id ==")
do {
    let t1 = BudgetTrip(scope: .session, key: "s1", sessionId: "s1", title: "x",
                        repo: nil, worktree: nil, spendUSD: 6, cap: 5, shouldInterrupt: false)
    let t2 = BudgetTrip(scope: .session, key: "s1", sessionId: "s1", title: "x",
                        repo: nil, worktree: nil, spendUSD: 12, cap: 10, shouldInterrupt: false)
    check(t1.id != t2.id, "a different cap yields a distinct id (re-cross is fresh news)")
    check(t1.id == "budget-session-s1-500", "id folds scope, key, and cap-in-cents")
}

// MARK: - A ≤ 0 cap never trips even at high spend

print("== zero cap ==")
do {
    let sample = BudgetSample(scope: .session, key: "s1", sessionId: "s1", title: "x",
                              repo: nil, worktree: nil, spendUSD: 999, cap: 0)
    check(BudgetMonitor().evaluate([sample], autoInterrupt: true).isEmpty, "a 0 cap never trips")
}

// MARK: - summary

print("")
if failures == 0 {
    print("ALL PASSED")
    exit(0)
} else {
    print("\(failures) ASSERTION(S) FAILED")
    exit(1)
}
