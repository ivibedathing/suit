import Cocoa

// Cmd-, settings window: a two-tab NSTabView. The "Settings" tab is the
// app-wide defaults form, grouped into Appearance (font, default font size,
// text color, default pane background, opacity, blur), Terminal (shell, cursor,
// bell responses), Viewer (word wrap) and Claude (default session arguments for
// the quick-access launchers). The "Shortcuts" tab is a scrollable, read-only
// keyboard-shortcut reference built from KeyboardShortcuts.groups (the single
// source of truth README.md and AppDelegate's menu mirror).
// A plain vertical form built with NSStackView + Auto Layout — safe here
// since, unlike the pane/split tree, this window's view hierarchy is never
// touched by NSSplitView's own frame management.
//
// Every control writes straight through to AppDelegate (which applies it to
// all windows and persists); show() re-reads all state, so values changed
// elsewhere (⇧⌘B blur, ⇧⌘= font size, the palette) are fresh each time the
// window opens.
//
// The form/section builders live in SettingsWindowController+Sections.swift and
// the control-action handlers in SettingsWindowController+Actions.swift; stored
// properties (which Swift forbids in extensions) stay here in the primary
// declaration.
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    weak var appDelegate: AppDelegate?

    let fontLabel = NSTextField(labelWithString: "")
    let fontSizeLabel = NSTextField(labelWithString: "")
    let fontSizeStepper = NSStepper(frame: NSRect(x: 0, y: 0, width: 19, height: 27))
    let textColorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
    let backgroundColorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
    let opacitySlider = NSSlider(value: 1, minValue: 0.3, maxValue: 1, target: nil, action: nil)
    let blurCheckbox = NSButton(checkboxWithTitle: "Background Blur", target: nil, action: nil)

    let shellField = NSTextField(string: "")
    let cursorShapePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let cursorBlinkCheckbox = NSButton(checkboxWithTitle: "Blinking", target: nil, action: nil)
    let bellFlashCheckbox = NSButton(checkboxWithTitle: "Flash pane on bell", target: nil, action: nil)
    let bellBounceCheckbox = NSButton(checkboxWithTitle: "Bounce Dock icon on bell when inactive", target: nil, action: nil)

    let wordWrapCheckbox = NSButton(checkboxWithTitle: "Word wrap long lines", target: nil, action: nil)

    let claudeArgsField = NSTextField(string: "")
    let goalProvenanceCheckbox = NSButton(checkboxWithTitle: "Prepend source location to goals (From file:lines:)", target: nil, action: nil)

    // Autopilot (ROADMAP Phase 32, §2.9): every control writes through
    // appDelegate.autopilotXChanged(...) and is re-read in show().
    let autopilotEnabledCheckbox = NSButton(checkboxWithTitle: "Work through ROADMAP.md autonomously", target: nil, action: nil)
    let autopilotProjectField = NSTextField(string: "")
    let autopilotModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let autopilotNightStartStepper = LabeledStepper(min: 0, max: 23, suffix: "h")
    let autopilotNightEndStepper = LabeledStepper(min: 0, max: 23, suffix: "h")
    let autopilotFiveHourStepper = LabeledStepper(min: 0, max: 100, suffix: "%")
    let autopilotWeeklyStepper = LabeledStepper(min: 0, max: 100, suffix: "%")
    let autopilotHardStopStepper = LabeledStepper(min: 0, max: 100, suffix: "%")
    let autopilotPaceStepper = LabeledStepper(min: 1, max: 100, suffix: "%")
    let autopilotAttemptsStepper = LabeledStepper(min: 1, max: 9, suffix: "")
    let autopilotStallStepper = LabeledStepper(min: 5, max: 240, suffix: " min")
    let autopilotExtraArgsField = NSTextField(string: "")
    let autopilotReviewModelField = NSTextField(string: "")
    let autopilotKeepAwakeCheckbox = NSButton(checkboxWithTitle: "Keep the Mac awake during runs", target: nil, action: nil)

    convenience init(appDelegate: AppDelegate) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        // Same over-release hazard as TerminalWindowController's window: ARC
        // owns this window, so it must not also release itself on close.
        window.isReleasedWhenClosed = false
        // The committed dark ground (Phase 15) — native controls already
        // render dark under the app-pinned .darkAqua appearance.
        window.backgroundColor = Theme.bg
        self.init(window: window)
        self.appDelegate = appDelegate
        buildUI()
    }

    func show() {
        if let appDelegate {
            updateFontLabel(appDelegate.currentFont)
            textColorWell.color = appDelegate.currentTextColor
            backgroundColorWell.color = appDelegate.defaultTerminalBackground
            opacitySlider.doubleValue = Double(appDelegate.backgroundAlpha)
            blurCheckbox.state = appDelegate.blurEnabled ? .on : .off
            shellField.stringValue = appDelegate.shellPath
            let (shape, blinking) = Self.components(of: appDelegate.cursorStyle)
            cursorShapePopup.selectItem(at: shape)
            cursorBlinkCheckbox.state = blinking ? .on : .off
            bellFlashCheckbox.state = appDelegate.bellFlashEnabled ? .on : .off
            bellBounceCheckbox.state = appDelegate.bellDockBounceEnabled ? .on : .off
            wordWrapCheckbox.state = appDelegate.wordWrapEnabled ? .on : .off
            claudeArgsField.stringValue = appDelegate.claudeSessionArgs
            goalProvenanceCheckbox.state = appDelegate.goalPrependProvenanceEnabled ? .on : .off
            autopilotEnabledCheckbox.state = appDelegate.autopilotEnabled ? .on : .off
            autopilotProjectField.stringValue = appDelegate.autopilotProjectRoot
            if let index = AutopilotBudgetMode.allCases.firstIndex(of: appDelegate.autopilotMode) {
                autopilotModePopup.selectItem(at: index)
            }
            autopilotNightStartStepper.intValue = appDelegate.autopilotNightStart
            autopilotNightEndStepper.intValue = appDelegate.autopilotNightEnd
            autopilotFiveHourStepper.intValue = appDelegate.autopilotFiveHourCeiling
            autopilotWeeklyStepper.intValue = appDelegate.autopilotWeeklyCeiling
            autopilotHardStopStepper.intValue = appDelegate.autopilotWeeklyHardStop
            autopilotPaceStepper.intValue = appDelegate.autopilotPaceTargetPct
            autopilotAttemptsStepper.intValue = appDelegate.autopilotMaxGateAttempts
            autopilotStallStepper.intValue = appDelegate.autopilotStallMinutes
            autopilotExtraArgsField.stringValue = appDelegate.autopilotExtraArgs
            autopilotReviewModelField.stringValue = appDelegate.autopilotReviewModel
            autopilotKeepAwakeCheckbox.state = appDelegate.autopilotPreventSleep ? .on : .off
            updateAutopilotNightEnabled()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateFontLabel(_ font: NSFont) {
        fontLabel.stringValue = font.displayName ?? font.fontName
        fontSizeLabel.stringValue = "\(Int(font.pointSize))pt"
        fontSizeStepper.doubleValue = Double(font.pointSize)
    }
}
