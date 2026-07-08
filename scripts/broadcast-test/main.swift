import Foundation

// Standalone logic test for the Phase 35 broadcast core. Compiled with only
// swift/Sources/suit/Broadcast.swift (Foundation-only, no app deps), the
// RoadmapParser/FeedbackRouting/DiffReview standalone-test pattern. Exercises
// the pure target resolution (scope × hosted × fleet order, dedup) and the
// fan-out confirm rule against fixtures with known answers. Prints PASS/FAIL
// lines and exits non-zero on any failure.

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}

// The fleet's needs-you-first order, as FleetModel would hand it over. Some are
// hosted (steerable), some are orphaned "done" files that outlived their pane.
let order = ["s-needs", "s-busy", "s-done", "s-orphan"]
let hosted: Set<String> = ["s-needs", "s-busy", "s-done"]   // s-orphan not hosted

// MARK: - All-live scope

do {
    let ids = Broadcast.targetIds(orderedSessionIds: order, hostedIds: hosted, scope: .allLive)
    check("allLive: keeps only hosted", ids == ["s-needs", "s-busy", "s-done"])
    check("allLive: drops the orphan", !ids.contains("s-orphan"))
    check("allLive: preserves fleet order", ids == order.filter { hosted.contains($0) })
}

// MARK: - Selected scope

do {
    let ids = Broadcast.targetIds(orderedSessionIds: order, hostedIds: hosted, scope: .selected(["s-done", "s-needs"]))
    check("selected: intersects with checks", Set(ids) == ["s-needs", "s-done"])
    check("selected: still in fleet order", ids == ["s-needs", "s-done"])
}

do {
    // A checked row whose tab has since closed (checked but no longer hosted)
    // silently drops rather than erroring.
    let ids = Broadcast.targetIds(orderedSessionIds: order, hostedIds: hosted, scope: .selected(["s-orphan", "s-busy"]))
    check("selected: drops checked-but-unhosted", ids == ["s-busy"])
}

do {
    let ids = Broadcast.targetIds(orderedSessionIds: order, hostedIds: hosted, scope: .selected([]))
    check("selected: empty selection → no targets", ids.isEmpty)
}

// MARK: - Dedup / edge cases

do {
    let dupOrder = ["a", "a", "b"]
    let ids = Broadcast.targetIds(orderedSessionIds: dupOrder, hostedIds: ["a", "b"], scope: .allLive)
    check("dedup: a repeated id resolves once", ids == ["a", "b"])
}

do {
    let ids = Broadcast.targetIds(orderedSessionIds: [], hostedIds: [], scope: .allLive)
    check("empty fleet → no targets", ids.isEmpty)
}

// MARK: - Confirm rule

check("confirm: single target sends without ceremony", Broadcast.needsConfirmation(targetCount: 1) == false)
check("confirm: zero targets never confirms", Broadcast.needsConfirmation(targetCount: 0) == false)
check("confirm: two targets gates", Broadcast.needsConfirmation(targetCount: 2) == true)
check("confirm: many targets gates", Broadcast.needsConfirmation(targetCount: 9) == true)

// MARK: - Labels

check("label: singular", Broadcast.sessionCountLabel(1) == "1 session")
check("label: plural", Broadcast.sessionCountLabel(3) == "3 sessions")
check("confirmMessage: names the count", Broadcast.confirmMessage(targetCount: 4) == "Send this to 4 sessions at once?")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
