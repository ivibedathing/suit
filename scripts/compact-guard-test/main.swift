import Foundation

// Standalone assertion driver for the auto-/compact guardrails core, compiled
// against swift/Sources/suit/CompactGuardrails.swift (Foundation-only) by
// scripts/compact-guard-test.sh. Mirrors the BudgetGuardrails standalone-test
// pattern: no app, no UI. Asserts the trip logic — fires once at the crossing,
// only at an idle prompt, re-arms with hysteresis, honors the cooldown, and
// never acts on stale, unhosted, busy, or needs-input sessions.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

let t0 = Date(timeIntervalSince1970: 1_760_000_000)
// `at` is the heartbeat instant the sample describes — updatedAt is set `age`
// seconds before it, so a default sample is always fresh at its own tick.
func sample(_ id: String = "s1", pct: Double, state: String = "done",
            hosted: Bool = true, age: TimeInterval = 0, at now: Date = t0) -> CompactSample {
    CompactSample(sessionId: id, title: "Fix", contextPct: pct,
                  stateRaw: state, updatedAt: now.addingTimeInterval(-age), hosted: hosted)
}

// MARK: - Crossing fires once, sustained overage is silent

print("== fires once at the crossing ==")
do {
    let monitor = CompactMonitor()
    let first = monitor.evaluate([sample(pct: 72)], threshold: 70, now: t0)
    check(first.count == 1, "crossing the threshold trips once")
    check(first.first?.sessionId == "s1", "the trip carries the session's pty id")
    check(first.first?.id == "compact-s1-70", "trip id folds the threshold in")
    check(first.first?.detail == "context 72% ≥ 70% threshold", "detail reads pct vs threshold")
    let second = monitor.evaluate([sample(pct: 74)], threshold: 70, now: t0.addingTimeInterval(3))
    check(second.isEmpty, "sustained overage on the next heartbeat is silent")
    let third = monitor.evaluate([sample(pct: 90)], threshold: 70, now: t0.addingTimeInterval(6))
    check(third.isEmpty, "climbing further while tripped stays silent")
}

// MARK: - Under threshold never fires

print("== under threshold ==")
do {
    let monitor = CompactMonitor()
    check(monitor.evaluate([sample(pct: 69.9)], threshold: 70, now: t0).isEmpty,
          "just under the threshold → no trip")
    check(monitor.evaluate([sample(pct: 0)], threshold: 70, now: t0).isEmpty,
          "an empty context never trips")
    check(monitor.tripped.isEmpty, "nothing marked tripped while under")
}

// MARK: - Only an idle, hosted, fresh session fires

print("== state gating ==")
do {
    let monitor = CompactMonitor()
    check(monitor.evaluate([sample(pct: 80, state: "working")], threshold: 70, now: t0).isEmpty,
          "mid-response (working) never fires")
    check(monitor.evaluate([sample(pct: 80, state: "needs-input")], threshold: 70, now: t0).isEmpty,
          "a pending question (needs-input) never fires")
    check(monitor.evaluate([sample(pct: 80, hosted: false)], threshold: 70, now: t0).isEmpty,
          "an unhosted session (no pane pty) never fires")
    check(monitor.evaluate([sample(pct: 80, age: 300)], threshold: 70, now: t0).isEmpty,
          "a stale session file never fires")
    check(monitor.tripped.isEmpty, "gated-out samples leave no marks")
    // The same session turning idle on a later heartbeat fires then.
    let fired = monitor.evaluate([sample(pct: 80)], threshold: 70, now: t0.addingTimeInterval(3))
    check(fired.count == 1, "the blocked session fires once it idles at the prompt")
}

// MARK: - Hysteresis re-arm

print("== hysteresis ==")
do {
    let monitor = CompactMonitor()
    _ = monitor.evaluate([sample(pct: 72)], threshold: 70, now: t0)
    // Dropping to threshold−2 (inside the band) keeps the mark.
    _ = monitor.evaluate([sample(pct: 68)], threshold: 70, now: t0.addingTimeInterval(3))
    check(monitor.evaluate([sample(pct: 71)], threshold: 70, now: t0.addingTimeInterval(6)).isEmpty,
          "re-crossing from inside the hysteresis band does not re-fire")
    // Dropping below threshold−5 re-arms; the cooldown still holds fire.
    _ = monitor.evaluate([sample(pct: 60)], threshold: 70, now: t0.addingTimeInterval(9))
    check(monitor.tripped.isEmpty, "falling below threshold−5 drops the mark")
    let recross = monitor.evaluate([sample(pct: 72, at: t0.addingTimeInterval(12))],
                                   threshold: 70, now: t0.addingTimeInterval(12))
    check(recross.isEmpty, "an immediate re-cross is still inside the cooldown")
    let later = monitor.evaluate([sample(pct: 72, at: t0.addingTimeInterval(700))],
                                 threshold: 70, now: t0.addingTimeInterval(700))
    check(later.count == 1, "a re-cross after the cooldown fires again")
}

// MARK: - Cooldown pins a compact that failed to lower the pct

print("== cooldown ==")
do {
    let monitor = CompactMonitor()
    _ = monitor.evaluate([sample(pct: 85)], threshold: 70, now: t0)
    // The pct never drops (compact failed / ignored): the mark alone keeps it
    // silent, for hours if need be.
    var quiet = true
    for i in 1...10 {
        let tick = t0.addingTimeInterval(Double(i) * 300)
        quiet = quiet && monitor.evaluate([sample(pct: 85, at: tick)],
                                          threshold: 70, now: tick).isEmpty
    }
    check(quiet, "a compact that fails to lower the pct never re-fires")
}

// MARK: - Vanished sessions clean up

print("== lifecycle ==")
do {
    let monitor = CompactMonitor()
    _ = monitor.evaluate([sample(pct: 80)], threshold: 70, now: t0)
    check(monitor.tripped == ["s1"], "the fired session is marked")
    _ = monitor.evaluate([], threshold: 70, now: t0.addingTimeInterval(3))
    check(monitor.tripped.isEmpty, "a session gone from the batch drops its mark")
}

// MARK: - Threshold changes re-evaluate cleanly

print("== threshold change ==")
do {
    let monitor = CompactMonitor()
    check(monitor.evaluate([sample(pct: 72)], threshold: 80, now: t0).isEmpty,
          "under a higher threshold → no trip")
    let lowered = monitor.evaluate([sample(pct: 72)], threshold: 70, now: t0.addingTimeInterval(3))
    check(lowered.count == 1, "lowering the threshold below the pct trips")
    check(lowered.first?.threshold == 70, "the trip records the threshold it crossed")
}

// MARK: - Independent sessions trip independently

print("== multiple sessions ==")
do {
    let monitor = CompactMonitor()
    let trips = monitor.evaluate(
        [sample("a", pct: 75), sample("b", pct: 40), sample("c", pct: 90, state: "working")],
        threshold: 70, now: t0
    )
    check(trips.map(\.sessionId) == ["a"], "only the idle over-threshold session fires")
    let next = monitor.evaluate(
        [sample("a", pct: 75), sample("b", pct: 71), sample("c", pct: 90)],
        threshold: 70, now: t0.addingTimeInterval(3)
    )
    check(next.map(\.sessionId).sorted() == ["b", "c"],
          "later crossings fire without re-firing the first")
}

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
