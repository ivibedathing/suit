import Foundation

// Cache hit-rate meter — the pure, UI-free, standalone-compilable core (the
// RoadmapParser / BudgetGuardrails pattern; verified by
// scripts/cache-stats-test.sh). Prompt-cache misses silently multiply input
// cost ~10× and are invisible in every existing readout: Claude Code's
// per-turn `usage` blocks live only in the transcript JSONL. This core turns
// a transcript tail into a rolling cache-hit percentage — cache-read tokens
// as a share of all input tokens over the last few turns — and provides the
// edge-triggered monitor (the BudgetMonitor pattern, plus hysteresis) that
// fires one alert per collapse instead of one per heartbeat. The AppKit half
// lives in CacheStatsGuard.swift (heartbeat-driven, feeds the fleet
// dashboard's per-row readout and the attention center).

// One API response's usage, extracted from an assistant transcript line.
struct CacheTurn: Equatable {
    var messageId: String?
    var inputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int

    var totalInputTokens: Int { inputTokens + cacheReadTokens + cacheCreationTokens }
}

enum CacheStats {
    /// Rolling window: the hit rate is computed over this many recent turns.
    static let window = 5
    /// A hit rate under this (in %) with a full window of turns is a collapse.
    static let alertThresholdPct = 40.0
    /// Re-arm only after recovery past this (hysteresis, so a rate hovering
    /// around the alert threshold can't fire repeatedly).
    static let rearmThresholdPct = 55.0
    /// Don't judge a session before it has this many measured turns — the
    /// first turns of any session legitimately create cache rather than read it.
    static let minTurns = 5
    /// How much of the transcript tail to read; enough for far more than
    /// `window` turns without ever paying for a 100 MB transcript.
    static let tailBytes = 262_144

    // Assistant lines' usage blocks, in transcript order. A single API
    // response can stream as several consecutive transcript lines sharing
    // message.id (one per content block) with the same usage — a run of equal
    // ids collapses to one turn (the last line wins). Anything unparseable is
    // skipped: the meter degrades to fewer turns, never to a crash.
    static func turns(fromTranscriptTail text: String) -> [CacheTurn] {
        var out: [CacheTurn] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (object["type"] as? String) == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            func count(_ key: String) -> Int {
                (usage[key] as? NSNumber)?.intValue ?? 0
            }
            let turn = CacheTurn(
                messageId: message["id"] as? String,
                inputTokens: count("input_tokens"),
                cacheReadTokens: count("cache_read_input_tokens"),
                cacheCreationTokens: count("cache_creation_input_tokens")
            )
            if let last = out.last, let id = turn.messageId, last.messageId == id {
                out[out.count - 1] = turn
            } else {
                out.append(turn)
            }
        }
        return out
    }

    // The rolling hit rate (0–100) over the last `window` turns: cache-read
    // tokens as a share of all input tokens (fresh + cache-read +
    // cache-creation). nil when the window carries no input at all.
    static func hitRatePct(_ turns: [CacheTurn], window: Int = CacheStats.window) -> Double? {
        let recent = turns.suffix(window)
        let read = recent.reduce(0) { $0 + $1.cacheReadTokens }
        let total = recent.reduce(0) { $0 + $1.totalInputTokens }
        guard total > 0 else { return nil }
        return Double(read) / Double(total) * 100
    }

    // The last `maxBytes` of a file as text, whole lines only: when the read
    // starts mid-file, everything up to the first newline is dropped (a
    // partial JSONL line can't parse and would just be noise). nil when the
    // file can't be opened/read.
    static func tail(ofFile path: String, maxBytes: Int = tailBytes) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if offset > 0, let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        return text
    }
}

// One session's measurement handed to the monitor per heartbeat.
struct CacheSample: Equatable {
    var sessionId: String
    var title: String
    var hitRatePct: Double
    var turnCount: Int
}

// A cache collapse worth telling the user about.
struct CacheAlert: Equatable {
    var sessionId: String
    var title: String
    var hitRatePct: Double

    var id: String { "cache-collapse-\(sessionId)" }
    var detail: String {
        String(format: "Prompt-cache hit rate is %.0f%% over the last %d turns — "
               + "input tokens are billing near full price. The usual cause is the "
               + "prompt prefix going cold: CLAUDE.md, hook scripts, or MCP config "
               + "changed mid-session. Consider finishing up or restarting the session.",
               hitRatePct, CacheStats.window)
    }
}

// The stateful edge trigger: one alert per collapse, re-armed only after the
// rate recovers past the hysteresis threshold (or the session vanishes) —
// the BudgetMonitor pattern with hysteresis, pure so the harness can drive
// it with synthetic samples.
final class CacheHitMonitor {
    private(set) var tripped: Set<String> = []

    func evaluate(_ samples: [CacheSample]) -> [CacheAlert] {
        var alerts: [CacheAlert] = []
        var stillTripped: Set<String> = []
        for sample in samples {
            let measured = sample.turnCount >= CacheStats.minTurns
            if measured, sample.hitRatePct < CacheStats.alertThresholdPct {
                stillTripped.insert(sample.sessionId)
                if !tripped.contains(sample.sessionId) {
                    alerts.append(CacheAlert(sessionId: sample.sessionId,
                                             title: sample.title,
                                             hitRatePct: sample.hitRatePct))
                }
            } else if tripped.contains(sample.sessionId),
                      sample.hitRatePct < CacheStats.rearmThresholdPct {
                // Above the alert line but under the re-arm line (or too few
                // turns): keep the mark — hovering must not re-fire.
                stillTripped.insert(sample.sessionId)
            }
        }
        tripped = stillTripped
        return alerts
    }
}
