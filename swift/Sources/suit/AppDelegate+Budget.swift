import Cocoa

// The AppKit acting side of Phase 42's cost budget guardrails: assembles the
// live BudgetCaps from settings, handles a trip (notify · opt-in interrupt ·
// log to the activity feed), and the per-session "Set Budget…" override that
// the fleet dashboard and palette drive.
extension AppDelegate {
    // The current ceilings, read live by the guard each heartbeat. 0 → "no
    // ceiling" (BudgetCaps treats ≤ 0 as unset).
    func budgetCaps() -> BudgetCaps {
        BudgetCaps(
            sessionCap: budgetSessionCap,
            taskCap: budgetTaskCap,
            perSession: budgetPerSession
        )
    }

    // A cap crossing: warn always (a notification, never silent), interrupt when
    // auto-interrupt is on (Esc over the run's pty), and record every trip to
    // the activity feed. The monitor already deduped, so this fires once.
    func handleBudgetTrip(_ trip: BudgetTrip) {
        let scopeWord = trip.scope == .task ? "Task" : "Session"
        let title = "\(scopeWord) over budget · \(trip.title)"

        // Interrupt first (opt-in): halt the run before the banner, so the Esc
        // lands even if the user is away. Only a hosted session's pty can be
        // written; a "done"/unhosted row just warns.
        var interrupted = false
        if trip.shouldInterrupt, let terminal = terminalContent(forSessionId: trip.sessionId) {
            SessionControl.interrupt(terminal)
            interrupted = true
        }

        var body = trip.detail
        if trip.shouldInterrupt {
            body += interrupted ? " · interrupted" : " · could not interrupt (not hosted)"
        }
        attentionCenter?.postBudgetEvent(
            title: title, body: body, identifier: trip.id, sessionId: trip.sessionId
        )

        // Activity feed (ROADMAP Phase 38): every trip is a row, deduped on the
        // trip id so a re-cross after a cap raise is genuinely new.
        activityRecorder.record(ActivityEvent(
            id: trip.id,
            kind: .budgetTripped,
            timestamp: Date().timeIntervalSince1970,
            title: title,
            detail: interrupted ? trip.detail + " · interrupted" : trip.detail,
            repo: trip.repo,
            // Route the row to the pane — the session for a session trip, the
            // worktree's highest-spend session for a task trip.
            sessionId: trip.sessionId,
            worktree: trip.worktree
        ))
    }

    // "Set Budget…" (ROADMAP Phase 42): a per-session dollar override, surfaced
    // on a fleet row and in the palette. An empty / 0 entry clears it (falls
    // back to the default session cap). Persists like the other defaults, and
    // clears the guard's mark so lowering a cap below current spend re-trips.
    func setBudget(forSessionId id: String) {
        let session = ClaudeSessionMonitor.shared.sessions.first { $0.id == id }
        let name = session?.displayName ?? String(id.prefix(8))
        let existing = budgetPerSession[id]
        let initial = existing.map { String(format: "%.2f", $0) } ?? ""
        let spendNote = session?.costUSD.map { String(format: " · spent $%.2f", $0) } ?? ""

        OverlayPromptController.shared.ask(
            caption: "Budget for \(name)\(spendNote)",
            text: initial,
            placeholder: "Dollar cap, e.g. 5.00 — empty to clear",
            over: activeWindowController()?.window
        ) { [weak self] value in
            guard let self else { return }
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                self.budgetPerSession.removeValue(forKey: id)
            } else if let amount = Double(trimmed.replacingOccurrences(of: "$", with: "")), amount > 0 {
                self.budgetPerSession[id] = amount
            } else {
                NSSound.beep()
                return
            }
            self.saveSettings()
        }
    }
}
