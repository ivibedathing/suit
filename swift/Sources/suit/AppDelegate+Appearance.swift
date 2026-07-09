import Cocoa

extension AppDelegate {
    // MARK: - Opacity & blur

    @objc func increaseOpacity(_ sender: Any?) {
        opacityChanged(min(1, backgroundAlpha + opacityStep))
    }

    @objc func decreaseOpacity(_ sender: Any?) {
        opacityChanged(max(minOpacity, backgroundAlpha - opacityStep))
    }

    @objc func toggleBlur(_ sender: Any?) {
        blurChanged(!blurEnabled)
    }

    func opacityChanged(_ value: CGFloat) {
        backgroundAlpha = value
        for controller in windowControllers {
            controller.applyTransparency(alpha: backgroundAlpha, blurEnabled: blurEnabled)
        }
        saveSettings()
    }

    func blurChanged(_ enabled: Bool) {
        blurEnabled = enabled
        for controller in windowControllers {
            controller.applyTransparency(alpha: backgroundAlpha, blurEnabled: blurEnabled)
        }
        saveSettings()
    }

    // MARK: - Word wrap (file viewers)

    @objc func toggleWordWrap(_ sender: Any?) {
        wordWrapChanged(!wordWrapEnabled)
    }

    func wordWrapChanged(_ wrap: Bool) {
        wordWrapEnabled = wrap
        for controller in windowControllers {
            controller.applyWordWrap(wordWrapEnabled)
        }
        saveSettings()
    }

    // MARK: - Settings

    @objc func showSettings(_ sender: Any?) {
        settingsWindowController.show()
    }

    func beginChoosingFont() {
        NSFontManager.shared.target = self
        NSFontManager.shared.setSelectedFont(currentFont, isMultiple: false)
        NSFontManager.shared.orderFrontFontPanel(self)
    }

