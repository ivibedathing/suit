import Cocoa

extension AppDelegate {
    // MARK: - Autopilot (ROADMAP Phase 32)

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
        AutopilotStore.shared.log(enabled ? "Autopilot enabled" : "Autopilot disabled")
        AutopilotEngine.shared.settingsChanged()
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
        AutopilotEngine.shared.settingsChanged()
        return true
    }

    func autopilotModeChanged(_ mode: AutopilotBudgetMode) {
        autopilotMode = mode
        saveSettings()
        AutopilotEngine.shared.settingsChanged()
    }

    func autopilotNightStartChanged(_ hour: Int) {
        autopilotNightStart = min(23, max(0, hour))
        saveSettings()
        AutopilotEngine.shared.settingsChanged()
    }

    func autopilotNightEndChanged(_ hour: Int) {
        autopilotNightEnd = min(23, max(0, hour))
        saveSettings()
        AutopilotEngine.shared.settingsChanged()
    }

    func autopilotFiveHourCeilingChanged(_ pct: Int) {
        autopilotFiveHourCeiling = min(100, max(0, pct))
        saveSettings()
        AutopilotEngine.shared.settingsChanged()
    }

    func autopilotWeeklyCeilingChanged(_ pct: Int) {
        autopilotWeeklyCeiling = min(100, max(0, pct))
        saveSettings()
        AutopilotEngine.shared.settingsChanged()
    }

    func autopilotWeeklyHardStopChanged(_ pct: Int) {
        autopilotWeeklyHardStop = min(100, max(0, pct))
        saveSettings()
        AutopilotEngine.shared.settingsChanged()
    }

    func autopilotPaceTargetChanged(_ pct: Int) {
        autopilotPaceTargetPct = min(100, max(1, pct))
        saveSettings()
        AutopilotEngine.shared.settingsChanged()
    }

    func autopilotMaxGateAttemptsChanged(_ attempts: Int) {
        autopilotMaxGateAttempts = min(9, max(1, attempts))
        saveSettings()
        AutopilotEngine.shared.settingsChanged()
    }

    func autopilotStallMinutesChanged(_ minutes: Int) {
        autopilotStallMinutes = min(24 * 60, max(5, minutes))
        saveSettings()
        AutopilotEngine.shared.settingsChanged()
    }

    // Newline-free (the launch path types this into zsh as one line, §2.5).
    func autopilotExtraArgsChanged(_ args: String) {
        autopilotExtraArgs = args
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        saveSettings()
        AutopilotEngine.shared.settingsChanged()
    }

    func autopilotReviewModelChanged(_ model: String) {
        autopilotReviewModel = model.trimmingCharacters(in: .whitespaces)
        saveSettings()
        AutopilotEngine.shared.settingsChanged()
    }

    func autopilotPreventSleepChanged(_ enabled: Bool) {
        autopilotPreventSleep = enabled
        saveSettings()
        AutopilotEngine.shared.settingsChanged()
    }

    // Footer row / palette "Open Run Tab" / notification click-through: focus
    // the worker tab wherever it lives. The one deliberate focus steal in the
    // Autopilot flow — the user explicitly asked for the run.
    func focusAutopilotRunTab() {
        guard let id = AutopilotEngine.shared.workerTabId,
              let (controller, tab) = controllerAndTab(withId: id) else {
            AutopilotStore.shared.log("Open Run Tab: no run tab is open")
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

    // "Autopilot: Show Log" / footer click while idle or blocked: the log is a
    // regular file, so it opens as a first-class viewer tab.
    func openAutopilotLog() {
        let path = AutopilotStore.shared.logFileURL.path
        if !FileManager.default.fileExists(atPath: path) {
            AutopilotStore.shared.log("log created")
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
        // §2.9: Retry appears only while blocked — it clears the block and
        // re-adopts the kept run (or re-runs preflight when none exists).
        if case .blocked = AutopilotEngine.shared.state {
            commands.append(PaletteCommand(title: "Autopilot: Retry", shortcut: nil) {
                AutopilotEngine.shared.retryAfterBlock()
            })
        }
        let paused = AutopilotEngine.shared.state == .paused
        commands.append(contentsOf: [
            PaletteCommand(title: "Autopilot: Run Next Phase Now", shortcut: nil) {
                AutopilotEngine.shared.runNextPhaseNow()
            },
            PaletteCommand(title: paused ? "Autopilot: Resume" : "Autopilot: Pause After Current Run", shortcut: nil) {
                if paused {
                    AutopilotEngine.shared.resume()
                } else {
                    AutopilotEngine.shared.pauseAfterCurrentRun()
                }
            },
            PaletteCommand(title: "Autopilot: Skip Current Phase", shortcut: nil) {
                AutopilotEngine.shared.skipCurrentPhase()
            },
            PaletteCommand(title: "Autopilot: Open Run Tab", shortcut: nil) { [weak self] in
                self?.focusAutopilotRunTab()
            },
        ])
        return commands
    }
}
