import Cocoa

// The AppKit half of the cost budget guardrails. Each session heartbeat
// it reads the live sessions' cumulative cost_usd (Phases 7/23), builds
// per-session and per-task (worktree) spend samples, and runs them through the
// pure BudgetMonitor. A new trip is handed to `onTrip` — AppDelegate notifies
// via the attention center, (opt-in) interrupts the pty, and logs the trip to
// the activity feed. Edge-triggered via the monitor's dedup, so a crossing acts
// once, not every heartbeat.
final class BudgetGuard {
    private let monitor = BudgetMonitor()
    private let caps: () -> BudgetCaps
    private let autoInterrupt: () -> Bool
    private let onTrip: (BudgetTrip) -> Void

    init(caps: @escaping () -> BudgetCaps,
         autoInterrupt: @escaping () -> Bool,
         onTrip: @escaping (BudgetTrip) -> Void) {
        self.caps = caps
        self.autoInterrupt = autoInterrupt
        self.onTrip = onTrip
    }

    // Driven from AppDelegate's 3 s session heartbeat. Skips the whole pass when
    // no ceiling is configured (the common case), so budget-off costs nothing.
    func tick(sessions: [ClaudeSession]) {
        let caps = caps()
        guard caps.isActive else {
            // Nothing capped: drop any stale marks so re-enabling starts clean.
            _ = monitor.evaluate([], autoInterrupt: false)
            return
        }
        let samples = Self.samples(sessions: sessions, caps: caps)
        for trip in monitor.evaluate(samples, autoInterrupt: autoInterrupt()) {
            onTrip(trip)
        }
    }

    // Build the session + task samples. A session sample per session that has a
    // measured cost and a resolved cap; a task sample per worktree summing its
    // sessions' costs against the task cap, attributed to the highest-spending
    // session in that worktree (the pty a trip interrupts / routes to).
    static func samples(sessions: [ClaudeSession], caps: BudgetCaps) -> [BudgetSample] {
        var samples: [BudgetSample] = []

        for session in sessions {
            guard let cost = session.costUSD, cost > 0,
                  let cap = caps.cap(forSessionId: session.id) else { continue }
            let place = FleetModel.projectAndWorktree(cwd: session.cwd)
            samples.append(BudgetSample(
                scope: .session, key: session.id, sessionId: session.id,
                title: session.displayName,
                repo: place.project == "—" ? nil : place.project,
                worktree: place.worktree,
                spendUSD: cost, cap: cap
            ))
        }

        if let taskCap = caps.taskCap, taskCap > 0 {
            var byWorktree: [String: [ClaudeSession]] = [:]
            for session in sessions {
                let place = FleetModel.projectAndWorktree(cwd: session.cwd)
                guard let worktree = place.worktree else { continue }
                // Key by repo/worktree so same-named worktrees in different
                // repos don't merge into one budget.
                byWorktree["\(place.project)/\(worktree)", default: []].append(session)
            }
            for (key, group) in byWorktree {
                let total = group.reduce(0.0) { $0 + ($1.costUSD ?? 0) }
                guard total > 0 else { continue }
                let rep = group.max { ($0.costUSD ?? 0) < ($1.costUSD ?? 0) } ?? group[0]
                let place = FleetModel.projectAndWorktree(cwd: rep.cwd)
                samples.append(BudgetSample(
                    scope: .task, key: key, sessionId: rep.id,
                    title: place.worktree ?? key,
                    repo: place.project == "—" ? nil : place.project,
                    worktree: place.worktree,
                    spendUSD: total, cap: taskCap
                ))
            }
        }

        return samples
    }
}
