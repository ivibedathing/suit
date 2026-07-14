import Cocoa

extension AppDelegate {
    // MARK: - Autopilot

    // Enabling runs the §2.3 enable-time checks: the hook/statusline scripts
    // are Autopilot's nervous system (refuse without them), and gh gets an
    // install hint (missing gh is an expected, recoverable blocked state).
    // Returns whether the value was taken so the settings checkbox can revert.
    @discardableResult
    func autopilotEnabledChanged(_ enabled: Bool) -> Bool {
        if enabled, !autopilotEnabled {
            guard ClaudeIntegration.status() == .installed else {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Install the Claude Code integration first"
                alert.informativeText = "Autopilot watches its worker sessions through the session files and usage snapshot written by Suit's statusline and hook scripts — without them it is blind. Run “Install Claude Code Integration…” from the app menu, then enable Autopilot."
                alert.runModal()
                return false
            }
            if !GitHubCLI.isAvailable {
                let alert = NSAlert()
                alert.messageText = "The gh CLI isn’t installed"
                alert.informativeText = "Autopilot uses GitHub’s gh to open and merge PRs (brew install gh, then gh auth login). Autopilot will stay blocked until gh is available."
                alert.runModal()
            }
        }
        autopilotEnabled = enabled
        saveSettings()
        AutopilotStore.logGlobal(enabled ? "Autopilot enabled" : "Autopilot disabled")
        AutopilotManager.shared.settingsChangedAll()
        return true
    }

    // Only accepts a git repository that contains ROADMAP.md (the steering
    // file the engine parses); clearing the path is always allowed. Returns
    // whether the value was taken so the settings field can revert.
    @discardableResult
    func autopilotProjectRootChanged(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        if !expanded.isEmpty {
            guard FileIndex.gitRoot(of: expanded) != nil,
                  FileManager.default.fileExists(atPath: expanded + "/ROADMAP.md") else { return false }
        }
        autopilotProjectRoot = expanded
        saveSettings()
        AutopilotManager.shared.settingsChangedAll()
        return true
    }

    func autopilotModeChanged(_ mode: AutopilotBudgetMode) {
        autopilotMode = mode
        saveSettings()
        AutopilotManager.shared.settingsChangedAll()
    }

    func autopilotNightStartChanged(_ hour: Int) {
        autopilotNightStart = min(23, max(0, hour))
        saveSettings()
        AutopilotManager.shared.settingsChangedAll()
    }

    func autopilotNightEndChanged(_ hour: Int) {
        autopilotNightEnd = min(23, max(0, hour))
        saveSettings()
        AutopilotManager.shared.settingsChangedAll()
    }

    func autopilotFiveHourCeilingChanged(_ pct: Int) {
        autopilotFiveHourCeiling = min(100, max(0, pct))
        saveSettings()
        AutopilotManager.shared.settingsChangedAll()
    }

    func autopilotWeeklyCeilingChanged(_ pct: Int) {
        autopilotWeeklyCeiling = min(100, max(0, pct))
        saveSettings()
        AutopilotManager.shared.settingsChangedAll()
    }

    func autopilotWeeklyHardStopChanged(_ pct: Int) {
        autopilotWeeklyHardStop = min(100, max(0, pct))
        saveSettings()
        AutopilotManager.shared.settingsChangedAll()
    }

    func autopilotPaceTargetChanged(_ pct: Int) {
        autopilotPaceTargetPct = min(100, max(1, pct))
        saveSettings()
        AutopilotManager.shared.settingsChangedAll()
    }

    func autopilotMaxGateAttemptsChanged(_ attempts: Int) {
        autopilotMaxGateAttempts = min(9, max(1, attempts))
        saveSettings()
        AutopilotManager.shared.settingsChangedAll()
    }

    func autopilotStallMinutesChanged(_ minutes: Int) {
        autopilotStallMinutes = min(24 * 60, max(5, minutes))
        saveSettings()
        AutopilotManager.shared.settingsChangedAll()
    }

    // Newline-free (the launch path types this into zsh as one line, §2.5).
    func autopilotExtraArgsChanged(_ args: String) {
        autopilotExtraArgs = args
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        saveSettings()
        AutopilotManager.shared.settingsChangedAll()
    }

