import Cocoa

// The settings window's control-action handlers: cursor-style mapping, the
// @objc targets every control fires, the NSTextFieldDelegate commit logic, and
// the Autopilot section's numeric-stepper dispatch. Split out of
// SettingsWindowController.swift; the stored controls they read/write live there.
extension SettingsWindowController {
    // MARK: - Cursor style <-> popup + checkbox

    static func cursorStyle(shape: Int, blinking: Bool) -> CursorStyle {
        switch shape {
        case 1: return blinking ? .blinkUnderline : .steadyUnderline
        case 2: return blinking ? .blinkBar : .steadyBar
        default: return blinking ? .blinkBlock : .steadyBlock
        }
    }

    static func components(of style: CursorStyle) -> (shape: Int, blinking: Bool) {
        switch style {
        case .blinkBlock: return (0, true)
        case .steadyBlock: return (0, false)
        case .blinkUnderline: return (1, true)
        case .steadyUnderline: return (1, false)
        case .blinkBar: return (2, true)
        case .steadyBar: return (2, false)
        }
    }

    // MARK: - Actions

    @objc func chooseFont(_ sender: Any?) {
        appDelegate?.beginChoosingFont()
    }

    @objc func fontSizeChanged(_ sender: NSStepper) {
        appDelegate?.fontSizeChanged(CGFloat(sender.doubleValue))
    }

    @objc func textColorChanged(_ sender: NSColorWell) {
        appDelegate?.textColorChanged(sender.color)
    }

    @objc func backgroundColorChanged(_ sender: NSColorWell) {
        appDelegate?.defaultBackgroundChanged(sender.color)
    }

    @objc func resetBackgroundColor(_ sender: Any?) {
        backgroundColorWell.color = Theme.terminalBg
        appDelegate?.defaultBackgroundChanged(Theme.terminalBg)
    }

    @objc func opacityChanged(_ sender: NSSlider) {
        appDelegate?.opacityChanged(CGFloat(sender.doubleValue))
    }

    @objc func blurChanged(_ sender: NSButton) {
        appDelegate?.blurChanged(sender.state == .on)
    }

