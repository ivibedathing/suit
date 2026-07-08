import Darwin
import Foundation

// Autopilot engine — the §2.11 footer status line, the usage-snapshot
// plumbing, and the core state-transition machinery. Split out of
// AutopilotEngine.swift.
extension AutopilotEngine {
    // MARK: - Footer status (§2.11)

    func footerStatus() -> AutopilotFooterStatus {
        switch state {
        case .off:
            return AutopilotFooterStatus(text: "Autopilot · off", tooltip: "Autopilot is disabled", kind: .idle)
        case .paused:
            return AutopilotFooterStatus(
                text: "Autopilot · paused",
                tooltip: "Paused by you — Run Next Phase Now resumes",
                kind: .paused
            )
        case .doneAllPhases:
            return AutopilotFooterStatus(
                text: "Autopilot · idle — no unshipped phases",
                tooltip: "Every ROADMAP.md phase is ✅ shipped or ⏸ skipped; editing the roadmap re-arms Autopilot",
                kind: .done
            )
        case .blocked(let reason):
            let message = blockedMessage ?? store.blocked?.message ?? reason.rawValue
            let text: String
            if let phaseId = store.blocked?.phaseId {
                text = "⚠ Phase \(phaseId) blocked — \(message)"
            } else {
                text = "⚠ Autopilot blocked — \(message)"
            }
            return AutopilotFooterStatus(text: text, tooltip: message, kind: .blocked)
        case .idle:
            if case .wait(let until, let why)? = lastDecision {
                let text: String
                if let until {
                    text = "Autopilot · next run ~" + Self.clockFormatter.string(from: until)
                } else {
                    text = "Autopilot · waiting"
                }
                return AutopilotFooterStatus(text: text, tooltip: why, kind: .idle)
            }
            return AutopilotFooterStatus(
                text: "Autopilot · idle",
                tooltip: "Waiting for the next scheduling decision",
                kind: .idle
            )
        case .running:
            guard let run = store.run else {
                return AutopilotFooterStatus(text: "⚙ Autopilot · running", tooltip: "", kind: .running)
            }
            let maxAttempts = appDelegate?.autopilotMaxGateAttempts ?? 3
            let prefix = "⚙ Phase \(run.phaseId)"
            let text: String
            switch AutopilotRunStage(rawValue: run.stage) {
            case .gatingBuild:
                let attempts = run.buildAttempts > 1 ? " (\(run.buildAttempts)/\(maxAttempts))" : ""
                text = "\(prefix) · gate: build\(attempts)"
            case .gatingReview:
                let attempts = run.reviewAttempts > 1 ? " (\(run.reviewAttempts)/\(maxAttempts))" : ""
                text = "\(prefix) · gate: review\(attempts)"
            case .merging:
                let pr = run.prNumber.map { " PR #\($0)" } ?? ""
                text = "\(prefix) · merging\(pr)"
            case .cleanup:
                text = "\(prefix) · cleaning up"
            case .working, nil:
                let minutes = max(0, Int(Date().timeIntervalSince1970 - run.startedAt) / 60)
                text = "\(prefix) · running \(minutes)m"
            }
            return AutopilotFooterStatus(
                text: text,
                tooltip: "Phase \(run.phaseId) — \(run.title)",
                kind: .running
            )
        }
    }

    // MARK: - Snapshot plumbing

    @objc func sessionMonitorUpdated(_ note: Notification) {
        refreshSnapshot()
        guard case .running = state, let run = store.run else { return }
        if run.sessionId == nil {
            if AutopilotRunStage(rawValue: run.stage) == .working {
                tryPinWorkerSession(run)
            }
            return
        }
        guard let session = pinnedSession(run) else { return }
        // §2.10: cost/context sampled on every update, whatever the stage —
        // session files get pruned, the history row's data lives on the run.
        sampleSessionMetrics(session, run: run)
        guard AutopilotRunStage(rawValue: run.stage) == .working else { return }
        // The Stop hook flips the session to done at *every* turn end — that
        // only triggers verification (§2.7), world state decides.
        if session.state == .done {
            maybeStartVerification()
        }
    }

