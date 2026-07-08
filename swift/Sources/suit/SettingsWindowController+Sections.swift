import Cocoa

// The settings window's view construction: the two-tab NSTabView, the
// app-wide defaults form (Appearance / Terminal / File Viewer / Claude /
// Autopilot sections), and the read-only Shortcuts reference. Split out of
// SettingsWindowController.swift; the stored controls it wires up live there.
extension SettingsWindowController {
    func buildUI() {
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

        // New-task isolation default (ROADMAP Phase 31): whether the "New
        // Claude Task" prompt's "Isolate in worktree" switch starts on.
        taskIsolateCheckbox.target = self
        taskIsolateCheckbox.action = #selector(taskIsolateChanged)
        let taskIsolateRow = row(label: "New task:", controls: [taskIsolateCheckbox])

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
            claudeArgsRow, claudeHintRow, taskIsolateRow, goalProvenanceRow,
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

    var autopilotSteppers: [LabeledStepper] {
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
}