    // The exact selector NSFontManager sends up the responder chain when the user
    // picks a font in the font panel.
    @objc func changeFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        currentFont = sender.convert(currentFont)
        for controller in windowControllers {
            controller.applyFont(currentFont)
        }
        settingsWindowController.updateFontLabel(currentFont)
        saveSettings()
    }

    // Cmd-=/Cmd--: size just the focused pane. Cmd-Shift-=/Cmd-Shift--: every
    // pane steps relative to its own size (so per-pane overrides keep their
    // offset) and the global default moves with them for future panes.
    @objc func increaseFontSize(_ sender: Any?) {
        adjustFocusedPaneFontSize(by: 1)
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        adjustFocusedPaneFontSize(by: -1)
    }

    @objc func increaseAllFontSizes(_ sender: Any?) {
        adjustAllPaneFontSizes(by: 1)
    }

    @objc func decreaseAllFontSizes(_ sender: Any?) {
        adjustAllPaneFontSizes(by: -1)
    }

    private func adjustFocusedPaneFontSize(by delta: CGFloat) {
        guard let pane = activeWindowController()?.focusedPane() else {
            NSSound.beep()
            return
        }
        adjustPaneFontSize(pane, by: delta)
    }

    private func adjustAllPaneFontSizes(by delta: CGFloat) {
        currentFont = NSFontManager.shared.convert(currentFont, toSize: clampedFontSize(currentFont.pointSize + delta))
        for controller in windowControllers {
            for pane in controller.panes {
                adjustPaneFontSize(pane, by: delta)
            }
        }
        settingsWindowController.updateFontLabel(currentFont)
        saveSettings()
    }

    private func adjustPaneFontSize(_ pane: Pane, by delta: CGFloat) {
        let font = pane.appliedFont ?? currentFont
        pane.setFont(NSFontManager.shared.convert(font, toSize: clampedFontSize(font.pointSize + delta)))
    }

    private func clampedFontSize(_ size: CGFloat) -> CGFloat {
        min(maxFontSize, max(minFontSize, size))
    }

    func fontSizeChanged(_ size: CGFloat) {
        currentFont = NSFontManager.shared.convert(currentFont, toSize: size)
        for controller in windowControllers {
            controller.applyFont(currentFont)
        }
        settingsWindowController.updateFontLabel(currentFont)
        saveSettings()
    }

    func textColorChanged(_ color: NSColor) {
        currentTextColor = color
        for controller in windowControllers {
            controller.applyTextColor(color)
        }
        saveSettings()
    }

    // Like textColorChanged, the new default repaints every pane — including
    // ones with a per-pane menu override, which the user can re-pick.
    func defaultBackgroundChanged(_ color: NSColor) {
        defaultTerminalBackground = color
        for controller in windowControllers {
            controller.applyDefaultBackground(color)
        }
        saveSettings()
    }

    func cursorStyleChanged(_ style: CursorStyle) {
        cursorStyle = style
        for controller in windowControllers {
            controller.applyCursorStyle(style)
        }
        saveSettings()
    }

    // Only accepts executable paths (a bad shell would exec-fail every new
    // tab); returns whether the value was taken so the settings field can
    // revert. Running shells are untouched — this is a new-tab default.
    @discardableResult
    func shellPathChanged(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: expanded) else { return false }
        shellPath = expanded
        saveSettings()
        return true
    }

    func claudeSessionArgsChanged(_ args: String) {
        claudeSessionArgs = args.trimmingCharacters(in: .whitespaces)
        saveSettings()
    }

    func taskIsolateByDefaultChanged(_ enabled: Bool) {
        taskIsolateByDefault = enabled
        saveSettings()
    }

    func bellFlashChanged(_ enabled: Bool) {
        bellFlashEnabled = enabled
        saveSettings()
    }

    func bellDockBounceChanged(_ enabled: Bool) {
        bellDockBounceEnabled = enabled
        saveSettings()
    }

    func goalProvenanceChanged(_ enabled: Bool) {
        goalPrependProvenanceEnabled = enabled
        saveSettings()
    }

    // Toggle rtk output compression: persist the preference, then install or
    // remove the PreToolUse hook in ~/.claude/settings.json. Best-effort — the
    // preference sticks even if the settings write fails (e.g. the bundled
    // rewrite script isn't found on a dev run); the failure is logged, not fatal.
    func rtkCompressionChanged(_ enabled: Bool) {
        rtkCompressionEnabled = enabled
        saveSettings()
        do {
            _ = try RtkHook.setEnabled(enabled)
        } catch {
            NSLog("Suit: rtk compression \(enabled ? "install" : "removal") failed: \(error.localizedDescription)")
        }
        // The hook fails open, so a missing rtk isn't fatal — but say so plainly
        // rather than letting the toggle look active while nothing compresses.
        if enabled, !RtkHook.rtkAvailable() {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "rtk isn’t installed"
            alert.informativeText = "The hook is installed, but rtk isn’t on your PATH, so commands run unchanged (no compression) until it is. Install rtk (e.g. cargo install rtk, or place it on your PATH) — Suit picks it up automatically, and bundles it when it’s present at build time."
            alert.runModal()
        }
    }

    // MARK: - Settings persistence

    func loadSettings() {
        let defaults = UserDefaults.standard
        if let fontName = defaults.string(forKey: "fontName") {
            let size = defaults.double(forKey: "fontSize")
            currentFont = NSFont(name: fontName, size: size > 0 ? CGFloat(size) : currentFont.pointSize) ?? currentFont
        }
        if defaults.object(forKey: "textColorR") != nil {
            currentTextColor = NSColor(
                calibratedRed: CGFloat(defaults.double(forKey: "textColorR")),
                green: CGFloat(defaults.double(forKey: "textColorG")),
                blue: CGFloat(defaults.double(forKey: "textColorB")),
                alpha: CGFloat(defaults.double(forKey: "textColorA"))
            )
        }
        if defaults.object(forKey: "backgroundAlpha") != nil {
            backgroundAlpha = CGFloat(defaults.double(forKey: "backgroundAlpha"))
        }
        blurEnabled = defaults.bool(forKey: "blurEnabled")
        if defaults.object(forKey: "wordWrapEnabled") != nil {
            wordWrapEnabled = defaults.bool(forKey: "wordWrapEnabled")
        }
        if defaults.object(forKey: "defaultBgR") != nil {
            defaultTerminalBackground = NSColor(
                calibratedRed: CGFloat(defaults.double(forKey: "defaultBgR")),
                green: CGFloat(defaults.double(forKey: "defaultBgG")),
                blue: CGFloat(defaults.double(forKey: "defaultBgB")),
                alpha: 1
            )
        }
        if let raw = defaults.string(forKey: "cursorStyle"), let style = CursorStyle.from(string: raw) {
            cursorStyle = style
        }
        // Re-validate at load: the shell may have been uninstalled since.
        if let shell = defaults.string(forKey: "shellPath"),
           FileManager.default.isExecutableFile(atPath: shell) {
            shellPath = shell
        }
        if defaults.object(forKey: "bellFlashEnabled") != nil {
            bellFlashEnabled = defaults.bool(forKey: "bellFlashEnabled")
        }
        if defaults.object(forKey: "bellDockBounceEnabled") != nil {
            bellDockBounceEnabled = defaults.bool(forKey: "bellDockBounceEnabled")
        }
        if defaults.object(forKey: "goalPrependProvenanceEnabled") != nil {
            goalPrependProvenanceEnabled = defaults.bool(forKey: "goalPrependProvenanceEnabled")
        }
        if defaults.object(forKey: "rtkCompressionEnabled") != nil {
            rtkCompressionEnabled = defaults.bool(forKey: "rtkCompressionEnabled")
        }
        if let args = defaults.string(forKey: "claudeSessionArgs") {
            claudeSessionArgs = args
        }
        if defaults.object(forKey: "taskIsolateByDefault") != nil {
            taskIsolateByDefault = defaults.bool(forKey: "taskIsolateByDefault")
        }
        // Autopilot (§2.9): bare camelCase keys, one per table row.
        autopilotEnabled = defaults.bool(forKey: "autopilotEnabled")
        if let root = defaults.string(forKey: "autopilotProjectRoot") {
            autopilotProjectRoot = root
        }
        if let raw = defaults.string(forKey: "autopilotMode"),
           let mode = AutopilotBudgetMode(rawValue: raw) {
            autopilotMode = mode
        }
        if defaults.object(forKey: "autopilotNightStart") != nil {
            autopilotNightStart = defaults.integer(forKey: "autopilotNightStart")
        }
        if defaults.object(forKey: "autopilotNightEnd") != nil {
            autopilotNightEnd = defaults.integer(forKey: "autopilotNightEnd")
        }
        if defaults.object(forKey: "autopilotFiveHourCeiling") != nil {
            autopilotFiveHourCeiling = defaults.integer(forKey: "autopilotFiveHourCeiling")
        }
        if defaults.object(forKey: "autopilotWeeklyCeiling") != nil {
            autopilotWeeklyCeiling = defaults.integer(forKey: "autopilotWeeklyCeiling")
        }
        if defaults.object(forKey: "autopilotWeeklyHardStop") != nil {
            autopilotWeeklyHardStop = defaults.integer(forKey: "autopilotWeeklyHardStop")
        }
        if defaults.object(forKey: "autopilotPaceTargetPct") != nil {
            autopilotPaceTargetPct = defaults.integer(forKey: "autopilotPaceTargetPct")
        }
        if defaults.object(forKey: "autopilotMaxGateAttempts") != nil {
            autopilotMaxGateAttempts = defaults.integer(forKey: "autopilotMaxGateAttempts")
        }
        if defaults.object(forKey: "autopilotStallMinutes") != nil {
            autopilotStallMinutes = defaults.integer(forKey: "autopilotStallMinutes")
        }
        if let args = defaults.string(forKey: "autopilotExtraArgs") {
            autopilotExtraArgs = args
        }
        if let model = defaults.string(forKey: "autopilotReviewModel") {
            autopilotReviewModel = model
        }
        if defaults.object(forKey: "autopilotPreventSleep") != nil {
            autopilotPreventSleep = defaults.bool(forKey: "autopilotPreventSleep")
        }
        // Cost budget guardrails (ROADMAP Phase 42).
        if defaults.object(forKey: "budgetSessionCap") != nil {
            budgetSessionCap = defaults.double(forKey: "budgetSessionCap")
        }
        if defaults.object(forKey: "budgetTaskCap") != nil {
            budgetTaskCap = defaults.double(forKey: "budgetTaskCap")
        }
        budgetAutoInterrupt = defaults.bool(forKey: "budgetAutoInterrupt")
        if let raw = defaults.dictionary(forKey: "budgetPerSession") {
            budgetPerSession = raw.compactMapValues { ($0 as? NSNumber)?.doubleValue }
        }
    }

    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(currentFont.fontName, forKey: "fontName")
        defaults.set(Double(currentFont.pointSize), forKey: "fontSize")
        let color = currentTextColor.usingColorSpace(.deviceRGB) ?? currentTextColor
        defaults.set(Double(color.redComponent), forKey: "textColorR")
        defaults.set(Double(color.greenComponent), forKey: "textColorG")
        defaults.set(Double(color.blueComponent), forKey: "textColorB")
        defaults.set(Double(color.alphaComponent), forKey: "textColorA")
        defaults.set(Double(backgroundAlpha), forKey: "backgroundAlpha")
        defaults.set(blurEnabled, forKey: "blurEnabled")
        defaults.set(wordWrapEnabled, forKey: "wordWrapEnabled")
        let background = defaultTerminalBackground.usingColorSpace(.deviceRGB) ?? defaultTerminalBackground
        defaults.set(Double(background.redComponent), forKey: "defaultBgR")
        defaults.set(Double(background.greenComponent), forKey: "defaultBgG")
        defaults.set(Double(background.blueComponent), forKey: "defaultBgB")
        defaults.set(cursorStyle.persistedName, forKey: "cursorStyle")
        defaults.set(shellPath, forKey: "shellPath")
        defaults.set(bellFlashEnabled, forKey: "bellFlashEnabled")
        defaults.set(bellDockBounceEnabled, forKey: "bellDockBounceEnabled")
        defaults.set(goalPrependProvenanceEnabled, forKey: "goalPrependProvenanceEnabled")
        defaults.set(rtkCompressionEnabled, forKey: "rtkCompressionEnabled")
        defaults.set(claudeSessionArgs, forKey: "claudeSessionArgs")
        defaults.set(taskIsolateByDefault, forKey: "taskIsolateByDefault")
        defaults.set(autopilotEnabled, forKey: "autopilotEnabled")
        defaults.set(autopilotProjectRoot, forKey: "autopilotProjectRoot")
        defaults.set(autopilotMode.rawValue, forKey: "autopilotMode")
        defaults.set(autopilotNightStart, forKey: "autopilotNightStart")
        defaults.set(autopilotNightEnd, forKey: "autopilotNightEnd")
        defaults.set(autopilotFiveHourCeiling, forKey: "autopilotFiveHourCeiling")
        defaults.set(autopilotWeeklyCeiling, forKey: "autopilotWeeklyCeiling")
        defaults.set(autopilotWeeklyHardStop, forKey: "autopilotWeeklyHardStop")
        defaults.set(autopilotPaceTargetPct, forKey: "autopilotPaceTargetPct")
        defaults.set(autopilotMaxGateAttempts, forKey: "autopilotMaxGateAttempts")
        defaults.set(autopilotStallMinutes, forKey: "autopilotStallMinutes")
        defaults.set(autopilotExtraArgs, forKey: "autopilotExtraArgs")
        defaults.set(autopilotReviewModel, forKey: "autopilotReviewModel")
        defaults.set(autopilotPreventSleep, forKey: "autopilotPreventSleep")
        defaults.set(budgetSessionCap, forKey: "budgetSessionCap")
        defaults.set(budgetTaskCap, forKey: "budgetTaskCap")
        defaults.set(budgetAutoInterrupt, forKey: "budgetAutoInterrupt")
        defaults.set(budgetPerSession, forKey: "budgetPerSession")
    }
}

// The inverse of SwiftTerm's CursorStyle.from(string:), for UserDefaults.
extension CursorStyle {
    var persistedName: String {
        switch self {
        case .blinkBlock: return "blinkBlock"
        case .steadyBlock: return "steadyBlock"
        case .blinkUnderline: return "blinkUnderline"
        case .steadyUnderline: return "steadyUnderline"
        case .blinkBar: return "blinkBar"
        case .steadyBar: return "steadyBar"
        }
    }
}
