import Cocoa

// The AppKit half of the auto-/compact guardrails. Each session heartbeat it
// reads the live sessions' context_pct, builds CompactSamples (state, file
// freshness, whether a pane hosts the pty), and runs them through the pure
// CompactMonitor. A new trip is handed to `onTrip` — AppDelegate types
// `/compact <instructions>` into the session and logs it. Edge-triggered via
// the monitor's hysteresis + cooldown, so a crossing acts once, not every
// heartbeat.
final class CompactGuard {
    private let monitor = CompactMonitor()
    private let enabled: () -> Bool
    private let threshold: () -> Int
    private let hosted: (String) -> Bool
    private let onTrip: (CompactTrip) -> Void

    init(enabled: @escaping () -> Bool,
         threshold: @escaping () -> Int,
         hosted: @escaping (String) -> Bool,
         onTrip: @escaping (CompactTrip) -> Void) {
        self.enabled = enabled
        self.threshold = threshold
        self.hosted = hosted
        self.onTrip = onTrip
    }

    // Driven from AppDelegate's 3 s session heartbeat. Skips the whole pass
    // when the toggle is off (the default), so auto-compact-off costs nothing.
    func tick(sessions: [ClaudeSession]) {
        guard enabled() else {
            // Off: drop any stale marks so re-enabling starts clean.
            _ = monitor.evaluate([], threshold: 100)
            return
        }
        let samples = sessions.compactMap { session -> CompactSample? in
            guard let pct = session.contextPct else { return nil }
            return CompactSample(
                sessionId: session.id,
                title: session.displayName,
                contextPct: pct,
                stateRaw: session.state.rawValue,
                updatedAt: session.updatedAt,
                hosted: hosted(session.id)
            )
        }
        for trip in monitor.evaluate(samples, threshold: threshold()) {
            onTrip(trip)
        }
    }
}
