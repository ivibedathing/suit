import Cocoa
import UniformTypeIdentifiers

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
        // Auto-/compact focus instructions: free-form, empty = plain /compact.
        if (notification.object as? NSTextField) === autoCompactInstructionsField {
            appDelegate.autoCompactInstructionsChanged(autoCompactInstructionsField.stringValue)
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
        // Claude API fields: free-form strings commit as-is (sanitized by the
        // setter); the token counts parse like the dollar caps below.
        if (notification.object as? NSTextField) === apiModelField {
            commitClaudeAPI { $0.model = self.apiModelField.stringValue }
            return
        }
        if (notification.object as? NSTextField) === apiSubagentModelField {
            commitClaudeAPI { $0.subagentModel = self.apiSubagentModelField.stringValue }
            return
        }
        if (notification.object as? NSTextField) === apiCustomHeadersField {
            commitClaudeAPI { $0.customHeaders = self.apiCustomHeadersField.stringValue }
            return
        }
        if (notification.object as? NSTextField) === apiExtraEnvField {
            commitClaudeAPI { $0.extraEnv = self.apiExtraEnvField.stringValue }
            return
        }
        if (notification.object as? NSTextField) === apiThinkingTokensField {
            commitClaudeAPI {
                $0.thinkingTokens = Self.parseTokenCount(self.apiThinkingTokensField.stringValue, current: $0.thinkingTokens)
            }
            return
        }
        if (notification.object as? NSTextField) === apiMaxOutputTokensField {
            commitClaudeAPI {
                $0.maxOutputTokens = Self.parseTokenCount(self.apiMaxOutputTokensField.stringValue, current: $0.maxOutputTokens)
            }
            return
        }
        // Budget caps: a dollar amount, or blank/0 for off.
        // A non-numeric entry beeps and snaps back.
        if (notification.object as? NSTextField) === budgetSessionCapField {
            appDelegate.budgetSessionCap = Self.parseDollarCap(budgetSessionCapField.stringValue, current: appDelegate.budgetSessionCap)
            appDelegate.saveSettings()
            budgetSessionCapField.stringValue = SettingsWindowController.dollarString(appDelegate.budgetSessionCap)
            return
        }
        if (notification.object as? NSTextField) === budgetTaskCapField {
            appDelegate.budgetTaskCap = Self.parseDollarCap(budgetTaskCapField.stringValue, current: appDelegate.budgetTaskCap)
            appDelegate.saveSettings()
            budgetTaskCapField.stringValue = SettingsWindowController.dollarString(appDelegate.budgetTaskCap)
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

    @objc func taskDoneSoundEnabledChanged(_ sender: NSButton) {
        appDelegate?.taskDoneSoundEnabledChanged(sender.state == .on)
    }

    @objc func needsInputSoundEnabledChanged(_ sender: NSButton) {
        appDelegate?.needsInputSoundEnabledChanged(sender.state == .on)
    }

    // Picking a sound previews it once so the choice is audible.
    @objc func taskDoneSoundChanged(_ sender: NSPopUpButton) {
        guard let name = sender.titleOfSelectedItem else { return }
        appDelegate?.taskDoneSoundNameChanged(name)
        soundPreviewPlayer.play(named: name)
    }

    @objc func needsInputSoundChanged(_ sender: NSPopUpButton) {
        guard let name = sender.titleOfSelectedItem else { return }
        appDelegate?.needsInputSoundNameChanged(name)
        soundPreviewPlayer.play(named: name)
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

    @objc func rtkCompressionChanged(_ sender: NSButton) {
        appDelegate?.rtkCompressionChanged(sender.state == .on)
    }

    @objc func postToolCompressChanged(_ sender: NSButton) {
        appDelegate?.postToolCompressChanged(sender.state == .on)
    }

    @objc func readDedupChanged(_ sender: NSButton) {
        appDelegate?.readDedupChanged(sender.state == .on)
    }

    @objc func shellExtrasChanged(_ sender: NSButton) {
        appDelegate?.shellExtrasChanged(sender.state == .on)
    }

    @objc func autoCompactEnabledChanged(_ sender: NSButton) {
        appDelegate?.autoCompactEnabledChanged(sender.state == .on)
        autoCompactThresholdStepper.isEnabled = sender.state == .on
    }

    @objc func autoCompactThresholdChanged(_ sender: NSStepper) {
        autoCompactThresholdStepper.refreshLabel()
        appDelegate?.autoCompactThresholdChanged(autoCompactThresholdStepper.intValue)
    }

    // MARK: - Claude API actions

    // Re-read every Claude API control from the stored struct and refresh the
    // live launch-command preview. Runs from show() and after every commit, so
    // the pane always reflects the value AppDelegate actually took.
    func reloadClaudeAPIControls() {
        guard let appDelegate else { return }
        let api = appDelegate.claudeAPI
        apiModelField.stringValue = api.model
        apiSubagentModelField.stringValue = api.subagentModel
        if let index = ClaudeAPISettings.effortLevels.firstIndex(of: api.effort) {
            apiEffortPopup.selectItem(at: index + 1)   // 0 is "Default"
        } else {
            apiEffortPopup.selectItem(at: 0)
        }
        apiThinkingTokensField.stringValue = api.thinkingTokens > 0 ? String(api.thinkingTokens) : ""
        apiMaxOutputTokensField.stringValue = api.maxOutputTokens > 0 ? String(api.maxOutputTokens) : ""
        apiPromptCachingCheckbox.state = api.promptCachingEnabled ? .on : .off
        apiCustomHeadersField.stringValue = api.customHeaders
        apiExtraEnvField.stringValue = api.extraEnv
        apiPreviewLabel.stringValue = api.launchCommand(base: "claude …")
    }

    // Mutate one knob on a copy of the stored struct and commit the whole
    // thing (the struct-at-once analog of the scalar xChanged setters).
    private func commitClaudeAPI(_ mutate: (inout ClaudeAPISettings) -> Void) {
        guard let appDelegate else { return }
        var api = appDelegate.claudeAPI
        mutate(&api)
        appDelegate.claudeAPIChanged(api)
        reloadClaudeAPIControls()
    }

    @objc func apiEffortPicked(_ sender: Any?) {
        let index = apiEffortPopup.indexOfSelectedItem - 1   // -1 = "Default"
        let levels = ClaudeAPISettings.effortLevels
        commitClaudeAPI { $0.effort = levels.indices.contains(index) ? levels[index] : "" }
    }

    @objc func apiPromptCachingChanged(_ sender: NSButton) {
        commitClaudeAPI { $0.promptCachingEnabled = sender.state == .on }
    }

    // A token-count field: blank → 0 (default), a non-negative integer → that
    // count, anything else → beep and keep the current value (the parseDollarCap
    // convention, integer-shaped).
    static func parseTokenCount(_ text: String, current: Int) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return 0 }
        guard let value = Int(trimmed), value >= 0 else {
            NSSound.beep()
            return current
        }
        return value
    }

    // MARK: - Autopilot actions

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

    @objc func budgetAutoInterruptChanged(_ sender: NSButton) {
        guard let appDelegate else { return }
        appDelegate.budgetAutoInterrupt = sender.state == .on
        appDelegate.saveSettings()
    }

    // Parses a dollar-cap field: blank → 0 (off); a valid non-negative number
    // (a leading "$" tolerated) → that amount; anything else → the current
    // value unchanged with a beep, so a typo doesn't wipe a cap.
    static func parseDollarCap(_ text: String, current: Double) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
        if trimmed.isEmpty { return 0 }
        guard let value = Double(trimmed), value >= 0 else {
            NSSound.beep()
            return current
        }
        return value
    }

    // MARK: - Themes

    // A dynamic UTI for ".suittheme" (falling back to JSON), used to filter the
    // import/export panels — the format is JSON with a distinct extension.
    private static var suitThemeType: UTType? { UTType(filenameExtension: "suittheme") }

    // Rebuild the theme list from ThemeStore, preserving the current selection by
    // id (falling back to the active theme, then the first row), then sync the
    // editor. Runs from show(), and from the ThemeStore.didUpdate observer so a
    // switch/duplicate/delete/import anywhere keeps the list and checkmark fresh.
    func reloadThemes() {
        let previous = selectedThemeId()
        themeRows = ThemeStore.shared.allThemes
        themeTable.reloadData()
        selectThemeRow(id: previous ?? ThemeStore.shared.selected.id)
        themeSelectionChanged()
    }

    // Select the row for theme `id` (or row 0 if it's gone), without extending.
    func selectThemeRow(id: String) {
        if let row = themeRows.firstIndex(where: { $0.id == id }) {
            themeTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if !themeRows.isEmpty {
            themeTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    // The id of the theme selected in the list, or nil if none.
    func selectedThemeId() -> String? {
        let row = themeTable.selectedRow
        return themeRows.indices.contains(row) ? themeRows[row].id : nil
    }

    // Sync the editor to the selected theme: load its colors into the wells and
    // preview, enable the wells only for a user theme (built-ins are read-only),
    // and enable Delete/Edit accordingly. Edit turns a built-in into an editable
    // copy; user themes are edited inline through the wells.
    func themeSelectionChanged() {
        guard let id = selectedThemeId(), let info = ThemeStore.shared.theme(id: id) else {
            themeEditingPalette = nil
            themePreviewStrip.palette = nil
            for well in themeColorWells { well.isEnabled = false }
            for button in [themeApplyButton, themeDuplicateButton, themeEditButton,
                           themeExportButton, themeDeleteButton] { button.isEnabled = false }
            themeEditHint.stringValue = ""
            return
        }
        themeEditingPalette = info.palette
        themePreviewStrip.palette = info.palette
        let tokens = Theme.Palette.editableTokens
        for (i, well) in themeColorWells.enumerated() where tokens.indices.contains(i) {
            well.color = info.palette[keyPath: tokens[i].keyPath]
            well.isEnabled = !info.isBuiltIn
        }
        themeApplyButton.isEnabled = true
        themeDuplicateButton.isEnabled = true
        themeExportButton.isEnabled = true
        themeEditButton.isEnabled = info.isBuiltIn
        themeDeleteButton.isEnabled = !info.isBuiltIn
        themeEditHint.stringValue = info.isBuiltIn
            ? "Built-in theme — Duplicate (or Edit) to make an editable copy."
            : "Edit the colors below; changes apply live."
    }

    // Apply the selected theme live (ThemeStore posts Theme.didChange, which the
    // window controllers observe to re-skin every window).
    @objc func themeApply(_ sender: Any?) {
        guard let id = selectedThemeId() else { return }
        ThemeStore.shared.apply(id: id)
    }

    // Duplicate the selection into a new editable user theme and select it.
    @objc func themeDuplicate(_ sender: Any?) {
        guard let id = selectedThemeId(), let new = ThemeStore.shared.duplicate(id: id) else { return }
        selectThemeRow(id: new.id)
        themeSelectionChanged()
    }

    // Edit a built-in: since built-ins are immutable, this duplicates it into an
    // editable copy and selects that (user themes are edited inline via the wells).
    @objc func themeEdit(_ sender: Any?) {
        guard let id = selectedThemeId(), let info = ThemeStore.shared.theme(id: id),
              info.isBuiltIn, let new = ThemeStore.shared.duplicate(id: id) else { return }
        selectThemeRow(id: new.id)
        themeSelectionChanged()
    }

    // Import one or more shared ".suittheme" files as new user themes.
    @objc func themeImport(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        var types: [UTType] = [.json]
        if let t = Self.suitThemeType { types.insert(t, at: 0) }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { ThemeStore.shared.importTheme(from: url) }
    }

    // Export the selected theme's ".suittheme" file to a chosen location.
    @objc func themeExport(_ sender: Any?) {
        guard let id = selectedThemeId(), let info = ThemeStore.shared.theme(id: id) else { return }
        let panel = NSSavePanel()
        if let t = Self.suitThemeType { panel.allowedContentTypes = [t] }
        panel.nameFieldStringValue = ThemeStore.slug(info.palette.name) + ".suittheme"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !ThemeStore.shared.exportTheme(id: id, to: url) { NSSound.beep() }
    }

    // Delete the selected user theme (built-ins are ignored), after confirming.
    @objc func themeDelete(_ sender: Any?) {
        guard let id = selectedThemeId(), let info = ThemeStore.shared.theme(id: id), !info.isBuiltIn else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(info.palette.name)”?"
        alert.informativeText = "This removes the theme file from ~/.suit/themes. This can’t be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ThemeStore.shared.delete(id: id)
    }

    // Commit one token's color edit to the selected user theme: mutate the
    // working palette and refresh the preview live, but debounce the persist
    // through ThemeStore. NSColorWell fires continuously while the color panel
    // is dragged; without coalescing, every frame would write the theme file,
    // re-decode the whole catalog, and re-skin every window — dozens of times a
    // second. We persist once the drag settles (trailing edge).
    @objc func themeTokenChanged(_ sender: NSColorWell) {
        let tokens = Theme.Palette.editableTokens
        guard let index = themeColorWells.firstIndex(where: { $0 === sender }),
              tokens.indices.contains(index),
              let id = selectedThemeId(),
              var info = ThemeStore.shared.theme(id: id), !info.isBuiltIn else { return }
        var palette = themeEditingPalette ?? info.palette
        palette[keyPath: tokens[index].keyPath] = sender.color
        themeEditingPalette = palette
        themePreviewStrip.palette = palette
        info.palette = palette

        themeCommitWork?.cancel()
        let work = DispatchWorkItem { ThemeStore.shared.update(info) }
        themeCommitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}
