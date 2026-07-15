import Darwin
import Foundation

// Autopilot engine — gate/merge feedback helpers, the §2.9 sleep hold, the
// §2.7 worker-death watchdog, and the worker-run tab/session lookups. Split
// out of AutopilotEngine.swift.
extension AutopilotEngine {
    // MARK: - Gate/merge helpers

    // Gate feedback → the live worker session, and the run back to `working`
    // with a fresh fix round (its own wall clock / stall / verification
    // window). Without a live session the feedback is never dropped: an
    // adopted run with no tab respawns `claude --continue` (feedback delivers
    // on session-ready), a shell that died during the gates goes through the
    // §2.7 death path the same way, and only a user-closed tab — deliberate
    // intervention (§2.9) — parks in `paused` via the next working tick.
    func returnRunToWorking(_ run: AutopilotRun, message: String, logLine: String) {
        store.updateRun { $0.stage = AutopilotRunStage.working.rawValue }
        attemptStartedAt = Date()
        needsInputSince = nil
        stallNudgeSent = false
        // The session file still reads `done` until the UserPromptSubmit hook
        // fires for the feedback; a verification inside that window would see
        // the world all green and skip the gates' verdict. The ≥30 s pace
        // starting now comfortably outlasts the hook.
        lastVerificationAt = Date()
        if let terminal = workerTerminal() {
            SessionControl.send(text: message, to: terminal, submit: true, submitDelay: 0.5)
            store.log(logLine)
        } else if workerTabId == nil {
            // Adoption landed the run at a gate stage without opening a tab
            // (§2.2: OPEN PR → re-run gates). Respawn `claude --continue`
            // (not counted against the §2.7 death respawn) and hold the
            // feedback for session-ready.
            pendingFeedbackMessage = message
            store.updateRun { $0.sessionId = nil }
            guard let current = store.run, openWorkerTab(run: current, continueSession: true) else {
                pendingFeedbackMessage = nil
                block(.workerDied,
                      "Phase \(run.phaseId): no window could host the run tab for the gate feedback",
                      phaseId: run.phaseId)
                return
            }
            store.log("no worker tab (adopted run) — respawned claude --continue; gate feedback delivers on session-ready")
        } else if workerTab() != nil {
            // The tab is open but its shell died during the gates
            // (workerTabExited deliberately leaves gate stages alone): the
            // §2.7 death path respawns `claude --continue`; the feedback
            // delivers on session-ready. A second death blocks instead — the
            // held feedback then dies with the run memory on the next adoption.
            pendingFeedbackMessage = message
            workerDied(reason: "the shell died while the gates ran")
        } else {
            store.log("worker tab was closed — feedback couldn't be delivered (Autopilot will pause)")
        }
        postUpdate()
    }

    // §2.8 item 4: the merged run's worker tab closes without confirmation —
    // the same trust as paneFinishedTask. workerTabId clears first so the
    // teardown's process kill can't route back through the
    // tabProcessDidExit intercept as a worker death.
    func closeWorkerTab() {
        guard let id = workerTabId else { return }
        workerTabId = nil
        guard let (controller, tab) = appDelegate?.controllerAndTab(withId: id) else { return }
        controller.closeAutopilotRunTab(tab)
    }

    // Clears every per-run in-memory flag once the run record is gone.
    func resetRunMemory() {
        workerTabId = nil
        sessionReadyDeadline = nil
        deliverResumePrompt = false
        pendingFeedbackMessage = nil
        respawnCount = 0
        attemptStartedAt = nil
        needsInputSince = nil
        stallNudgeSent = false
        lastVerificationAt = nil
        reviewGateBrokenCount = 0
        mergeConfirmedPending = false
        lastMergePollAt = nil
    }

