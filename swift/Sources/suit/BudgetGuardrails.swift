import Foundation

// Cost budget guardrails (ROADMAP Phase 42): per-session and per-task
// (worktree) spend ceilings that warn — or, opt-in, interrupt — when a run
// blows past its budget. Phase 23 makes spend legible; this acts on it.
//
// This file is the UI-free, standalone-compilable core (the RoadmapParser /
// AutopilotScheduler / FeedbackRouting pattern, Foundation-only, no AppKit and
// no app deps), so `scripts/budget-test.sh` can compile it in isolation and
// assert the trip logic — notify once at the threshold, an Esc reaches the
// right pty under auto-interrupt, and staying under a cap never trips —
// without any UI. The AppKit half lives in BudgetGuard.swift (the
// heartbeat-driven monitor that reads session cost and wires trips into the
// attention center / interrupt / activity feed).

// Which kind of ceiling a cap measures. A session cap tracks one Claude
// session's cumulative cost_usd; a task cap tracks the summed cost of every
// session in one worktree (a New Claude Task / Autopilot run).
enum BudgetScope: String, Codable, Equatable {
    case session
    case task

    var label: String {
        switch self {
        case .session: return "session"
        case .task: return "task"
        }
    }
}

// The configured ceilings. `sessionCap`/`taskCap` are the defaults applied to
// every session / every worktree; `perSession` holds the "Set Budget…"
// overrides keyed by session id. A nil or ≤ 0 cap means "no ceiling" for that
// scope. All amounts are US dollars, read from the session files' cost_usd.
struct BudgetCaps: Codable, Equatable {
    var sessionCap: Double?
    var taskCap: Double?
    var perSession: [String: Double]

    init(sessionCap: Double? = nil, taskCap: Double? = nil, perSession: [String: Double] = [:]) {
        self.sessionCap = sessionCap
        self.taskCap = taskCap
        self.perSession = perSession
    }

    // The ceiling a given session is measured against: its per-session override
    // wins over the default. Returns nil when neither is set (no ceiling).
    func cap(forSessionId id: String) -> Double? {
        if let override = perSession[id], override > 0 { return override }
        if let sessionCap, sessionCap > 0 { return sessionCap }
        return nil
    }

    // Whether any ceiling is configured at all — the guard skips its whole pass
    // when nothing is capped, so the common no-budget case costs nothing.
    var isActive: Bool {
        if let sessionCap, sessionCap > 0 { return true }
        if let taskCap, taskCap > 0 { return true }
        return perSession.values.contains { $0 > 0 }
    }
}

// One spend observation handed to the monitor. `key` is the trip identity
// (session id for a session sample, "repo/worktree" for a task sample);
// `sessionId` is the pty the interrupt / route targets — for a task sample the
// representative session (the highest-spending one in the worktree).
struct BudgetSample: Equatable {
    var scope: BudgetScope
    var key: String
    var sessionId: String
    var title: String
    var repo: String?
    var worktree: String?
    var spendUSD: Double
    var cap: Double
}

// A cap crossing. `shouldInterrupt` folds in the auto-interrupt setting so the
// harness can assert "an Esc reaches the right pty" purely: the AppKit side
// reads it to decide whether to send Esc to `sessionId`.
struct BudgetTrip: Equatable {
    var scope: BudgetScope
    var key: String
    var sessionId: String
    var title: String
    var repo: String?
    var worktree: String?
    var spendUSD: Double
    var cap: Double
    var shouldInterrupt: Bool

    // Stable id for notification / activity-feed dedup: scope + key + the whole
    // cents of the cap it crossed, so raising a cap and re-crossing records
    // anew (the notification and the feed row are then genuinely fresh news).
    var id: String {
        "budget-\(scope.rawValue)-\(key)-\(Int((cap * 100).rounded()))"
    }

    // "$1.50 ≥ $1.00 cap" — the notification body / feed detail.
    var detail: String {
        String(format: "$%.2f ≥ $%.2f %@ cap", spendUSD, cap, scope.label)
    }
}

// The stateful monitor: remembers which entities are already over their cap so
// a crossing notifies / interrupts once, not every heartbeat. Pure — the
// AppKit side builds the samples and acts on the returned trips.
final class BudgetMonitor {
    // The trip ids currently over cap (BudgetTrip.id, which folds the cap in),
    // carried between evaluate() calls so a sustained overage doesn't re-fire.
    private(set) var tripped: Set<String> = []

    // Evaluate a batch of samples against their caps. Returns the newly-tripped
    // ones — spend ≥ cap and not already tripped at that cap. An entity whose
    // spend falls back under its cap, whose cap changed, or that vanished from
    // the batch (its session ended) drops its mark, so the set can't grow
    // without bound and a genuine later re-cross trips again.
    func evaluate(_ samples: [BudgetSample], autoInterrupt: Bool) -> [BudgetTrip] {
        var trips: [BudgetTrip] = []
        var live = Set<String>()
        for sample in samples where sample.cap > 0 && sample.spendUSD >= sample.cap {
            let trip = BudgetTrip(
                scope: sample.scope, key: sample.key, sessionId: sample.sessionId,
                title: sample.title, repo: sample.repo, worktree: sample.worktree,
                spendUSD: sample.spendUSD, cap: sample.cap, shouldInterrupt: autoInterrupt
            )
            live.insert(trip.id)
            if !tripped.contains(trip.id) {
                trips.append(trip)
            }
        }
        tripped = live
        return trips
    }
}
