import Darwin
import Foundation

// Autopilot engine — launch adoption + the per-tick run-loop dispatcher
// (§2.2/§2.4). Split out of AutopilotEngine.swift.
extension AutopilotEngine {
    // MARK: - Launch

    // Called once from applicationDidFinishLaunching (after the session
    // monitor exists). App quit kills pty children, so a live worker never
    // survives a relaunch — a persisted run is re-adopted per §2.2's truth
    // table (reactivateFromStore → adoptPersistedRun); persisted pause/block
    // flags win over adoption (the user's last word stands until Resume or
    // Retry, which re-adopt the kept run themselves).
    func adoptOnLaunch() {
        guard let app = appDelegate, app.autopilotEnabled else {
            setState(.off)
            return
        }
        seedSnapshotFromStore()
        refreshSnapshot()
        reactivateFromStore()
        store.log("Autopilot active — \(describe(state))")
    }

    // MARK: - Tick (main queue, every 3 s)

    func tick() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let app = appDelegate else { return }
        guard app.autopilotEnabled else {
            if isActive { setState(.off) }
            return
        }
        if case .off = state {
            // Just (re-)enabled: restore paused/blocked from the store.
            reactivateFromStore()
        }

        switch state {
        case .off, .blocked:
            break // blocked waits for the user (Run Next Phase Now retries)
        case .paused:
            break
        case .doneAllPhases:
            checkDoneAllPhasesRecovery()
        case .running:
            tickRunning()
        case .idle:
            tickIdle()
        }

        // Repaint the footer only when its text actually changed.
        let status = footerStatus()
        if status.text != lastStatusText {
            lastStatusText = status.text
            postUpdate()
        }
    }

    private func tickIdle() {
        guard let app = appDelegate else { return }
        if store.pausedByUser {
            setState(.paused)
            return
        }
        let decision = AutopilotScheduler.mayStartRun(
            mode: app.autopilotMode, snapshot: cachedSnapshot,
            now: Date(), config: schedulerConfig
        )
        if decision != lastDecision {
            lastDecision = decision
            postUpdate()
        }
        let bypass = budgetBypassOnce
        if case .wait = decision, !bypass { return }
        startPreflightIfDue(force: bypass)
    }

    // The per-tick run driver: a pull-based dispatcher over the persisted run
    // stage. The gate/merge/cleanup starters are all idempotent-per-tick —
    // the shared `inFlight` flag (and the merge poll pace) keeps each stage's
    // background work single-file.
    private func tickRunning() {
        // Mid-adoption the persisted stage may be stale (the truth table is
        // still resolving what actually happened) — don't drive it yet.
        guard !adopting else { return }
        guard let run = store.run else {
            // A running state with no persisted run can't happen through the
            // normal paths; recover instead of wedging.
            workerTabId = nil
            setState(.idle)
            return
        }
        switch AutopilotRunStage(rawValue: run.stage) {
        case .working:
            tickWorking(run)
        case .gatingBuild:
            maybeStartBuildGate(run)
        case .gatingReview:
            maybeStartReviewGate(run)
        case .merging:
            maybeStartMerge(run)
        case .cleanup:
            maybeStartCleanup(run)
        case nil:
            // A stage this build doesn't know (newer state.json) — leave it
            // for the user rather than guessing.
            break
        }
    }

    // The `working` stage driver: session readiness, watchdogs, stall
    // handling, and re-arming completion verification.
    private func tickWorking(_ run: AutopilotRun) {
        // The user closing the worker tab is deliberate intervention (§2.9):
        // park instead of respawning over their decision.
        if workerTabId != nil, workerTerminal() == nil {
            workerTabId = nil
            store.setPausedByUser(true)
            store.log("worker tab was closed — Autopilot paused (Run Next Phase Now resumes)")
            setState(.paused)
            return
        }

        // §2.5: no session file within the ready timeout → blocked, tab left
        // open (the one-time skip-permissions dialog is the usual culprit).
        if run.sessionId == nil {
            if let deadline = sessionReadyDeadline, Date() >= deadline {
                sessionReadyDeadline = nil
                block(.sessionNeverReady,
                      "claude session never became ready — check the run tab",
                      phaseId: run.phaseId)
            }
            return
        }

        // 90-min per-attempt wall clock (§2.7); tab left open for inspection.
        if let started = attemptStartedAt,
           Date().timeIntervalSince(started) > Self.wallClockCap {
            block(.wallClockExceeded,
                  "Phase \(run.phaseId): the attempt passed the 90-minute wall clock — check the run tab",
                  phaseId: run.phaseId)
            return
        }

        let session = pinnedSession(run)

        // §2.9 needs-input stall handling.
        if let session, session.state == .needsInput {
            handleStall(run: run, session: session)
            if case .blocked = state { return }
        } else {
            needsInputSince = nil
        }

        // §2.7 watchdog: claude's pid is gone but the shell (and tab) live
        // on, and the session file froze — the worker died silently.
        if let session, let pid = session.pid, Self.processIsDead(pid),
           Date().timeIntervalSince(session.updatedAt) > Self.frozenSessionAge {
            workerDied(reason: "session pid \(pid) is dead and the session file froze")
            return
        }

        // Re-trigger verification while the session sits at `done` — the
        // ≥30 s throttle or the nudge spacing may have deferred the last one
        // past the final didUpdate.
        if session?.state == .done {
            maybeStartVerification()
        }
    }

    // MARK: - doneAllPhases auto-recovery (the steering loop)

    func checkDoneAllPhasesRecovery() {
        let now = Date()
        if let last = lastRoadmapCheckAt,
           now.timeIntervalSince(last) < Self.roadmapCheckInterval { return }
        lastRoadmapCheckAt = now
        guard let mtime = roadmapModificationDate() else { return }
        if let atDone = roadmapMtimeAtDone, mtime > atDone {
            store.log("ROADMAP.md changed — re-checking for eligible phases")
            roadmapMtimeAtDone = nil
            setState(.idle)
        }
    }

    func roadmapModificationDate() -> Date? {
        guard let root = appDelegate?.autopilotProjectRoot, !root.isEmpty else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: root + "/ROADMAP.md")
        return attributes?[.modificationDate] as? Date
    }
}
