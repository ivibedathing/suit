import Foundation

// Standalone assertion driver for the notification-sound core, compiled
// against swift/Sources/suit/NotificationSoundCore.swift (Foundation-only) by
// scripts/notification-sound-test.sh. Mirrors the Recipes / RoadmapParser
// standalone-test pattern: no app, no UI — only the transition-to-event
// decision (which events fire, gating by the two enable flags, dedup, and
// the no-transition / no-repeat rule).

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

let bothOn = NotificationSoundSettings(taskDoneEnabled: true, needsInputEnabled: true)

print("== done transition ==")
let done = notificationSoundEvents(
    previousStates: ["a": .working],
    currentStates: [("a", .done)],
    settings: bothOn
)
check(done == [.taskDone], "working → done yields [.taskDone] when enabled")

let doneOff = notificationSoundEvents(
    previousStates: ["a": .working],
    currentStates: [("a", .done)],
    settings: NotificationSoundSettings(taskDoneEnabled: false, needsInputEnabled: true)
)
check(doneOff == [], "working → done yields [] when taskDone disabled")

print("== needs-input transition ==")
let needs = notificationSoundEvents(
    previousStates: ["a": .working],
    currentStates: [("a", .needsInput)],
    settings: bothOn
)
check(needs == [.needsInput], "working → needsInput yields [.needsInput] when enabled")

let needsOff = notificationSoundEvents(
    previousStates: ["a": .working],
    currentStates: [("a", .needsInput)],
    settings: NotificationSoundSettings(taskDoneEnabled: true, needsInputEnabled: false)
)
check(needsOff == [], "working → needsInput yields [] when needsInput disabled")

print("== no transition ==")
let stayDone = notificationSoundEvents(
    previousStates: ["a": .done],
    currentStates: [("a", .done)],
    settings: bothOn
)
check(stayDone == [], "done → done yields [] (no repeat)")

let firstSeenWorking = notificationSoundEvents(
    previousStates: [:],
    currentStates: [("a", .working)],
    settings: bothOn
)
check(firstSeenWorking == [], "newly-seen working session yields no event")

print("== first-seen already-terminal ==")
let firstSeenDone = notificationSoundEvents(
    previousStates: [:],
    currentStates: [("a", .done)],
    settings: bothOn
)
check(firstSeenDone == [.taskDone], "newly-seen done session (no previous) counts as a transition")

print("== dedup ==")
let twoDone = notificationSoundEvents(
    previousStates: ["a": .working, "b": .working],
    currentStates: [("a", .done), ("b", .done)],
    settings: bothOn
)
check(twoDone == [.taskDone], "two sessions both newly done yield a single .taskDone")

print("== both events, fixed order ==")
let both = notificationSoundEvents(
    previousStates: ["a": .working, "b": .working],
    currentStates: [("a", .needsInput), ("b", .done)],
    settings: bothOn
)
check(both == [.taskDone, .needsInput], "one of each yields both, .taskDone first")

if failures == 0 {
    print("ALL PASS")
    exit(0)
} else {
    print("\(failures) FAILED")
    exit(1)
}
