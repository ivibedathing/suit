import Foundation

// Auto-/compact guardrails: watch each live Claude session's context-window
// usage (context_pct, written by scripts/claude/suit-statusline.sh) and, when a
// session idles past a configured threshold, send `/compact` with the user's
// focus instructions into its pty — reclaiming context on the user's terms
// before Claude Code's own late, generic auto-compact (~83.5%) has to.
//
// This file is the UI-free, standalone-compilable core (the BudgetGuardrails /
// RoadmapParser pattern, Foundation-only, no AppKit and no app deps), so
// `scripts/compact-guard-test.sh` can compile it in isolation and assert the
// trip logic — fires once at the crossing, only at an idle prompt, re-arms with
// hysteresis, honors the cooldown, and never acts on stale or unhosted
// sessions. The AppKit half lives in CompactGuard.swift (the heartbeat-driven
// monitor) and AppDelegate+Compact.swift (typing the /compact).

// One context observation handed to the monitor. `stateRaw` is the session
// JSON's state string ("working" / "needs-input" / "done") rather than the
// app's ClaudeSessionState so this file compiles with zero app dependencies;
// `hosted` is whether a pane currently hosts the session's pty (only a hosted
// session can be typed into); `updatedAt` is the session file's own timestamp,
// so a stale file — a dead session the monitor hasn't aged out yet — never
// fires.
struct CompactSample: Equatable {
    var sessionId: String
    var title: String
    var contextPct: Double
    var stateRaw: String
    var updatedAt: Date
    var hosted: Bool
}

// A threshold crossing the guard should act on: type /compact into the
// session's pty, notify, and log to the activity feed.
struct CompactTrip: Equatable {
    var sessionId: String
    var title: String
    var contextPct: Double
    var threshold: Int

    // Stable id for notification / activity-feed dedup. Folds the threshold in
    // so a re-cross after the user raises the threshold records anew — the same
    // shape as BudgetTrip.id.
    var id: String {
        "compact-\(sessionId)-\(threshold)"
    }

    // "context 74% ≥ 70% threshold" — the notification body / feed detail.
    var detail: String {
        String(format: "context %.0f%% ≥ %d%% threshold", contextPct, threshold)
    }
}

// The stateful monitor: remembers which sessions already tripped so a crossing
// fires once, not every heartbeat. Pure — the AppKit side builds the samples
// and acts on the returned trips.
final class CompactMonitor {
    // Compaction drops the pct well below the threshold; requiring it to fall
    // this far under before re-arming keeps a reading that hovers right at the
    // line from re-firing on noise.
    static let hysteresis = 5.0
    // A session file this stale describes a pty that may no longer be at the
    // prompt the sample claims — never type into it.
    static let maxSampleAge: TimeInterval = 120

    // Session ids currently tripped, carried between evaluate() calls. A mark
    // holds while the session stays above (threshold − hysteresis) and drops
    // when it falls below or vanishes, so the set can't grow without bound.
    private(set) var tripped: Set<String> = []
    // After a fire, the same session can't fire again until this passes — a
    // /compact that fails to lower the pct (or a bounce off the hysteresis
    // band) must not re-type every heartbeat.
    private var cooldownUntil: [String: Date] = [:]

    // Evaluate a batch of samples against the threshold. Returns the sessions
    // to /compact now: at or above the threshold, idle at the prompt ("done" —
    // never mid-response, never while a permission prompt may own the input
    // line), hosted in a pane, fresh, not already tripped, and off cooldown.
    func evaluate(_ samples: [CompactSample], threshold: Int,
                  now: Date = Date(), cooldown: TimeInterval = 600) -> [CompactTrip] {
        var trips: [CompactTrip] = []
        var live = Set<String>()

        for sample in samples {
            if tripped.contains(sample.sessionId) {
                // Already tripped: hold the mark until the pct falls under the
                // hysteresis band (or the session vanishes from the batch).
                if sample.contextPct >= Double(threshold) - Self.hysteresis {
                    live.insert(sample.sessionId)
                }
                continue
            }
            guard sample.contextPct >= Double(threshold),
                  sample.stateRaw == "done",
                  sample.hosted,
                  now.timeIntervalSince(sample.updatedAt) < Self.maxSampleAge
            else { continue }
            if let until = cooldownUntil[sample.sessionId], until > now { continue }

            trips.append(CompactTrip(
                sessionId: sample.sessionId, title: sample.title,
                contextPct: sample.contextPct, threshold: threshold
            ))
            live.insert(sample.sessionId)
            cooldownUntil[sample.sessionId] = now.addingTimeInterval(cooldown)
        }

        tripped = live
        // Expired cooldowns are dead weight; sessions gone from the batch ended,
        // and their ids never recur (Claude session ids are unique).
        let seen = Set(samples.map(\.sessionId))
        cooldownUntil = cooldownUntil.filter { $0.value > now && seen.contains($0.key) }
        return trips
    }
}
