import Cocoa

// The AppKit acting side of the auto-/compact guardrails: a trip types
// `/compact <instructions>` into the session's pty (the same path as the
// context meter's one-tap /compact), notifies, and logs to the activity feed.
// The monitor already deduped (hysteresis + cooldown), so this fires once per
// crossing.
extension AppDelegate {
    func handleCompactTrip(_ trip: CompactTrip) {
        // The sample said "hosted" this same heartbeat, but re-resolve — a pane
        // that closed in between just means the trip is dropped (the cooldown
        // keeps the retry from hammering).
        guard let terminal = terminalContent(forSessionId: trip.sessionId) else { return }

        let instructions = autoCompactInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = instructions.isEmpty ? "/compact" : "/compact " + instructions
        SessionControl.send(text: command, to: terminal, submit: true)

        // Quiet news: banner only while Suit is in the background (no
        // willPresent exception), click focuses the session.
        attentionCenter?.postBudgetEvent(
            title: "Auto-compact · \(trip.title)",
            body: trip.detail,
            identifier: trip.id,
            sessionId: trip.sessionId
        )

        activityRecorder.record(ActivityEvent(
            id: trip.id,
            kind: .autoCompacted,
            timestamp: Date().timeIntervalSince1970,
            title: "Auto-compact · \(trip.title)",
            detail: trip.detail,
            repo: nil,
            sessionId: trip.sessionId,
            worktree: nil
        ))
    }
}
