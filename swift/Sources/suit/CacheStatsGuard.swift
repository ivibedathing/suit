import Foundation

// The heartbeat-driven half of the cache hit-rate meter (pure core:
// CacheStats.swift). Every tick it refreshes each live session's rolling
// hit rate from its transcript tail — at most once per recomputeInterval and
// only when the transcript actually grew, so the steady-state tick costs a
// stat() per session — then runs the edge-triggered monitor and hands new
// collapses to the app (attention-center notification). The fleet dashboard
// reads hitRatePct(forSession:) for its per-row readout. Main-thread only
// (called from AppDelegate's heartbeat, like BudgetGuard / CompactGuard).
final class CacheStatsGuard {
    static let recomputeInterval: TimeInterval = 15

    private struct Entry {
        var transcriptSize: UInt64
        var computedAt: Date
        var hitRatePct: Double?
        var turnCount: Int
    }

    private var entries: [String: Entry] = [:]
    private let monitor = CacheHitMonitor()
    private let onAlert: (CacheAlert) -> Void

    init(onAlert: @escaping (CacheAlert) -> Void) {
        self.onAlert = onAlert
    }

    // The dashboard's readout: the last computed rolling hit rate, nil until
    // a session has a measurable transcript.
    func hitRatePct(forSession id: String) -> Double? {
        entries[id]?.hitRatePct
    }

    func tick(sessions: [ClaudeSession]) {
        var samples: [CacheSample] = []
        var liveIds: Set<String> = []

        for session in sessions {
            guard let path = session.transcriptPath, !path.isEmpty else { continue }
            liveIds.insert(session.id)

            let now = Date()
            let existing = entries[session.id]
            var entry = existing
            let due = existing.map { now.timeIntervalSince($0.computedAt) >= Self.recomputeInterval } ?? true
            if due {
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                let size = (attributes?[.size] as? NSNumber).map { UInt64(truncating: $0) } ?? 0
                if existing?.transcriptSize != size || existing == nil {
                    let turns = CacheStats.tail(ofFile: path).map(CacheStats.turns(fromTranscriptTail:)) ?? []
                    entry = Entry(transcriptSize: size, computedAt: now,
                                  hitRatePct: CacheStats.hitRatePct(turns),
                                  turnCount: turns.count)
                } else {
                    entry?.computedAt = now
                }
                entries[session.id] = entry
            }

            if let entry, let pct = entry.hitRatePct {
                samples.append(CacheSample(sessionId: session.id,
                                           title: session.displayName,
                                           hitRatePct: pct,
                                           turnCount: entry.turnCount))
            }
        }

        // Ended sessions drop out so the map can't grow without bound (and the
        // monitor re-arms them implicitly by their absence from the samples).
        entries = entries.filter { liveIds.contains($0.key) }

        for alert in monitor.evaluate(samples) {
            onAlert(alert)
        }
    }
}
