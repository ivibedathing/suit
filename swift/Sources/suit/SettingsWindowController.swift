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
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private weak var appDelegate: AppDelegate?

    private let fontLabel = NSTextField(labelWithString: "")
    private let fontSizeLabel = NSTextField(labelWithString: "")
    private let fontSizeStepper = NSStepper(frame: NSRect(x: 0, y: 0, width: 19, height: 27))
    private let textColorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
    private let backgroundColorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
    private let opacitySlider = NSSlider(value: 1, minValue: 0.3, maxValue: 1, target: nil, action: nil)
    private let blurCheckbox = NSButton(checkboxWithTitle: "Background Blur", target: nil, action: nil)

    private let shellField = NSTextField(string: "")
    private let cursorShapePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cursorBlinkCheckbox = NSButton(checkboxWithTitle: "Blinking", target: nil, action: nil)
    private let bellFlashCheckbox = NSButton(checkboxWithTitle: "Flash pane on bell", target: nil, action: nil)
    private let bellBounceCheckbox = NSButton(checkboxWithTitle: "Bounce Dock icon on bell when inactive", target: nil, action: nil)

    private let wordWrapCheckbox = NSButton(checkboxWithTitle: "Word wrap long lines", target: nil, action: nil)

    private let claudeArgsField = NSTextField(string: "")
    private let goalProvenanceCheckbox = NSButton(checkboxWithTitle: "Prepend source location to goals (From file:lines:)", target: nil, action: nil)

    // Autopilot (ROADMAP Phase 32, §2.9): every control writes through
    // appDelegate.autopilotXChanged(...) and is re-read in show().
    private let autopilotEnabledCheckbox = NSButton(checkboxWithTitle: "Work through ROADMAP.md autonomously", target: nil, action: nil)
    private let autopilotProjectField = NSTextField(string: "")
    private let autopilotModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let autopilotNightStartStepper = LabeledStepper(min: 0, max: 23, suffix: "h")
    private let autopilotNightEndStepper = LabeledStepper(min: 0, max: 23, suffix: "h")
    private let autopilotFiveHourStepper = LabeledStepper(min: 0, max: 100, suffix: "%")
    private let autopilotWeeklyStepper = LabeledStepper(min: 0, max: 100, suffix: "%")
    private let autopilotHardStopStepper = LabeledStepper(min: 0, max: 100, suffix: "%")
    private let autopilotPaceStepper = LabeledStepper(min: 1, max: 100, suffix: "%")
    private let autopilotAttemptsStepper = LabeledStepper(min: 1, max: 9, suffix: "")
    private let autopilotStallStepper = LabeledStepper(min: 5, max: 240, suffix: " min")
    private let autopilotExtraArgsField = NSTextField(string: "")
    private let autopilotReviewModelField = NSTextField(string: "")
    private let autopilotKeepAwakeCheckbox = NSButton(checkboxWithTitle: "Keep the Mac awake during runs", target: nil, action: nil)

    // A stepper with its value label, the fontSizeStepper pattern factored out
    // for the Autopilot section's many numeric settings.
    private final class LabeledStepper {
        let valueLabel = NSTextField(labelWithString: "")
        let stepper = NSStepper(frame: NSRect(x: 0, y: 0, width: 19, height: 27))
        private let suffix: String

        init(min: Double, max: Double, suffix: String) {
            self.suffix = suffix
            stepper.minValue = min
            stepper.maxValue = max
            stepper.increment = 1
            valueLabel.font = .systemFont(ofSize: 12)
            valueLabel.textColor = Theme.textPrimary
        }

        var intValue: Int {
            get { Int(stepper.doubleValue) }
            set {
                stepper.doubleValue = Double(newValue)
                refreshLabel()
            }
        }

        func refreshLabel() {
            valueLabel.stringValue = "\(Int(stepper.doubleValue))\(suffix)"
        }

        var isEnabled: Bool {
            get { stepper.isEnabled }
            set {
                stepper.isEnabled = newValue
                valueLabel.textColor = newValue ? Theme.textPrimary : Theme.textFaint
            }
        }

        var views: [NSView] { [valueLabel, stepper] }
    }

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

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false

        let settingsItem = NSTabViewItem(identifier: "settings")
        settingsItem.label = "Settings"
        settingsItem.view = buildSettingsForm()
        tabView.addTabViewItem(settingsItem)

        let docsItem = NSTabViewItem(identifier: "docs")
        docsItem.label = "Shortcuts"
        docsItem.view = buildDocsView()
        tabView.addTabViewItem(docsItem)

        contentView.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    private func buildSettingsForm() -> NSView {
        for value in [fontLabel, fontSizeLabel] {
            value.font = .systemFont(ofSize: 12)
            value.textColor = Theme.textPrimary
        }

        // Appearance
        let chooseFontButton = NSButton(title: "Choose…", target: self, action: #selector(chooseFont))
        let fontRow = row(label: "Font:", controls: [fontLabel, chooseFontButton])

        fontSizeStepper.minValue = 8
        fontSizeStepper.maxValue = 36
        fontSizeStepper.increment = 1
        fontSizeStepper.target = self
        fontSizeStepper.action = #selector(fontSizeChanged)
        let fontSizeRow = row(label: "Font Size:", controls: [fontSizeLabel, fontSizeStepper])

        textColorWell.target = self
        textColorWell.action = #selector(textColorChanged)
        let textColorRow = row(label: "Text Color:", controls: [textColorWell])

        backgroundColorWell.target = self
        backgroundColorWell.action = #selector(backgroundColorChanged)
        let resetBackgroundButton = NSButton(title: "Reset", target: self, action: #selector(resetBackgroundColor))
        let backgroundRow = row(label: "Background:", controls: [backgroundColorWell, resetBackgroundButton])

        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged)
        opacitySlider.translatesAutoresizingMaskIntoConstraints = false
        opacitySlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let opacityRow = row(label: "Opacity:", controls: [opacitySlider])

        blurCheckbox.target = self
        blurCheckbox.action = #selector(blurChanged)
        let blurRow = row(label: "", controls: [blurCheckbox])

        // Terminal
        shellField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        shellField.placeholderString = "/bin/zsh"
        shellField.delegate = self
        shellField.translatesAutoresizingMaskIntoConstraints = false
        shellField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let shellRow = row(label: "Shell:", controls: [shellField])

        cursorShapePopup.addItems(withTitles: ["Block", "Underline", "Bar"])
        cursorShapePopup.target = self
        cursorShapePopup.action = #selector(cursorStyleChanged)
        cursorBlinkCheckbox.target = self
        cursorBlinkCheckbox.action = #selector(cursorStyleChanged)
        let cursorRow = row(label: "Cursor:", controls: [cursorShapePopup, cursorBlinkCheckbox])

        bellFlashCheckbox.target = self
        bellFlashCheckbox.action = #selector(bellFlashChanged)
        bellBounceCheckbox.target = self
        bellBounceCheckbox.action = #selector(bellBounceChanged)
        let bellFlashRow = row(label: "Bell:", controls: [bellFlashCheckbox])
        let bellBounceRow = row(label: "", controls: [bellBounceCheckbox])

        // Viewer
        wordWrapCheckbox.target = self
        wordWrapCheckbox.action = #selector(wordWrapChanged)
        let wordWrapRow = row(label: "", controls: [wordWrapCheckbox])

        // Claude: arguments the quick-access launchers (strip ✦, ⌃⌘C,
        // palette) append to `claude`.
        claudeArgsField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        claudeArgsField.placeholderString = "e.g. --continue or --model opus"
        claudeArgsField.delegate = self
        claudeArgsField.translatesAutoresizingMaskIntoConstraints = false
        claudeArgsField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let claudeArgsRow = row(label: "Arguments:", controls: [claudeArgsField])
        let claudeArgsHint = NSTextField(labelWithString: "Appended to “claude” when starting a session from the ✦ button.")
        claudeArgsHint.font = .systemFont(ofSize: 10)
        claudeArgsHint.textColor = Theme.textDim
        let claudeHintRow = row(label: "", controls: [claudeArgsHint])

        // Set as Goal (ROADMAP Phase 18): whether "Set as Goal" from a viewer
        // selection carries a `From <file>:<lines>:` line into the goal.
        goalProvenanceCheckbox.target = self
        goalProvenanceCheckbox.action = #selector(goalProvenanceChanged)
        let goalProvenanceRow = row(label: "Goals:", controls: [goalProvenanceCheckbox])

        // Autopilot (ROADMAP Phase 32, §2.9).
        autopilotEnabledCheckbox.target = self
        autopilotEnabledCheckbox.action = #selector(autopilotEnabledToggled)
        let autopilotEnabledRow = row(label: "", controls: [autopilotEnabledCheckbox])

        autopilotProjectField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        autopilotProjectField.placeholderString = "git repo containing ROADMAP.md"
        autopilotProjectField.delegate = self
        autopilotProjectField.translatesAutoresizingMaskIntoConstraints = false
        autopilotProjectField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let autopilotChooseButton = NSButton(title: "Choose…", target: self, action: #selector(autopilotChooseProject))
        let autopilotProjectRow = row(label: "Project:", controls: [autopilotProjectField, autopilotChooseButton])

        autopilotModePopup.addItems(withTitles: AutopilotBudgetMode.allCases.map(\.displayName))
        autopilotModePopup.target = self
        autopilotModePopup.action = #selector(autopilotModePicked)
        let autopilotModeRow = row(label: "Mode:", controls: [autopilotModePopup])

        let nightToLabel = NSTextField(labelWithString: "to")
        nightToLabel.font = .systemFont(ofSize: 12)
        nightToLabel.textColor = Theme.textDim
        let autopilotNightRow = row(
            label: "Night:",
            controls: autopilotNightStartStepper.views + [nightToLabel] + autopilotNightEndStepper.views
        )

        for labeled in autopilotSteppers {
            labeled.stepper.target = self
            labeled.stepper.action = #selector(autopilotStepperChanged)
        }
        let autopilotFiveHourRow = row(label: "5h Cap:", controls: autopilotFiveHourStepper.views)
        let autopilotWeeklyRow = row(label: "Weekly Cap:", controls: autopilotWeeklyStepper.views)
        let autopilotHardStopRow = row(label: "Hard Stop:", controls: autopilotHardStopStepper.views)
        let autopilotPaceRow = row(label: "Pace To:", controls: autopilotPaceStepper.views)
        let attemptsHint = NSTextField(labelWithString: "max attempts per phase")
        attemptsHint.font = .systemFont(ofSize: 10)
        attemptsHint.textColor = Theme.textDim
        let autopilotAttemptsRow = row(label: "Attempts:", controls: autopilotAttemptsStepper.views + [attemptsHint])
        let autopilotStallRow = row(label: "Stall:", controls: autopilotStallStepper.views)

        autopilotExtraArgsField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        autopilotExtraArgsField.delegate = self
        autopilotExtraArgsField.translatesAutoresizingMaskIntoConstraints = false
        autopilotExtraArgsField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let autopilotArgsRow = row(label: "Arguments:", controls: [autopilotExtraArgsField])
        let autopilotArgsHint = NSTextField(labelWithString: "Appended to claude for Autopilot runs (--dangerously-skip-permissions is always set)")
        autopilotArgsHint.font = .systemFont(ofSize: 10)
        autopilotArgsHint.textColor = Theme.textDim
        let autopilotArgsHintRow = row(label: "", controls: [autopilotArgsHint])

        autopilotReviewModelField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        autopilotReviewModelField.placeholderString = "empty = default model"
        autopilotReviewModelField.delegate = self
        autopilotReviewModelField.translatesAutoresizingMaskIntoConstraints = false
        autopilotReviewModelField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let autopilotReviewModelRow = row(label: "Reviewer:", controls: [autopilotReviewModelField])

        autopilotKeepAwakeCheckbox.target = self
        autopilotKeepAwakeCheckbox.action = #selector(autopilotKeepAwakeChanged)
        let autopilotKeepAwakeRow = row(label: "", controls: [autopilotKeepAwakeCheckbox])

        let stack = NSStackView(views: [
            sectionHeader("Appearance"),
            fontRow, fontSizeRow, textColorRow, backgroundRow, opacityRow, blurRow,
            sectionHeader("Terminal"),
            shellRow, cursorRow, bellFlashRow, bellBounceRow,
            sectionHeader("File Viewer"),
            wordWrapRow,
            sectionHeader("Claude"),
            claudeArgsRow, claudeHintRow, goalProvenanceRow,
            sectionHeader("Autopilot"),
            autopilotEnabledRow, autopilotProjectRow, autopilotModeRow, autopilotNightRow,
            autopilotFiveHourRow, autopilotWeeklyRow, autopilotHardStopRow, autopilotPaceRow,
            autopilotAttemptsRow, autopilotStallRow,
            autopilotArgsRow, autopilotArgsHintRow,
            autopilotReviewModelRow, autopilotKeepAwakeRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        // The bell rows read as one setting; keep them tight. Sections get
        // extra air before their headers.
        stack.setCustomSpacing(4, after: bellFlashRow)
        stack.setCustomSpacing(4, after: claudeArgsRow)
        stack.setCustomSpacing(4, after: autopilotArgsRow)
        stack.setCustomSpacing(22, after: blurRow)
        stack.setCustomSpacing(22, after: bellBounceRow)
        stack.setCustomSpacing(22, after: wordWrapRow)
        stack.setCustomSpacing(22, after: goalProvenanceRow)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The Autopilot section pushed the form past the window height, so the
        // whole tab scrolls (same FlippedView + width-pinned document pattern
        // as the Shortcuts tab).
        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -20),
        ])
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = documentView
        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    private var autopilotSteppers: [LabeledStepper] {
        [autopilotNightStartStepper, autopilotNightEndStepper, autopilotFiveHourStepper,
         autopilotWeeklyStepper, autopilotHardStopStepper, autopilotPaceStepper,
         autopilotAttemptsStepper, autopilotStallStepper]
    }

    // The Docs tab: a scrollable, read-only reference of every keyboard shortcut,
    // built from KeyboardShortcuts.groups (the single source of truth that
    // README.md and AppDelegate's menu mirror).
    private func buildDocsView() -> NSView {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.translatesAutoresizingMaskIntoConstraints = false
        content.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)

        for (index, group) in KeyboardShortcuts.groups.enumerated() {
            let header = sectionHeader(group.name)
            if index > 0 { content.setCustomSpacing(20, after: content.arrangedSubviews.last ?? header) }
            content.addArrangedSubview(header)
            content.setCustomSpacing(8, after: header)
            for entry in group.entries {
                content.addArrangedSubview(shortcutRow(keys: entry.keys, title: entry.title))
            }
            if let note = group.note {
                let noteLabel = NSTextField(labelWithString: note)
                noteLabel.font = .systemFont(ofSize: 11)
                noteLabel.textColor = Theme.textDim
                content.addArrangedSubview(noteLabel)
            }
        }

        // This scroll view is the tab item's top-level view; leave its
        // autoresizing intact so NSTabView sizes it to fill the content area.
        // (Disabling it would collapse the scroll view to zero height.)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: documentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
        scroll.documentView = documentView
        // Pin the document to the clip view's width so rows lay out full-width and
        // only vertical scrolling happens.
        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    // One shortcut row: a fixed-width monospaced "keycap" column on the left, the
    // action description on the right.
    private func shortcutRow(keys: String, title: String) -> NSView {
        let keysField = NSTextField(labelWithString: keys)
        keysField.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        keysField.textColor = Theme.textPrimary
        keysField.alignment = .left
        keysField.translatesAutoresizingMaskIntoConstraints = false
        keysField.widthAnchor.constraint(equalToConstant: 92).isActive = true
        keysField.setContentHuggingPriority(.required, for: .horizontal)

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 12)
        titleField.textColor = Theme.textDim

        let stack = NSStackView(views: [keysField, titleField])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 10
        return stack
    }

    // A top-anchored document view for the Docs scroll view, so content lays out
    // from the top and scrolls downward the usual way.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private func sectionHeader(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = Theme.textDim
        return label
    }

    private func row(label: String, controls: [NSView]) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.alignment = .right
        labelField.font = .systemFont(ofSize: 12)
        labelField.textColor = Theme.textDim
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let stack = NSStackView(views: [labelField] + controls)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    // MARK: - Cursor style <-> popup + checkbox

    private static func cursorStyle(shape: Int, blinking: Bool) -> CursorStyle {
        switch shape {
        case 1: return blinking ? .blinkUnderline : .steadyUnderline
        case 2: return blinking ? .blinkBar : .steadyBar
        default: return blinking ? .blinkBlock : .steadyBlock
        }
    }

    private static func components(of style: CursorStyle) -> (shape: Int, blinking: Bool) {
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

    @objc private func chooseFont(_ sender: Any?) {
        appDelegate?.beginChoosingFont()
    }

    @objc private func fontSizeChanged(_ sender: NSStepper) {
        appDelegate?.fontSizeChanged(CGFloat(sender.doubleValue))
    }

    @objc private func textColorChanged(_ sender: NSColorWell) {
        appDelegate?.textColorChanged(sender.color)
    }

    @objc private func backgroundColorChanged(_ sender: NSColorWell) {
        appDelegate?.defaultBackgroundChanged(sender.color)
    }

    @objc private func resetBackgroundColor(_ sender: Any?) {
        backgroundColorWell.color = Theme.terminalBg
        appDelegate?.defaultBackgroundChanged(Theme.terminalBg)
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        appDelegate?.opacityChanged(CGFloat(sender.doubleValue))
    }

    @objc private func blurChanged(_ sender: NSButton) {
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

    @objc private func cursorStyleChanged(_ sender: Any?) {
        appDelegate?.cursorStyleChanged(Self.cursorStyle(
            shape: cursorShapePopup.indexOfSelectedItem,
            blinking: cursorBlinkCheckbox.state == .on
        ))
    }

    @objc private func bellFlashChanged(_ sender: NSButton) {
        appDelegate?.bellFlashChanged(sender.state == .on)
    }

    @objc private func bellBounceChanged(_ sender: NSButton) {
        appDelegate?.bellDockBounceChanged(sender.state == .on)
    }

    @objc private func wordWrapChanged(_ sender: NSButton) {
        appDelegate?.wordWrapChanged(sender.state == .on)
    }

    @objc private func goalProvenanceChanged(_ sender: NSButton) {
        appDelegate?.goalProvenanceChanged(sender.state == .on)
    }

    // MARK: - Autopilot actions (ROADMAP Phase 32)

    // Enabling runs the §2.3 enable-time checks in AppDelegate (Claude
    // integration installed, gh hint); a refusal snaps the checkbox back.
    @objc private func autopilotEnabledToggled(_ sender: NSButton) {
        guard let appDelegate else { return }
        if !appDelegate.autopilotEnabledChanged(sender.state == .on) {
            sender.state = appDelegate.autopilotEnabled ? .on : .off
        }
    }

    @objc private func autopilotChooseProject(_ sender: Any?) {
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

    @objc private func autopilotModePicked(_ sender: Any?) {
        let modes = AutopilotBudgetMode.allCases
        let index = autopilotModePopup.indexOfSelectedItem
        guard modes.indices.contains(index) else { return }
        appDelegate?.autopilotModeChanged(modes[index])
        updateAutopilotNightEnabled()
    }

    // The night-hours steppers only matter in night mode.
    private func updateAutopilotNightEnabled() {
        let night = appDelegate?.autopilotMode == .nightShift
        autopilotNightStartStepper.isEnabled = night
        autopilotNightEndStepper.isEnabled = night
    }

    // One selector for all eight numeric settings, dispatched by identity;
    // the label re-reads the (clamped) value AppDelegate actually took.
    @objc private func autopilotStepperChanged(_ sender: NSStepper) {
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

    @objc private func autopilotKeepAwakeChanged(_ sender: NSButton) {
        appDelegate?.autopilotPreventSleepChanged(sender.state == .on)
    }
}
