import Cocoa

// Cmd-, settings window: a macOS System-Settings-style layout — a category
// sidebar on the left, one category's form on the right. Categories are
// Appearance (font, default font size, text color, default pane background,
// opacity, blur), Terminal (shell, cursor, bell responses), File Viewer (word
// wrap), Claude (default session arguments + task/goal/token toggles),
// Autopilot (ROADMAP autonomy budget), Budget (cost guardrails), and Shortcuts
// (a read-only keyboard reference built from KeyboardShortcuts.groups — the
// single source of truth README.md and AppDelegate's menu mirror). Only the
// selected category is shown, so no single scroll dumps every setting at once.
//
// Each pane is a plain vertical NSStackView form built with Auto Layout — safe
// here since, unlike the pane/split tree, this window's view hierarchy is never
// touched by NSSplitView's own frame management. Selecting a sidebar row swaps
// the detail scroll's document view.
//
// Every control writes straight through to AppDelegate (which applies it to
// all windows and persists); show() re-reads all state, so values changed
// elsewhere (⇧⌘B blur, ⇧⌘= font size, the palette) are fresh each time the
// window opens.
//
// The sidebar + per-category pane builders live in
// SettingsWindowController+Sections.swift and the control-action handlers in
// SettingsWindowController+Actions.swift; stored properties (which Swift forbids
// in extensions) stay here in the primary declaration.
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate,
                                      NSTableViewDataSource, NSTableViewDelegate {
    weak var appDelegate: AppDelegate?

    // The category sidebar (left) and the detail scroll (right) whose document
    // view swaps to the selected category's pane. Built in buildUI(); panes are
    // built once and cached in `panels`, index-aligned with `Self.categories`.
    let sidebarTable = NSTableView()
    let detailScroll = NSScrollView()
    var panels: [NSView] = []
    // The width pin tying the current document view to the clip view, replaced
    // on each selection so only vertical scrolling happens in the detail area.
    var detailWidthConstraint: NSLayoutConstraint?

    // Sidebar categories: title + SF Symbol. Order is the display order; the
    // index maps 1:1 to `panels`.
    static let categories: [(title: String, symbol: String)] = [
        ("Appearance", "paintbrush"),
        ("Terminal", "terminal"),
        ("File Viewer", "doc.text"),
        ("Claude", "sparkles"),
        ("Autopilot", "airplane"),
        ("Budget", "dollarsign.circle"),
        ("Themes", "swatchpalette"),
        ("Shortcuts", "keyboard"),
    ]

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
    let taskDoneSoundCheckbox = NSButton(checkboxWithTitle: "Play a sound when a task finishes", target: nil, action: nil)
    let taskDoneSoundPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let needsInputSoundCheckbox = NSButton(checkboxWithTitle: "Play a sound when Claude has a question", target: nil, action: nil)
    let needsInputSoundPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let soundPreviewPlayer = NotificationSoundPlayer()
    let taskIsolateCheckbox = NSButton(checkboxWithTitle: "Isolate new tasks in a worktree by default", target: nil, action: nil)
    let goalProvenanceCheckbox = NSButton(checkboxWithTitle: "Prepend source location to goals (From file:lines:)", target: nil, action: nil)
    let rtkCompressionCheckbox = NSButton(checkboxWithTitle: "Compress tool output with rtk", target: nil, action: nil)

    // Autopilot: every control writes through
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

    // Cost budget guardrails: per-session / per-task dollar
    // ceilings (blank / 0 = no cap) and the opt-in auto-interrupt. The fields
    // commit on Enter/focus-loss through controlTextDidEndEditing.
    let budgetSessionCapField = NSTextField(string: "")
    let budgetTaskCapField = NSTextField(string: "")
    let budgetAutoInterruptCheckbox = NSButton(checkboxWithTitle: "Interrupt the run (Esc) when a cap is crossed", target: nil, action: nil)

    // Themes: a selectable catalog (built-ins + user themes, active one checked)
    // driving ThemeStore, plus a color-well editor for the selected user theme.
    // `themeRows` is the snapshot the table renders (stable across a selection
    // cycle); `themeColorWells` is index-aligned with Theme.Palette.editableTokens
    // and `themeEditingPalette` is the working copy edits mutate before ThemeStore
    // persists them. `themeObserverToken` refreshes the list on ThemeStore.didUpdate.
    let themeTable = NSTableView()
    var themeRows: [ThemeStore.ThemeInfo] = []
    var themeColorWells: [NSColorWell] = []
    let themePreviewStrip = ThemePreviewStrip()
    var themeEditingPalette: Theme.Palette?
    var themeObserverToken: NSObjectProtocol?
    // Coalesces continuous NSColorWell fires: a drag scrubs through dozens of
    // colors per second, but the working palette is only persisted (disk write +
    // catalog reload + app-wide re-skin) on the trailing edge so one hue drag is
    // one write, not a hundred. The preview strip updates live meanwhile.
    var themeCommitWork: DispatchWorkItem?
    let themeApplyButton     = NSButton(title: "Apply",     target: nil, action: nil)
    let themeDuplicateButton = NSButton(title: "Duplicate", target: nil, action: nil)
    let themeEditButton      = NSButton(title: "Edit",      target: nil, action: nil)
    let themeImportButton    = NSButton(title: "Import…",   target: nil, action: nil)
    let themeExportButton    = NSButton(title: "Export…",   target: nil, action: nil)
    let themeDeleteButton    = NSButton(title: "Delete",    target: nil, action: nil)
    let themeEditHint = NSTextField(labelWithString: "")

    convenience init(appDelegate: AppDelegate) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        // Same over-release hazard as TerminalWindowController's window: ARC
        // owns this window, so it must not also release itself on close.
        window.isReleasedWhenClosed = false
        // The committed dark ground — native controls already
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
            taskDoneSoundCheckbox.state = appDelegate.taskDoneSoundEnabled ? .on : .off
            needsInputSoundCheckbox.state = appDelegate.needsInputSoundEnabled ? .on : .off
            taskDoneSoundPopup.selectItem(withTitle: appDelegate.taskDoneSoundName)
            needsInputSoundPopup.selectItem(withTitle: appDelegate.needsInputSoundName)
            taskIsolateCheckbox.state = appDelegate.taskIsolateByDefault ? .on : .off
            goalProvenanceCheckbox.state = appDelegate.goalPrependProvenanceEnabled ? .on : .off
            rtkCompressionCheckbox.state = appDelegate.rtkCompressionEnabled ? .on : .off
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
            budgetSessionCapField.stringValue = Self.dollarString(appDelegate.budgetSessionCap)
            budgetTaskCapField.stringValue = Self.dollarString(appDelegate.budgetTaskCap)
            budgetAutoInterruptCheckbox.state = appDelegate.budgetAutoInterrupt ? .on : .off
            updateAutopilotNightEnabled()
        }
        reloadThemes()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // A dollar cap for a text field: blank when off (≤ 0), else "%.2f".
    static func dollarString(_ value: Double) -> String {
        value > 0 ? String(format: "%.2f", value) : ""
    }

    func updateFontLabel(_ font: NSFont) {
        fontLabel.stringValue = font.displayName ?? font.fontName
        fontSizeLabel.stringValue = "\(Int(font.pointSize))pt"
        fontSizeStepper.doubleValue = Double(font.pointSize)
    }
}