    // The last ~100 lines of a gate log — what rides along in the §2.8
    // build-failure feedback (fenced by AutopilotPrompts, one paste unit).
    static func tailOfLog(atPath path: String, maxLines: Int = 100) -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return "(no build log was captured)"
        }
        // Only the tail region matters; 64 KB comfortably covers 100 lines.
        let text = String(decoding: data.suffix(64 * 1024), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(maxLines)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // The review output minus its final VERDICT line — the findings the
    // rejection feedback forwards verbatim.
    static func findingsText(from output: String) -> String {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = lines.last,
              last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeLast()
        }
        if let last = lines.last,
           last.trimmingCharacters(in: .whitespaces).hasPrefix("VERDICT:") {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Sleep hold (§2.9 "Keep the Mac awake during runs")

    func updateSleepHold() {
        var wanted = false
        if case .running = state, appDelegate?.autopilotPreventSleep == true { wanted = true }
        setSleepHold(wanted)
    }

    func beginSleepHoldForSpawn() {
        if appDelegate?.autopilotPreventSleep == true { setSleepHold(true) }
    }

    private func setSleepHold(_ wanted: Bool) {
        if wanted, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: .idleSystemSleepDisabled,
                reason: "Autopilot run in progress"
            )
        } else if !wanted, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }

    // MARK: - Worker death (§2.7 watchdog)

    // Called by TerminalWindowController when the worker tab's shell exits
    // (it skips the clean-exit auto-close, so the scrollback survives).
    func workerTabExited(_ tab: Tab) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard tab.id == workerTabId else { return }
        guard case .running = state, let run = store.run else {
            workerTabId = nil
            return
        }
        guard AutopilotRunStage(rawValue: run.stage) == .working else {
            // The gates/merge/cleanup read git/gh, not the pty — a dead shell
            // there doesn't stop the pipeline (gate feedback discovers the
            // missing terminal itself). Leave the tab for inspection.
            store.log("worker tab's shell exited during \(run.stage) — tab left open")
            return
        }
        workerDied(reason: "the run tab's shell exited")
    }

    // One respawn with `claude --continue` + the resume prompt; a second
    // death blocks the phase. The dead tab stays open for debugging.
    func workerDied(reason: String) {
        guard let run = store.run else { return }
        if respawnCount >= 1 {
            block(.workerDied,
                  "Phase \(run.phaseId): the worker died twice (\(reason)) — check the run tab",
                  phaseId: run.phaseId)
            return
        }
        respawnCount += 1
        store.log("worker died (\(reason)) — respawning once with --continue")
        // Un-pin so the session-ready watch re-arms; the old id stays in
        // sessionIds for the history row.
        store.updateRun { $0.sessionId = nil }
        guard openWorkerTab(run: run, continueSession: true) else {
            block(.workerDied,
                  "Phase \(run.phaseId): the worker died and no window could host the respawn",
                  phaseId: run.phaseId)
            return
        }
        postUpdate()
    }

    // MARK: - Worker-run helpers

    // The staleness guard every background-job completion runs on the main
    // queue: act only if the engine wasn't stopped or restarted since the job
    // began (generation), is still running, and the store still holds the same
    // run at the expected stage. Returns the current run re-read from the
    // store — the callback's captured copy may be stale — or nil to drop the
    // callback.
    func currentRun(ifGeneration gen: Int, run: AutopilotRun, stage: AutopilotRunStage) -> AutopilotRun? {
        guard gen == generation, case .running = state,
              let current = store.run, current.id == run.id,
              AutopilotRunStage(rawValue: current.stage) == stage else { return nil }
        return current
    }

    // Whether the engine owns this tab (the tabProcessDidExit intercept).
    func ownsTab(withId id: String) -> Bool {
        workerTabId == id
    }

    // The worker tab, resolved live across windows — tab ids stay valid
    // through drags/tear-offs, unlike weak content refs.
    private func workerTab() -> Tab? {
        guard let id = workerTabId,
              let (_, tab) = appDelegate?.controllerAndTab(withId: id) else { return nil }
        return tab
    }

    // The worker tab's terminal content — nil once the tab is gone OR its
    // shell exited (the tab is deliberately left open then, but a dead pty
    // swallows sends silently: LocalProcess.send guards on `running`, so
    // "delivered" feedback would be dropped while the log claims success).
    func workerTerminal() -> TerminalPaneContent? {
        guard let tab = workerTab(), tab.exitStatus == nil else { return nil }
        return tab.content as? TerminalPaneContent
    }

    func pinnedSession(_ run: AutopilotRun) -> ClaudeSession? {
        guard let id = run.sessionId else { return nil }
        return ClaudeSessionMonitor.shared.sessions.first { $0.id == id }
    }

    static func processIsDead(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return true }
        return kill(pid, 0) != 0 && errno == ESRCH
    }
}
