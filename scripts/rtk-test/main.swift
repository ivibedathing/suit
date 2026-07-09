import Foundation

// Standalone assertion driver for the rtk output-compression hook core
// (RtkHook.swift, Foundation-only, no app deps), compiled by scripts/rtk-test.sh.
// Mirrors the RoadmapParser / Recipes / FeedbackRouting standalone-test pattern:
// no app, no UI — just the settings.json transform that wires the rtk PreToolUse
// hook in and out, idempotently, preserving every unrelated key and hook.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

// Serialize a settings dict to a JSON string so tests can assert on structure
// without hand-walking [String: Any].
func json(_ root: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(data: data, encoding: .utf8)!
}

let hookCmd = RtkHook.hookCommand

// MARK: - adding

print("== RtkHook.adding ==")
let (added, addedChanged) = RtkHook.adding(to: [:])
check(addedChanged, "adding to an empty settings dict reports a change")
check(RtkHook.isWired(in: added), "after adding, the rtk hook is wired")
check(json(added).contains("PreToolUse"), "the hook lands under PreToolUse")
check(json(added).contains("\"Bash\""), "the hook matches the Bash tool")
check(json(added).contains(hookCmd), "the hook command points at the rtk-rewrite script")

// MARK: - idempotency

print("== RtkHook.adding (idempotent) ==")
let (addedTwice, addedTwiceChanged) = RtkHook.adding(to: added)
check(!addedTwiceChanged, "adding a second time is a no-op (no change)")
check(RtkHook.isWired(in: addedTwice), "still wired after a repeat add")

// MARK: - preservation of unrelated keys and hooks

print("== RtkHook preserves foreign config ==")
let foreign: [String: Any] = [
    "model": "opus",
    "hooks": [
        "PreToolUse": [
            ["matcher": "Bash",
             "hooks": [["type": "command", "command": "/other/thing.sh"]]],
        ],
        "Stop": [
            ["hooks": [["type": "command", "command": "/home/.suit/scripts/suit-session-state.sh done"]]],
        ],
    ],
]
let (mergedForeign, mergedForeignChanged) = RtkHook.adding(to: foreign)
check(mergedForeignChanged, "adding into a populated dict reports a change")
check(RtkHook.isWired(in: mergedForeign), "rtk hook wired alongside foreign hooks")
check(json(mergedForeign).contains("/other/thing.sh"), "a foreign PreToolUse hook is preserved")
check(json(mergedForeign).contains("suit-session-state.sh done"), "the Suit session-state Stop hook is preserved")
check(json(mergedForeign).contains("\"model\":\"opus\"") || json(mergedForeign).contains("\"model\" : \"opus\""), "an unrelated top-level key is preserved")

// MARK: - removing

print("== RtkHook.removing ==")
let (removed, removedChanged) = RtkHook.removing(from: mergedForeign)
check(removedChanged, "removing an installed rtk hook reports a change")
check(!RtkHook.isWired(in: removed), "after removing, the rtk hook is gone")
check(json(removed).contains("/other/thing.sh"), "removing leaves the foreign PreToolUse hook intact")
check(json(removed).contains("suit-session-state.sh done"), "removing leaves the session-state hook intact")
check(json(removed).contains("opus"), "removing leaves unrelated keys intact")

// MARK: - removing when absent

print("== RtkHook.removing (absent) ==")
let (removedAbsent, removedAbsentChanged) = RtkHook.removing(from: [:])
check(!removedAbsentChanged, "removing from a dict with no rtk hook is a no-op")
check(!RtkHook.isWired(in: removedAbsent), "still not wired")

// MARK: - isWired on bare input

print("== RtkHook.isWired ==")
check(!RtkHook.isWired(in: [:]), "an empty dict is not wired")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
