import Foundation

// Standalone assertion driver for the token-ignore firewall core
// (TokenIgnoreHook.swift, Foundation-only, no app deps) plus the --ignore
// extension of the PostToolUse dispatcher core (PostToolHook.swift), compiled
// by scripts/token-ignore-test.sh. Mirrors the rtk-test driver: no app, no UI
// — just the settings.json transforms, idempotently, preserving every
// unrelated key and hook.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

func json(_ root: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(data: data, encoding: .utf8)!
}

let hookCmd = TokenIgnoreHook.hookCommand

// MARK: - adding

print("== TokenIgnoreHook.adding ==")
let (added, addedChanged) = TokenIgnoreHook.adding(to: [:])
check(addedChanged, "adding to an empty settings dict reports a change")
check(TokenIgnoreHook.isWired(in: added), "after adding, the firewall hook is wired")
check(json(added).contains("PreToolUse"), "the hook lands under PreToolUse")
check(json(added).contains("\"Read\""), "the hook matches the Read tool")
check(json(added).contains(hookCmd), "the hook command points at the firewall script")

print("== TokenIgnoreHook.adding (idempotent) ==")
let (addedTwice, addedTwiceChanged) = TokenIgnoreHook.adding(to: added)
check(!addedTwiceChanged, "adding a second time is a no-op (no change)")
check(TokenIgnoreHook.isWired(in: addedTwice), "still wired after a repeat add")

// MARK: - preservation of unrelated keys and hooks

print("== TokenIgnoreHook preserves foreign config ==")
let foreign: [String: Any] = [
    "model": "opus",
    "hooks": [
        "PreToolUse": [
            ["matcher": "Bash",
             "hooks": [["type": "command", "command": "/home/.suit/scripts/suit-rtk-rewrite.sh"]]],
        ],
        "Stop": [
            ["hooks": [["type": "command", "command": "/home/.suit/scripts/suit-session-state.sh done"]]],
        ],
    ],
]
let (mergedForeign, mergedForeignChanged) = TokenIgnoreHook.adding(to: foreign)
check(mergedForeignChanged, "adding alongside foreign hooks reports a change")
check(TokenIgnoreHook.isWired(in: mergedForeign), "wired alongside foreign hooks")
check(json(mergedForeign).contains("suit-rtk-rewrite.sh"), "the rtk PreToolUse hook survives")
check(json(mergedForeign).contains("suit-session-state.sh"), "the Stop hook survives")
check(json(mergedForeign).contains("\"model\":\"opus\""), "unrelated top-level keys survive")

// MARK: - drifted path repointing

print("== TokenIgnoreHook.adding repoints a drifted command ==")
let drifted: [String: Any] = [
    "hooks": [
        "PreToolUse": [
            ["matcher": "Read",
             "hooks": [["type": "command", "command": "/old/place/suit-token-ignore.sh"]]],
        ],
    ],
]
let (repointed, repointedChanged) = TokenIgnoreHook.adding(to: drifted)
check(repointedChanged, "a drifted install location reports a change")
check(json(repointed).contains(hookCmd), "the command is repointed at the current location")
check(!json(repointed).contains("/old/place/"), "the drifted command is gone")

// MARK: - removing

print("== TokenIgnoreHook.removing ==")
let (removed, removedChanged) = TokenIgnoreHook.removing(from: mergedForeign)
check(removedChanged, "removing an installed hook reports a change")
check(!TokenIgnoreHook.isWired(in: removed), "no longer wired after removal")
check(json(removed).contains("suit-rtk-rewrite.sh"), "the rtk hook survives removal")
check(json(removed).contains("suit-session-state.sh"), "the Stop hook survives removal")
let (removedTwice, removedTwiceChanged) = TokenIgnoreHook.removing(from: removed)
check(!removedTwiceChanged, "removing again is a no-op")
_ = removedTwice
let (removedEmpty, removedEmptyChanged) = TokenIgnoreHook.removing(from: [:])
check(!removedEmptyChanged, "removing from empty settings is a no-op")
_ = removedEmpty

let (justOurs, _) = TokenIgnoreHook.adding(to: [:])
let (cleaned, cleanedChanged) = TokenIgnoreHook.removing(from: justOurs)
check(cleanedChanged, "removing the only hook reports a change")
check((cleaned["hooks"] == nil), "an empty hooks map is dropped entirely")

// MARK: - PostToolHook --ignore flag

print("== PostToolHook.filterCommand with ignore ==")
check(PostToolHook.filterCommand(compress: false, dedup: false) == nil,
      "all toggles off → no command (unchanged default)")
check(PostToolHook.filterCommand(compress: false, dedup: false, ignore: true) ==
      PostToolHook.scriptPath + " --ignore",
      "ignore alone yields a --ignore command")
check(PostToolHook.filterCommand(compress: true, dedup: true, ignore: true) ==
      PostToolHook.scriptPath + " --compress --dedup --ignore",
      "all three flags compose in order")

print("== PostToolHook.applying with ignore ==")
let (igApplied, igChanged) = PostToolHook.applying(to: [:], compress: false, dedup: false, ignore: true)
check(igChanged, "applying ignore-only to empty settings reports a change")
check(json(igApplied).contains("--ignore"), "the PostToolUse entry carries --ignore")
check(!json(igApplied).contains("PreCompact"), "ignore alone adds no dedup lifecycle entries")
let (igOff, igOffChanged) = PostToolHook.applying(to: igApplied, compress: false, dedup: false, ignore: false)
check(igOffChanged, "turning ignore back off reports a change")
check(!PostToolHook.isWired(in: igOff), "the dispatcher entry is gone with every toggle off")
let (igAgain, igAgainChanged) = PostToolHook.applying(to: igApplied, compress: false, dedup: false, ignore: true)
check(!igAgainChanged, "re-applying the same ignore state is a no-op")
_ = igAgain

if failures > 0 {
    print("\(failures) FAILURE(S)")
    exit(1)
}
print("all core assertions passed")