    func autopilotReviewModelChanged(_ model: String) {
        autopilotReviewModel = model.trimmingCharacters(in: .whitespaces)
        saveSettings()
        AutopilotManager.shared.settingsChangedAll()
    }

    func autopilotPreventSleepChanged(_ enabled: Bool) {
        autopilotPreventSleep = enabled
        saveSettings()
        AutopilotManager.shared.settingsChangedAll()
    }

    // Footer row / palette "Open Run Tab" / notification click-through: focus
    // the worker tab wherever it lives. The one deliberate focus steal in the
    // Autopilot flow — the user explicitly asked for the run.
    func focusAutopilotRunTab(engine: AutopilotEngine? = nil) {
        let target = engine ?? AutopilotManager.shared.allEngines.first { $0.workerTabId != nil }
        guard let id = target?.workerTabId,
              let (controller, tab) = controllerAndTab(withId: id) else {
            AutopilotStore.logGlobal("Open Run Tab: no run tab is open")
            NSSound.beep()
            return
        }
        controller.activate(tab)
        controller.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // The engine's tab factory (§2.5 launch stage): the run tab opens in the
    // active window without stealing focus. Nil only when no window exists.
    func openAutopilotRunTab(directory: String, title: String, continueSession: Bool) -> Tab? {
        activeWindowController()?.openAutopilotRunTab(
            directory: directory, title: title, continueSession: continueSession
        )
    }

    // The engine's notification hook (§2.11): merged / blocked / idle events
    // ride the attention center's existing UNUserNotificationCenter plumbing
    // (it already owns the delegate and the no-bundle-identity guard).
    func postAutopilotNotification(title: String, body: String, identifier: String) {
        attentionCenter?.postAutopilotEvent(title: title, body: body, identifier: identifier)
    }

    // Fleet activity feed: record an Autopilot run that
    // merged — a positive row that routes to its PR on GitHub (or the log when
    // there's no URL). id keyed by run so re-entry can't double-record.
    func recordAutopilotMerged(runId: String, phaseId: Int, title: String, repo: String?, prNumber: Int?, prURL: String?) {
        activityRecorder.record(ActivityEvent(
            id: "autopilot_merged-\(runId)",
            kind: .autopilotMerged,
            timestamp: Date().timeIntervalSince1970,
            title: "Phase \(phaseId): \(title)",
            detail: prNumber.map { "PR #\($0)" },
            repo: (repo == "—") ? nil : repo,
            prNumber: prNumber,
            prURL: prURL
        ))
    }

    // The blocked counterpart — a negative row that routes to the Autopilot log.
    // id carries the block instant so a genuinely new block records again.
    func recordAutopilotBlocked(reason: String, message: String, phaseId: Int?, at: TimeInterval) {
        activityRecorder.record(ActivityEvent(
            id: "autopilot_blocked-\(phaseId.map(String.init) ?? "-")-\(Int(at))",
            kind: .autopilotBlocked,
            timestamp: at,
            title: phaseId.map { "Phase \($0)" } ?? "Autopilot",
            detail: message
        ))
    }

    // "Autopilot: Show Log" / footer click while idle or blocked: the log is a
    // regular file, so it opens as a first-class viewer tab.
    func openAutopilotLog(engine: AutopilotEngine? = nil) {
        // A specific instance's per-repo log, else the running/primary one,
        // else the cross-instance global log.
        let target = engine ?? AutopilotManager.shared.targetEngine()
        let path = target?.store.logFileURL.path ?? AutopilotStore.globalLogURL.path
        if !FileManager.default.fileExists(atPath: path) {
            if let target { target.store.log("log created") } else { AutopilotStore.logGlobal("log created") }
        }
        guard let controller = activeWindowController() else {
            NSSound.beep()
            return
        }
        controller.openFile(atPath: path, line: nil)
    }

    // The §2.10 palette entries. Rebuilt per palette invocation (like the rest
    // of paletteCommands), so titles reflect the engine's current state. The
    // run-control verbs only appear while Autopilot is enabled.
    func autopilotPaletteCommands() -> [PaletteCommand] {
        var commands = [
            PaletteCommand(title: autopilotEnabled ? "Autopilot: Disable" : "Autopilot: Enable", shortcut: nil) { [weak self] in
                guard let self else { return }
                self.autopilotEnabledChanged(!self.autopilotEnabled)
            },
            PaletteCommand(title: "Autopilot: Show Log", shortcut: nil) { [weak self] in
                self?.openAutopilotLog()
            },
        ]
        guard autopilotEnabled else { return commands }
        // Start a new autopilot on the active tab's repo; open the multi-run
        // dashboard. These come first — they don't depend on a current run.
        commands.append(contentsOf: [
            PaletteCommand(title: "Autopilot: Start Here (active tab's repo)", shortcut: nil) { [weak self] in
                self?.startAutopilotHere()
            },
            PaletteCommand(title: "Autopilot: Dashboard", shortcut: nil) { [weak self] in
                self?.showAutopilotDashboard()
            },
        ])
        // The run-control verbs act on the "current" instance (running / primary
        // / first active). Titles reflect its state.
        let target = AutopilotManager.shared.targetEngine()
        // §2.9: Retry appears only while blocked — it clears the block and
        // re-adopts the kept run (or re-runs preflight when none exists).
        if let target, case .blocked = target.state {
            commands.append(PaletteCommand(title: "Autopilot: Retry", shortcut: nil) {
                target.retryAfterBlock()
            })
        }
        let paused = target.map { $0.state == .paused } ?? false
        commands.append(contentsOf: [
            PaletteCommand(title: "Autopilot: Run Next Phase Now", shortcut: nil) { [weak self] in
                self?.autopilotRunNextPhaseNow()
            },
            PaletteCommand(title: paused ? "Autopilot: Resume" : "Autopilot: Pause After Current Run", shortcut: nil) {
                if paused {
                    target?.resume()
                } else {
                    target?.pauseAfterCurrentRun()
                }
            },
            PaletteCommand(title: "Autopilot: Skip Current Phase", shortcut: nil) {
                target?.skipCurrentPhase()
            },
            PaletteCommand(title: "Autopilot: Open Run Tab", shortcut: nil) { [weak self] in
                self?.focusAutopilotRunTab()
            },
        ])
        return commands
    }

    // "Run Next Phase Now" with no active instance falls back to the configured
    // primary root, creating its engine on demand.
    func autopilotRunNextPhaseNow() {
        if let target = AutopilotManager.shared.targetEngine() {
            target.runNextPhaseNow()
            return
        }
        let primary = AutopilotManager.normalize(autopilotProjectRoot)
        guard !primary.isEmpty else {
            AutopilotStore.logGlobal("Run Next Phase Now ignored — no autopilot is running and no project is configured")
            NSSound.beep()
            return
        }
        let engine = AutopilotManager.shared.engine(for: primary)
        engine.store.markActive()
        engine.activate()
        engine.runNextPhaseNow()
    }

    // "Autopilot: Start Here" — resolve the active tab's cwd to its git root and
    // stand up (or focus) an autopilot for it.
    func startAutopilotHere() {
        if !autopilotEnabled {
            // Run the enable-time checks first; bail if the user declines.
            guard autopilotEnabledChanged(true) else { return }
        }
        guard let controller = activeWindowController(),
              let directory = controller.activeTabWorkingDirectory() else {
            let alert = NSAlert()
            alert.messageText = "No active tab to start Autopilot from"
            alert.informativeText = "Focus a terminal (or file) tab inside the git repo you want Autopilot to work on, then try again."
            alert.runModal()
            return
        }
        switch AutopilotManager.shared.startHere(directory: directory) {
        case .started(let engine):
            AutopilotStore.logGlobal("Autopilot started on \(engine.projectRoot)")
            showAutopilotDashboard()
        case .alreadyRunning(let engine):
            AutopilotStore.logGlobal("Autopilot already active on \(engine.projectRoot)")
            showAutopilotDashboard()
        case .notAGitRepo:
            let alert = NSAlert()
            alert.messageText = "That tab isn’t inside a git repository"
            alert.informativeText = "Autopilot works on a git repo containing a ROADMAP.md. Open a tab inside one and try again."
            alert.runModal()
        case .noRoadmap(let root):
            let alert = NSAlert()
            alert.messageText = "No ROADMAP.md in \(root)"
            alert.informativeText = "Autopilot steers off ROADMAP.md. Add one to the repo root, then Start Here."
            alert.runModal()
        case .notEnabled:
            break // handled by the guard above
        }
    }

    func showAutopilotDashboard() {
        autopilotDashboard.show(relativeTo: activeWindowController()?.window)
    }
}