    func refreshSnapshot() {
        guard let usage = ClaudeSessionMonitor.shared.readUsageSnapshot() else { return }
        let snapshot = UsageSnapshot(
            fiveHourPct: usage.fiveHourPct,
            sevenDayPct: usage.sevenDayPct,
            modelWeeklyMaxPct: usage.modelWeeklies.map(\.pct).max(),
            fiveHourResetsAt: usage.fiveHourResetsAt,
            sevenDayResetsAt: usage.sevenDayResetsAt,
            capturedAt: usage.capturedAt
        )
        guard snapshot != cachedSnapshot else { return }
        cachedSnapshot = snapshot
        // Mirror into state.json (relaunch shows "next run ~…"), but only when
        // something the scheduler reads changed — captured_at alone advances on
        // every statusline render and isn't worth a disk write.
        let stored = store.lastSnapshot
        if stored == nil
            || stored?.fiveHourPct != snapshot.fiveHourPct
            || stored?.sevenDayPct != snapshot.sevenDayPct
            || stored?.modelWeeklyMaxPct != snapshot.modelWeeklyMaxPct
            || stored?.fiveHourResetsAt != snapshot.fiveHourResetsAt?.timeIntervalSince1970
            || stored?.sevenDayResetsAt != snapshot.sevenDayResetsAt?.timeIntervalSince1970 {
            store.setLastSnapshot(AutopilotStore.Snapshot(
                fiveHourPct: snapshot.fiveHourPct,
                sevenDayPct: snapshot.sevenDayPct,
                modelWeeklyMaxPct: snapshot.modelWeeklyMaxPct,
                fiveHourResetsAt: snapshot.fiveHourResetsAt?.timeIntervalSince1970,
                sevenDayResetsAt: snapshot.sevenDayResetsAt?.timeIntervalSince1970,
                capturedAt: snapshot.capturedAt.timeIntervalSince1970
            ))
        }
    }

    func seedSnapshotFromStore() {
        guard cachedSnapshot == nil, let stored = store.lastSnapshot else { return }
        cachedSnapshot = UsageSnapshot(
            fiveHourPct: stored.fiveHourPct,
            sevenDayPct: stored.sevenDayPct,
            modelWeeklyMaxPct: stored.modelWeeklyMaxPct,
            fiveHourResetsAt: stored.fiveHourResetsAt.map(Date.init(timeIntervalSince1970:)),
            sevenDayResetsAt: stored.sevenDayResetsAt.map(Date.init(timeIntervalSince1970:)),
            capturedAt: Date(timeIntervalSince1970: stored.capturedAt)
        )
    }

    var schedulerConfig: AutopilotSchedulerConfig {
        guard let app = appDelegate else { return AutopilotSchedulerConfig() }
        return AutopilotSchedulerConfig(
            fiveHourCeiling: Double(app.autopilotFiveHourCeiling),
            weeklyCeiling: Double(app.autopilotWeeklyCeiling),
            weeklyHardStop: Double(app.autopilotWeeklyHardStop),
            paceTargetPct: Double(app.autopilotPaceTargetPct),
            nightStart: app.autopilotNightStart,
            nightEnd: app.autopilotNightEnd
        )
    }

    // MARK: - State plumbing

    func setState(_ new: AutopilotEngineState) {
        guard state != new else { return }
        state = new
        generation += 1
        updateSleepHold()
        postUpdate()
    }

    func block(_ reason: AutopilotBlockReason, _ message: String, phaseId: Int?) {
        blockedMessage = message
        let at = Date().timeIntervalSince1970
        store.setBlocked(AutopilotStore.Blocked(
            reason: reason.rawValue, message: message,
            at: at, phaseId: phaseId
        ))
        store.log("blocked (\(reason.rawValue)): \(message)")
        // §2.11: a block is always news — the attention center presents it
        // even while the app is frontmost.
        appDelegate?.postAutopilotNotification(
            title: phaseId.map { "Autopilot blocked — Phase \($0)" } ?? "Autopilot blocked",
            body: message, identifier: "autopilot-blocked"
        )
        // Fleet activity feed (ROADMAP Phase 38): a block is feed-worthy.
        appDelegate?.recordAutopilotBlocked(reason: reason.rawValue, message: message, phaseId: phaseId, at: at)
        setState(.blocked(reason))
    }

    func clearBlock() {
        blockedMessage = nil
        store.setBlocked(nil)
        store.log("block cleared")
        setState(.idle)
    }

    // The state to land in when Autopilot turns (back) on — launch and the
    // re-enable path share it: persisted pause and block flags win (the run,
    // if any, is re-adopted by Resume/Retry), then a persisted run adopts
    // per §2.2, then plain idle.
    func reactivateFromStore() {
        if store.pausedByUser {
            setState(.paused)
            return
        }
        if let blocked = store.blocked {
            blockedMessage = blocked.message
            setState(.blocked(AutopilotBlockReason(rawValue: blocked.reason) ?? .other))
            return
        }
        if store.run != nil {
            adoptPersistedRun(context: "adoption")
            return
        }
        setState(.idle)
    }

    func describe(_ state: AutopilotEngineState) -> String {
        switch state {
        case .off: return "off"
        case .idle: return "idle"
        case .running: return "running"
        case .paused: return "paused"
        case .blocked(let reason): return "blocked (\(reason.rawValue))"
        case .doneAllPhases: return "done — no unshipped phases"
        }
    }

    func postUpdate() {
        NotificationCenter.default.post(name: Self.didUpdate, object: self)
    }
}
