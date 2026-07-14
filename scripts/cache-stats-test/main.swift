import Foundation

// Standalone assertion driver for the cache hit-rate meter core
// (CacheStats.swift, Foundation-only, no app deps), compiled by
// scripts/cache-stats-test.sh. Covers the transcript-JSONL usage parsing
// (assistant filter, streamed-line dedupe, malformed-line tolerance), the
// rolling hit-rate math, the whole-lines file tail, and the edge-triggered
// monitor's fire-once / hysteresis / re-arm behavior.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

// Builds one transcript JSONL line.
func assistantLine(id: String, input: Int, read: Int, creation: Int) -> String {
    """
    {"type":"assistant","message":{"id":"\(id)","usage":{"input_tokens":\(input),\
    "cache_read_input_tokens":\(read),"cache_creation_input_tokens":\(creation),\
    "output_tokens":50}},"session_id":"s1"}
    """.replacingOccurrences(of: "\n", with: "")
}

// MARK: - turns parsing

print("== CacheStats.turns ==")
let transcript = [
    #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
    assistantLine(id: "msg_1", input: 12, read: 0, creation: 9000),
    #"{"type":"system","subtype":"info"}"#,
    assistantLine(id: "msg_2", input: 8, read: 9000, creation: 400),
    assistantLine(id: "msg_2", input: 8, read: 9000, creation: 400),
    "not json at all",
    #"{"type":"assistant","message":{"id":"msg_3"}}"#,
    assistantLine(id: "msg_4", input: 5, read: 9400, creation: 100),
].joined(separator: "\n")

let turns = CacheStats.turns(fromTranscriptTail: transcript)
check(turns.count == 3, "user/system/malformed/usage-less lines are skipped; streamed duplicate collapses (3 turns)")
check(turns.first?.cacheCreationTokens == 9000, "the first turn's creation tokens parse")
check(turns.dropFirst().first?.cacheReadTokens == 9000, "the deduped turn keeps its usage")
check(turns.last?.messageId == "msg_4", "order is preserved")

// MARK: - hit-rate math

print("== CacheStats.hitRatePct ==")
check(CacheStats.hitRatePct([]) == nil, "no turns → nil (unmeasured, not 0)")
let zero = [CacheTurn(messageId: nil, inputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)]
check(CacheStats.hitRatePct(zero) == nil, "a window with zero input tokens → nil")
let warm = [
    CacheTurn(messageId: nil, inputTokens: 10, cacheReadTokens: 0, cacheCreationTokens: 90),
    CacheTurn(messageId: nil, inputTokens: 10, cacheReadTokens: 90, cacheCreationTokens: 0),
]
check(abs((CacheStats.hitRatePct(warm) ?? 0) - 45.0) < 0.001,
      "90 read of 200 total input = 45%")
var windowed = Array(repeating: CacheTurn(messageId: nil, inputTokens: 100, cacheReadTokens: 0, cacheCreationTokens: 0), count: 10)
windowed += Array(repeating: CacheTurn(messageId: nil, inputTokens: 0, cacheReadTokens: 100, cacheCreationTokens: 0), count: 5)
check(abs((CacheStats.hitRatePct(windowed) ?? 0) - 100.0) < 0.001,
      "only the last window (5) turns count — old cold turns age out")

// MARK: - file tail

print("== CacheStats.tail ==")
let tmp = NSTemporaryDirectory() + "cache-stats-test-\(ProcessInfo.processInfo.processIdentifier).jsonl"
defer { try? FileManager.default.removeItem(atPath: tmp) }
let lines = (0..<50).map { assistantLine(id: "msg_\($0)", input: 10, read: 100, creation: 0) }
try! lines.joined(separator: "\n").write(toFile: tmp, atomically: true, encoding: .utf8)
let whole = CacheStats.tail(ofFile: tmp, maxBytes: 1_000_000)
check(whole?.hasPrefix("{\"type\":\"assistant\"") == true, "a small file comes back whole")
check(CacheStats.turns(fromTranscriptTail: whole ?? "").count == 50, "…and fully parseable")
let cut = CacheStats.tail(ofFile: tmp, maxBytes: 400)
check(cut != nil && cut!.hasPrefix("{"), "a mid-line cut drops the partial first line")
check(CacheStats.turns(fromTranscriptTail: cut ?? "").count >= 1, "…leaving whole parseable lines")
check(CacheStats.tail(ofFile: tmp + ".missing") == nil, "a missing file → nil")

// MARK: - edge-triggered monitor

print("== CacheHitMonitor ==")
func sample(_ pct: Double, turns: Int = 8, id: String = "s1") -> CacheSample {
    CacheSample(sessionId: id, title: "worker", hitRatePct: pct, turnCount: turns)
}
let monitor = CacheHitMonitor()
check(monitor.evaluate([sample(20, turns: 3)]).isEmpty,
      "a collapsed rate with too few turns never fires (early session)")
let first = monitor.evaluate([sample(20)])
check(first.count == 1, "a collapse with a full window fires once")
check(first.first?.id == "cache-collapse-s1", "the alert id is stable per session")
check(first.first?.detail.contains("CLAUDE.md") == true, "the detail names the likely cause")
check(monitor.evaluate([sample(20)]).isEmpty, "a sustained collapse does not re-fire")
check(monitor.evaluate([sample(48)]).isEmpty, "recovery into the hysteresis band does not re-fire…")
check(monitor.evaluate([sample(30)]).isEmpty, "…and dropping back from the band does not re-fire either")
check(monitor.evaluate([sample(80)]).isEmpty, "full recovery fires nothing")
check(monitor.evaluate([sample(20)]).count == 1, "a genuine second collapse after recovery fires again")
check(monitor.evaluate([]).isEmpty && monitor.evaluate([sample(20)]).count == 1,
      "a vanished session re-arms; its next collapse is fresh news")

let two = CacheHitMonitor()
let both = two.evaluate([sample(20, id: "a"), sample(90, id: "b"), sample(10, id: "c")])
check(both.count == 2 && Set(both.map { $0.sessionId }) == ["a", "c"],
      "sessions trip independently")

if failures > 0 {
    print("\(failures) FAILURE(S)")
    exit(1)
}
print("all assertions passed")
