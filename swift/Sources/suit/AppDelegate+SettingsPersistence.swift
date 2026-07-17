import Cocoa

// The UserDefaults double-entry ledger: loadSettings restores every persisted
// setting at launch, saveSettings writes them all back after any change. The
// two lists MUST mirror each other — a key added to one but not the other
// silently fails to persist or restore. Adding a setting means touching three
// places: the AppDelegate property, its `…Changed` handler (+Appearance or
// +Settings), and both halves here.
extension AppDelegate {
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
        if defaults.object(forKey: "blurRadius") != nil {
            blurRadius = min(maxBlurRadius, max(0, CGFloat(defaults.double(forKey: "blurRadius"))))
        }
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
        if defaults.object(forKey: "taskDoneSoundEnabled") != nil {
            taskDoneSoundEnabled = defaults.bool(forKey: "taskDoneSoundEnabled")
        }
        if defaults.object(forKey: "needsInputSoundEnabled") != nil {
            needsInputSoundEnabled = defaults.bool(forKey: "needsInputSoundEnabled")
        }
        if let name = defaults.string(forKey: "taskDoneSoundName") {
            taskDoneSoundName = name
        }
        if let name = defaults.string(forKey: "needsInputSoundName") {
            needsInputSoundName = name
        }
        if defaults.object(forKey: "goalPrependProvenanceEnabled") != nil {
            goalPrependProvenanceEnabled = defaults.bool(forKey: "goalPrependProvenanceEnabled")
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
        if defaults.object(forKey: "autopilotModelRouting") != nil {
            autopilotModelRouting = defaults.bool(forKey: "autopilotModelRouting")
        }
        if defaults.object(forKey: "autopilotPreventSleep") != nil {
            autopilotPreventSleep = defaults.bool(forKey: "autopilotPreventSleep")
        }
        // Cost budget guardrails.
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
        defaults.set(Double(blurRadius), forKey: "blurRadius")
        defaults.set(wordWrapEnabled, forKey: "wordWrapEnabled")
        let background = defaultTerminalBackground.usingColorSpace(.deviceRGB) ?? defaultTerminalBackground
        defaults.set(Double(background.redComponent), forKey: "defaultBgR")
        defaults.set(Double(background.greenComponent), forKey: "defaultBgG")
        defaults.set(Double(background.blueComponent), forKey: "defaultBgB")
        defaults.set(cursorStyle.persistedName, forKey: "cursorStyle")
        defaults.set(shellPath, forKey: "shellPath")
        defaults.set(bellFlashEnabled, forKey: "bellFlashEnabled")
        defaults.set(bellDockBounceEnabled, forKey: "bellDockBounceEnabled")
        defaults.set(taskDoneSoundEnabled, forKey: "taskDoneSoundEnabled")
        defaults.set(needsInputSoundEnabled, forKey: "needsInputSoundEnabled")
        defaults.set(taskDoneSoundName, forKey: "taskDoneSoundName")
        defaults.set(needsInputSoundName, forKey: "needsInputSoundName")
        defaults.set(goalPrependProvenanceEnabled, forKey: "goalPrependProvenanceEnabled")
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
        defaults.set(autopilotModelRouting, forKey: "autopilotModelRouting")
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