    // Commit on Enter or focus loss. The shell path is validated (an invalid
    // path beeps and the field snaps back); the Claude arguments are free-form.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let appDelegate else { return }
        if (notification.object as? NSTextField) === claudeArgsField {
            appDelegate.claudeSessionArgsChanged(claudeArgsField.stringValue)
            claudeArgsField.stringValue = appDelegate.claudeSessionArgs
            return
        }
        // Autopilot fields: the project path is validated like the shell path
        // (git repo with a ROADMAP.md — invalid beeps and snaps back), the
        // extra args and review model are free-form (args get newline-stripped).
        if (notification.object as? NSTextField) === autopilotProjectField {
            let entered = autopilotProjectField.stringValue.trimmingCharacters(in: .whitespaces)
            if entered != appDelegate.autopilotProjectRoot,
               !appDelegate.autopilotProjectRootChanged(entered) {
                NSSound.beep()
            }
            autopilotProjectField.stringValue = appDelegate.autopilotProjectRoot
            return
        }
        if (notification.object as? NSTextField) === autopilotExtraArgsField {
            appDelegate.autopilotExtraArgsChanged(autopilotExtraArgsField.stringValue)
            autopilotExtraArgsField.stringValue = appDelegate.autopilotExtraArgs
            return
        }
        if (notification.object as? NSTextField) === autopilotReviewModelField {
            appDelegate.autopilotReviewModelChanged(autopilotReviewModelField.stringValue)
            autopilotReviewModelField.stringValue = appDelegate.autopilotReviewModel
            return
        }
        guard (notification.object as? NSTextField) === shellField else { return }
        let entered = shellField.stringValue.trimmingCharacters(in: .whitespaces)
        if !entered.isEmpty, entered != appDelegate.shellPath, !appDelegate.shellPathChanged(entered) {
            NSSound.beep()
        }
        shellField.stringValue = appDelegate.shellPath
    }

    @objc func cursorStyleChanged(_ sender: Any?) {
        appDelegate?.cursorStyleChanged(Self.cursorStyle(
            shape: cursorShapePopup.indexOfSelectedItem,
            blinking: cursorBlinkCheckbox.state == .on
        ))
    }

    @objc func bellFlashChanged(_ sender: NSButton) {
        appDelegate?.bellFlashChanged(sender.state == .on)
    }

    @objc func bellBounceChanged(_ sender: NSButton) {
        appDelegate?.bellDockBounceChanged(sender.state == .on)
    }

    @objc func wordWrapChanged(_ sender: NSButton) {
        appDelegate?.wordWrapChanged(sender.state == .on)
    }

    @objc func goalProvenanceChanged(_ sender: NSButton) {
        appDelegate?.goalProvenanceChanged(sender.state == .on)
    }

    @objc func taskIsolateChanged(_ sender: NSButton) {
        appDelegate?.taskIsolateByDefaultChanged(sender.state == .on)
    }

    // MARK: - Autopilot actions (ROADMAP Phase 32)

    // Enabling runs the §2.3 enable-time checks in AppDelegate (Claude
    // integration installed, gh hint); a refusal snaps the checkbox back.
    @objc func autopilotEnabledToggled(_ sender: NSButton) {
        guard let appDelegate else { return }
        if !appDelegate.autopilotEnabledChanged(sender.state == .on) {
            sender.state = appDelegate.autopilotEnabled ? .on : .off
        }
    }

    @objc func autopilotChooseProject(_ sender: Any?) {
        guard let appDelegate else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a git repository containing ROADMAP.md"
        if !appDelegate.autopilotProjectRoot.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: appDelegate.autopilotProjectRoot)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if appDelegate.autopilotProjectRootChanged(url.path) {
            autopilotProjectField.stringValue = appDelegate.autopilotProjectRoot
        } else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Not an Autopilot project"
            alert.informativeText = "\(url.path) isn’t usable: Autopilot needs a git repository whose root contains ROADMAP.md."
            alert.runModal()
        }
    }

    @objc func autopilotModePicked(_ sender: Any?) {
        let modes = AutopilotBudgetMode.allCases
        let index = autopilotModePopup.indexOfSelectedItem
        guard modes.indices.contains(index) else { return }
        appDelegate?.autopilotModeChanged(modes[index])
        updateAutopilotNightEnabled()
    }

    // The night-hours steppers only matter in night mode.
    func updateAutopilotNightEnabled() {
        let night = appDelegate?.autopilotMode == .nightShift
        autopilotNightStartStepper.isEnabled = night
        autopilotNightEndStepper.isEnabled = night
    }

    // One selector for all eight numeric settings, dispatched by identity;
    // the label re-reads the (clamped) value AppDelegate actually took.
    @objc func autopilotStepperChanged(_ sender: NSStepper) {
        guard let appDelegate else { return }
        let value = Int(sender.doubleValue)
        switch sender {
        case autopilotNightStartStepper.stepper:
            appDelegate.autopilotNightStartChanged(value)
            autopilotNightStartStepper.intValue = appDelegate.autopilotNightStart
        case autopilotNightEndStepper.stepper:
            appDelegate.autopilotNightEndChanged(value)
            autopilotNightEndStepper.intValue = appDelegate.autopilotNightEnd
        case autopilotFiveHourStepper.stepper:
            appDelegate.autopilotFiveHourCeilingChanged(value)
            autopilotFiveHourStepper.intValue = appDelegate.autopilotFiveHourCeiling
        case autopilotWeeklyStepper.stepper:
            appDelegate.autopilotWeeklyCeilingChanged(value)
            autopilotWeeklyStepper.intValue = appDelegate.autopilotWeeklyCeiling
        case autopilotHardStopStepper.stepper:
            appDelegate.autopilotWeeklyHardStopChanged(value)
            autopilotHardStopStepper.intValue = appDelegate.autopilotWeeklyHardStop
        case autopilotPaceStepper.stepper:
            appDelegate.autopilotPaceTargetChanged(value)
            autopilotPaceStepper.intValue = appDelegate.autopilotPaceTargetPct
        case autopilotAttemptsStepper.stepper:
            appDelegate.autopilotMaxGateAttemptsChanged(value)
            autopilotAttemptsStepper.intValue = appDelegate.autopilotMaxGateAttempts
        case autopilotStallStepper.stepper:
            appDelegate.autopilotStallMinutesChanged(value)
            autopilotStallStepper.intValue = appDelegate.autopilotStallMinutes
        default:
            break
        }
    }

    @objc func autopilotKeepAwakeChanged(_ sender: NSButton) {
        appDelegate?.autopilotPreventSleepChanged(sender.state == .on)
    }
}
