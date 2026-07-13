import Foundation

// Standalone assertion driver for the PostToolUse output-filter hook core
// (PostToolHook.swift, Foundation-only, no app deps), compiled by
// scripts/posttool-test.sh. Mirrors the RtkHook standalone-test pattern: just
// the settings.json transform that wires the dispatcher hook set (PostToolUse,
// plus PreCompact/SessionEnd for dedup) in and out, idempotently, rewriting
// flags in place and preserving every unrelated key and hook.

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

let script = PostToolHook.scriptPath

// MARK: - filterCommand

print("== PostToolHook.filterCommand ==")
check(PostToolHook.filterCommand(compress: true, dedup: false) == script + " --compress",
      "compress alone → --compress")
check(PostToolHook.filterCommand(compress: false, dedup: true) == script + " --dedup",
      "dedup alone → --dedup")
check(PostToolHook.filterCommand(compress: true, dedup: true) == script + " --compress --dedup",
      "both → --compress --dedup")
check(PostToolHook.filterCommand(compress: false, dedup: false) == nil,
      "neither → no hook at all")

// MARK: - applying (compress only)

print("== applying (compress) ==")
let (compressed, compressedChanged) = PostToolHook.applying(to: [:], compress: true, dedup: false)
check(compressedChanged, "applying to an empty settings dict reports a change")
check(PostToolHook.isWired(in: compressed), "after applying, the hook is wired")
check(json(compressed).contains("PostToolUse"), "the hook lands under PostToolUse")
check(json(compressed).contains("Read|Grep|Glob|Bash"), "the matcher covers the four tools")
check(json(compressed).contains(script + " --compress"), "the command carries --compress")
check(!json(compressed).contains("PreCompact") && !json(compressed).contains("SessionEnd"),
      "compress alone installs no cache-lifecycle hooks")

print("== applying (idempotent) ==")
let (again, againChanged) = PostToolHook.applying(to: compressed, compress: true, dedup: false)
check(!againChanged, "re-applying the same state is a no-op")
check(PostToolHook.isWired(in: again), "still wired after a repeat apply")

// MARK: - flag rewrite in place

print("== applying (flag change) ==")
let (both, bothChanged) = PostToolHook.applying(to: compressed, compress: true, dedup: true)
check(bothChanged, "turning dedup on reports a change")
check(json(both).contains(script + " --compress --dedup"), "the PostToolUse command gains --dedup in place")
// Structural: exactly one of our hooks under PostToolUse (rewritten, not duplicated).
let bothEntries = ((both["hooks"] as? [String: Any])?["PostToolUse"] as? [[String: Any]]) ?? []
let ours = bothEntries.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
    .filter { ($0["command"] as? String)?.contains("suit-posttool-filter.sh") == true }
check(ours.count == 1, "still exactly one Suit PostToolUse hook after the flag change")
check(json(both).contains("PreCompact"), "dedup installs the PreCompact cache-clear hook")
check(json(both).contains(script + " --clear-cache"), "PreCompact points at --clear-cache")
check(json(both).contains("SessionEnd"), "dedup installs the SessionEnd cleanup hook")
check(json(both).contains(script + " --end-session"), "SessionEnd points at --end-session")

let (backOff, backOffChanged) = PostToolHook.applying(to: both, compress: true, dedup: false)
check(backOffChanged, "turning dedup back off reports a change")
check(!json(backOff).contains("PreCompact") && !json(backOff).contains("SessionEnd"),
      "dedup off removes the cache-lifecycle hooks")
check(json(backOff).contains(script + " --compress"), "the PostToolUse hook stays for compress")

// MARK: - preservation of foreign config

print("== preserves foreign config ==")
let foreign: [String: Any] = [
    "model": "opus",
    "hooks": [
        "PostToolUse": [
            ["matcher": "Edit|Write",
             "hooks": [["type": "command", "command": "/other/formatter.sh"]]],
        ],
        "PreToolUse": [
            ["matcher": "Bash",
             "hooks": [["type": "command", "command": "/home/.suit/scripts/suit-rtk-rewrite.sh"]]],
        ],
        "PreCompact": [
            ["hooks": [["type": "command", "command": "/other/precompact.sh"]]],
        ],
    ],
]
let (merged, mergedChanged) = PostToolHook.applying(to: foreign, compress: true, dedup: true)
check(mergedChanged, "applying into a populated dict reports a change")
check(json(merged).contains("/other/formatter.sh"), "a foreign PostToolUse hook is preserved")
check(json(merged).contains("suit-rtk-rewrite.sh"), "the rtk PreToolUse hook is preserved")
check(json(merged).contains("/other/precompact.sh"), "a foreign PreCompact hook is preserved")
check(json(merged).contains("opus"), "an unrelated top-level key is preserved")

print("== removing everything ==")
let (removed, removedChanged) = PostToolHook.applying(to: merged, compress: false, dedup: false)
check(removedChanged, "turning both toggles off reports a change")
check(!PostToolHook.isWired(in: removed), "after removal, no Suit post-tool hook remains")
check(json(removed).contains("/other/formatter.sh"), "removal leaves the foreign PostToolUse hook")
check(json(removed).contains("/other/precompact.sh"), "removal leaves the foreign PreCompact hook")
check(json(removed).contains("suit-rtk-rewrite.sh"), "removal leaves the rtk hook")

print("== no-op removal ==")
let (noop, noopChanged) = PostToolHook.applying(to: [:], compress: false, dedup: false)
check(!noopChanged, "removing from a dict with no hook is a no-op")
check(!PostToolHook.isWired(in: noop), "still not wired")

// MARK: - drifted path repoint

print("== drifted install path ==")
let drifted: [String: Any] = [
    "hooks": [
        "PostToolUse": [
            ["matcher": "Read|Grep|Glob|Bash",
             "hooks": [["type": "command", "command": "/old/place/suit-posttool-filter.sh --compress"]]],
        ],
    ],
]
let (repointed, repointedChanged) = PostToolHook.applying(to: drifted, compress: true, dedup: false)
check(repointedChanged, "a drifted script path reports a change")
check(json(repointed).contains(script + " --compress"), "the command is repointed at the current install dir")
check(!json(repointed).contains("/old/place/"), "the stale path is gone")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
