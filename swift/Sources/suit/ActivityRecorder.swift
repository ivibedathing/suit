import Cocoa

// The producer side of the activity feed. Watches the session monitor
// for state transitions and turns each into an ActivityEvent; the other
// producers (Autopilot merged/blocked, CI failures) call `record(...)` directly
// from their existing transition points. Also drives the once-daily digest
// notification.
//
// One instance, owned by the AppDelegate and started at launch. Recording is
// edge-triggered off ClaudeSessionMonitor.didUpdate, deduped by the store on a
// deterministic id, so a session's file being rewritten without a state change
// never records twice.
final class ActivityRecorder {
    private let store: ActivityStore
    // Focus/route + Autopilot-log hooks, wired by the AppDelegate. Kept here so
    // the digest notification's click can route (via the attention center).
    private let onDigest: (DailyDigest) -> Void

    // The last observed state per session. The first pass seeds this without
    // recording — otherwise every session already live at launch would flood
    // the feed with a spurious transition.
    private var previousStates: [String: ClaudeSessionState] = [:]
    private var seeded = false

    // The calendar day whose digest was last delivered, persisted so a relaunch
    // doesn't re-notify. Stored as a day-start epoch in UserDefaults.
    private static let lastDigestDayKey = "activityLastDigestDay"

    init(store: ActivityStore = .shared, onDigest: @escaping (DailyDigest) -> Void) {
        self.store = store
        self.onDigest = onDigest
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionsUpdated),
            name: ClaudeSessionMonitor.didUpdate, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Session transitions

    @objc private func sessionsUpdated() {
        let sessions = ClaudeSessionMonitor.shared.sessions

        if !seeded {
            previousStates = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.state) })
            seeded = true
            return
        }

        for session in sessions {
            let previous = previousStates[session.id]
            guard previous != session.state else { continue }
            recordSessionTransition(session)
        }
        previousStates = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.state) })
    }

    private func recordSessionTransition(_ session: ClaudeSession) {
        let kind: ActivityKind
        switch session.state {
        case .done: kind = .sessionDone
        case .needsInput: kind = .sessionNeedsInput
        // working→busy isn't feed-worthy on its own — the feed records
        // completions and stalls, not every keystroke.
        case .working: return
        }
        let place = FleetModel.projectAndWorktree(cwd: session.cwd)
        // The updatedAt second keys the id, so a genuine later transition into
        // the same state records again while a same-update re-fire doesn't.
        let stamp = Int(session.updatedAt.timeIntervalSince1970)
        store.record(ActivityEvent(
            id: "\(kind.rawValue)-\(session.id)-\(stamp)",
            kind: kind,
            timestamp: session.updatedAt.timeIntervalSince1970,
            title: session.displayName,
            detail: nil,
            repo: place.project == "—" ? nil : place.project,
            sessionId: session.id,
            worktree: place.worktree
        ))
    }

    // MARK: - Direct producers (called by Autopilot / feedback)

    // Records `event`; returns whether it was new (the store dedups on id). The
    // caller stamps the timestamp so the store stays deterministic.
    @discardableResult
    func record(_ event: ActivityEvent) -> Bool {
        store.record(event)
    }

    // MARK: - Daily digest

    // Delivers today's digest once per calendar day, on the first check after
    // local midnight when the day has any notable rows. Driven from the app's
    // session heartbeat.
    func maybePostDailyDigest(now: Date = Date(), calendar: Calendar = .current) {
        let todayStart = calendar.startOfDay(for: now).timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: Self.lastDigestDayKey)
        guard last < todayStart else { return }
        // Only recap once there's genuinely a day's worth behind us: don't fire
        // for "today" until at least the morning, so a launch at 00:01 doesn't
        // deliver an empty digest. Recap the *previous* day.
        let yesterday = now.addingTimeInterval(-3 * 3600)
        let digest = DailyDigest.rollup(events: store.events, day: yesterday, calendar: calendar)
        UserDefaults.standard.set(todayStart, forKey: Self.lastDigestDayKey)
        guard !digest.isEmpty else { return }
        onDigest(digest)
    }
}
