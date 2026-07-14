import Darwin
import Foundation

// Autopilot engine — the palette/footer command surface (§2.9/§2.10): Run
// Next Phase Now, Retry, Pause, Resume, Skip Current Phase, and the settings
// write-through. Split out of AutopilotEngine.swift.
extension AutopilotEngine {
    // MARK: - Lifecycle (manager-driven)

    // Bring this instance online outside of launch — "Start Autopilot Here"
    // stands up a fresh engine, this seeds its snapshot and reactivates it
    // (idle with no run → it preflights the repo's next eligible phase).
    func activate() {
        adoptOnLaunch()
    }

    // Dashboard "Stop": park the instance and drop its persisted slot so it
    // isn't re-adopted next launch. The current run's worktree/branch are left
    // in place for the user to take over — Skip Current Phase is the path that
    // tears those down.
    func deactivateAndForget() {
        workerTabId = nil
        resetRunMemory()
        setState(.off)
        store.deleteSlot()
    }

    // MARK: - Commands (palette / footer)

    // Bypasses the budget gate once. No-op while a run is active; a kept run
    // (after a block/pause) resumes through adoption rather than preflight —
    // preflight would only trip over its leftover worktree.
    func runNextPhaseNow() {
        guard let app = appDelegate, app.autopilotEnabled else {
            store.log("Run Next Phase Now ignored — Autopilot is disabled")
            return
        }
        if case .running = state {
            store.log("Run Next Phase Now ignored — a run is already active")
            return
        }
        if case .blocked = state {
            clearBlock()
        }
        if case .doneAllPhases = state {
            setState(.idle)
        }
        if case .paused = state {
            store.setPausedByUser(false)
            setState(.idle)
        }
        if store.run != nil {
            adoptPersistedRun(context: "run-next-phase-now")
            return
        }
        budgetBypassOnce = true
        lastPreflightAt = nil
        store.log("Run Next Phase Now — bypassing the budget gate once")
        tick()
    }

    // §2.9 palette Retry (shown while blocked): clears the block, then
    // either re-adopts the kept run at its true stage (§2.2) or re-runs
    // preflight right away.
    func retryAfterBlock() {
        guard case .blocked = state else { return }
        clearBlock()
        if store.run != nil {
            adoptPersistedRun(context: "retry")
            return
        }
        budgetBypassOnce = true
        lastPreflightAt = nil
        tick()
    }

    // §2.10 palette: an in-flight run always finishes; the engine parks
    // instead of starting the next one.
    func pauseAfterCurrentRun() {
        store.setPausedByUser(true)
        if case .running = state {
            store.log("pause requested — Autopilot pauses after the current run")
            postUpdate()
        } else {
            store.log("Autopilot paused")
            setState(.paused)
        }
    }

    func resume() {
        store.setPausedByUser(false)
        store.log("Autopilot resumed")
        guard case .paused = state else { return }
        // §2.9: resume = the adoption path — a kept run (e.g. after the user
        // closed the worker tab) is re-resolved and respawned, not
        // re-preflighted into its own leftover worktree.
        if store.run != nil {
            adoptPersistedRun(context: "resume")
        } else {
            setState(.idle)
        }
    }

    // §2.9 Skip Current Phase: append ⏸ to the phase heading in the MAIN
    // checkout's ROADMAP.md (the engine's one sanctioned write to the
    // steering file — steering stays in the file), interrupt the worker,
    // force-remove worktree + branch, record `skipped` in history, and let
    // the loop continue with the next phase.
    func skipCurrentPhase() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let app = appDelegate, app.autopilotEnabled else {
            store.log("Skip Current Phase ignored — Autopilot is disabled")
            return
        }
        guard let run = store.run else {
            store.log("Skip Current Phase: no phase run to skip — steer by editing ROADMAP.md")
            return
        }
        let root = projectRoot
        // The ⏸ mark is load-bearing (without it the next preflight re-picks
        // the same phase), so it goes first and a failure aborts the skip.
        if let error = markPhaseSkipped(run.phaseId, root: root) {
            store.log("Skip Current Phase failed: \(error)")
            postUpdate()
            return
        }
        store.log("Phase \(run.phaseId) skipped — ⏸ appended to its ROADMAP.md heading")
        if let terminal = workerTerminal() {
            SessionControl.interrupt(terminal)
        }
        // An in-flight gate (build.sh / claude -p) still runs inside the
        // worktree that's about to be force-removed: kill it. Its completion
        // then fires promptly — dropped by the generation check — and
        // releases the in-flight flag, so the next phase isn't stalled
        // behind the abandoned gate's 15-minute watchdog.
        let gateHandle = activeGateHandle
        activeGateHandle = nil
        gateHandle?.cancel()
        store.appendHistory(CompletedRun(
            runId: run.id, phase: run.phaseId, title: run.title, slug: run.slug,
            branch: run.branch, startedAt: run.startedAt,
            endedAt: Date().timeIntervalSince1970,
            attempts: max(run.buildAttempts, run.reviewAttempts, 1),
            outcome: .skipped, prURL: nil, costUSD: run.costUSD,
            maxContextPct: run.maxContextPct, sessionIds: run.sessionIds,
            blockedReason: store.blocked?.reason
        ))
        closeWorkerTab()
        blockedMessage = nil
        store.setBlocked(nil)
        store.setRun(nil)
        resetRunMemory()
        // Force-remove the worktree + branch in the background. Failures are
        // only logged — but loudly, because the skipped slug is out of the
        // next preflight's leftover check, so an orphan won't be auto-cleaned.
        let worktreePath = run.worktreePath
        let branch = run.branch
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Wait out the killed gate's death before removing its cwd —
            // removal must not race a process still writing into the tree.
            gateHandle?.waitUntilExited(timeout: 10)
            var warning: String?
            if FileManager.default.fileExists(atPath: worktreePath) {
                warning = WorktreeTasks.removeAfterRemoteMerge(worktreePath: worktreePath)
            } else {
                _ = WorktreeTasks.runGit(root, ["branch", "-D", branch])
                _ = WorktreeTasks.runGit(root, ["push", "origin", "--delete", branch])
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let warning {
                    self.store.log("skip cleanup warning: \(warning) — remove \(worktreePath) manually")
                } else {
                    self.store.log("skipped phase's worktree and branch removed")
                }
            }
        }
        // lastPreflightAt is left standing (not reset): the ≥30 s pace gives
        // the background removal a head start so the next phase's preflight
        // never races the git operations above.
        setState(.idle)
    }

    // The one sanctioned Autopilot write to ROADMAP.md (§2.9). Returns an
    // error message, nil on success (including already-marked).
    private func markPhaseSkipped(_ phaseId: Int, root: String) -> String? {
        guard !root.isEmpty else { return "no Autopilot project is configured" }
        let path = root + "/ROADMAP.md"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "couldn't read \(path)"
        }
        guard let marked = RoadmapParser.markingPhaseSkipped(phaseId, in: content) else {
            return "Phase \(phaseId) has no heading in ROADMAP.md"
        }
        if marked == content { return nil } // already ⏸
        do {
            try marked.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return "couldn't write \(path): \(error.localizedDescription)"
        }
        return nil
    }

    // Settings write-throughs poke this so mode/ceiling/root changes take
    // effect on the next decision instead of waiting out a throttle.
    func settingsChanged() {
        lastDecision = nil
        lastPreflightAt = nil
        updateSleepHold()
        tick()
    }
}
