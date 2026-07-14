import Cocoa

// The settings window's view construction: a category sidebar (left) driving a
// detail scroll (right) that shows one category's form at a time — Appearance /
// Terminal / File Viewer / Claude / Autopilot / Budget panes plus the read-only
// Shortcuts reference. Split out of SettingsWindowController.swift; the stored
// controls these builders wire up (and the `categories` list / `panels` cache)
// live there.
extension SettingsWindowController {
    func buildUI() {
        guard let contentView = window?.contentView else { return }

        // Build each category pane once, index-aligned with Self.categories.
        panels = [
            wrap(appearancePane()),
            wrap(terminalPane()),
            wrap(viewerPane()),
            wrap(claudePane()),
            wrap(claudeAPIPane()),
            wrap(autopilotPane()),
            wrap(budgetPane()),
            wrap(themesPane()),
            buildDocsView(),
        ]

        // Refresh the theme list/editor whenever the catalog or selection
        // changes anywhere (palette "Switch Theme", delete fallback, another
        // action), so the window never shows a stale active theme.
        themeObserverToken = NotificationCenter.default.addObserver(
            forName: ThemeStore.didUpdate, object: nil, queue: .main
        ) { [weak self] _ in self?.reloadThemes() }

        let sidebar = buildSidebar()

        let divider = NSBox()
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = Theme.hairline
        divider.translatesAutoresizingMaskIntoConstraints = false

        detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.automaticallyAdjustsContentInsets = false
        detailScroll.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)

        contentView.addSubview(sidebar)
        contentView.addSubview(divider)
        contentView.addSubview(detailScroll)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: contentView.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 184),

            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: contentView.topAnchor),
            divider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            detailScroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            detailScroll.topAnchor.constraint(equalTo: contentView.topAnchor),
            detailScroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            detailScroll.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        // Open on the first category.
        sidebarTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        showPanel(0)
    }

    // The category list: an icon + label per row, source-list styling, amber
    // selection (ThemedTableRowView, matching the app's sidebar rail lists).
    private func buildSidebar() -> NSView {
        sidebarTable.headerView = nil
        sidebarTable.backgroundColor = Theme.barChrome
        sidebarTable.rowHeight = 30
        sidebarTable.intercellSpacing = NSSize(width: 0, height: 2)
        sidebarTable.selectionHighlightStyle = .regular
        sidebarTable.style = .sourceList
        sidebarTable.dataSource = self
        sidebarTable.delegate = self
        sidebarTable.focusRingType = .none

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("category"))
        column.resizingMask = .autoresizingMask
        sidebarTable.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.barChrome
        scroll.documentView = sidebarTable
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        return scroll
    }

    // Swap the detail scroll to the selected category's pane, re-pinning its
    // width to the clip view so only vertical scrolling happens.
    func showPanel(_ index: Int) {
        guard panels.indices.contains(index) else { return }
        let panel = panels[index]
        detailWidthConstraint?.isActive = false
        detailScroll.documentView = panel
        panel.translatesAutoresizingMaskIntoConstraints = false
        let width = panel.widthAnchor.constraint(equalTo: detailScroll.contentView.widthAnchor)
        width.isActive = true
        detailWidthConstraint = width
        detailScroll.documentView?.scroll(NSPoint(x: 0, y: 0))
    }

    // MARK: - NSTableView data source / delegate (sidebar)

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === themeTable ? themeRows.count : Self.categories.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ThemedTableRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === themeTable { return themeCell(row: row) }
        let (title, symbol) = Self.categories[row]
        let id = NSUserInterfaceItemIdentifier("categoryCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id

            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyDown
            icon.contentTintColor = Theme.textDim
            c.imageView = icon

            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 13)
            label.textColor = Theme.textPrimary
            label.translatesAutoresizingMaskIntoConstraints = false
            c.textField = label

            c.addSubview(icon)
            c.addSubview(label)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 14),
                icon.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 17),
                icon.heightAnchor.constraint(equalToConstant: 17),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
                label.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = title
        cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if (notification.object as? NSTableView) === themeTable {
            themeSelectionChanged()
            return
        }
        let row = sidebarTable.selectedRow
        if row >= 0 { showPanel(row) }
    }

    // MARK: - Category panes

    // Wrap a form stack in a flipped document view with a consistent inset, so
    // every pane lays out top-down inside the shared detail scroll.
    private func wrap(_ stack: NSStackView) -> NSView {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -28),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
        ])
        return document
    }

    // Appearance: font, size, colors, opacity, blur.
    private func appearancePane() -> NSStackView {
        for value in [fontLabel, fontSizeLabel] {
            value.font = .systemFont(ofSize: 12)
            value.textColor = Theme.textPrimary
        }

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

        blurRadiusSlider.target = self
        blurRadiusSlider.action = #selector(blurRadiusChanged)
        blurRadiusSlider.translatesAutoresizingMaskIntoConstraints = false
        blurRadiusSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let blurAmountRow = row(label: "Blur:", controls: [blurRadiusSlider])

        blurCheckbox.target = self
        blurCheckbox.action = #selector(blurChanged)
        let blurRow = row(label: "", controls: [blurCheckbox])

        return NSStackView(views: [
            paneTitle("Appearance"),
            fontRow, fontSizeRow, textColorRow, backgroundRow, opacityRow, blurAmountRow, blurRow,
        ])
    }

    // Terminal: shell, cursor, bell responses.
    private func terminalPane() -> NSStackView {
        shellField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        shellField.placeholderString = "/bin/zsh"
        shellField.delegate = self
        shellField.translatesAutoresizingMaskIntoConstraints = false
        shellField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let shellRow = row(label: "Shell:", controls: [shellField])

        cursorShapePopup.removeAllItems()
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

        let stack = NSStackView(views: [
            paneTitle("Terminal"),
            shellRow, cursorRow, bellFlashRow, bellBounceRow,
        ])
        stack.setCustomSpacing(4, after: bellFlashRow)
        return stack
    }

    // File Viewer: word wrap.
    private func viewerPane() -> NSStackView {
        wordWrapCheckbox.target = self
        wordWrapCheckbox.action = #selector(wordWrapChanged)
        let wordWrapRow = row(label: "", controls: [wordWrapCheckbox])

        return NSStackView(views: [
            paneTitle("File Viewer"),
            wordWrapRow,
        ])
    }

    // Claude: launcher arguments + task / goal / token toggles.
    private func claudePane() -> NSStackView {
        // Arguments the quick-access launchers (strip ✦, ⌃⌘C, palette) append.
        claudeArgsField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        claudeArgsField.placeholderString = "e.g. --continue or --model opus"
        claudeArgsField.delegate = self
        claudeArgsField.translatesAutoresizingMaskIntoConstraints = false
        claudeArgsField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let claudeArgsRow = row(label: "Arguments:", controls: [claudeArgsField])
        let claudeHintRow = hintRow("Appended to “claude” when starting a session from the ✦ button.")

        // New-task isolation default.
        taskIsolateCheckbox.target = self
        taskIsolateCheckbox.action = #selector(taskIsolateChanged)
        let taskIsolateRow = row(label: "New task:", controls: [taskIsolateCheckbox])

        // Set as Goal provenance.
        goalProvenanceCheckbox.target = self
        goalProvenanceCheckbox.action = #selector(goalProvenanceChanged)
        let goalProvenanceRow = row(label: "Goals:", controls: [goalProvenanceCheckbox])

        // rtk output compression: install/remove the PreToolUse hook.
        rtkCompressionCheckbox.target = self
        rtkCompressionCheckbox.action = #selector(rtkCompressionChanged)
        let rtkCompressionRow = row(label: "Tokens:", controls: [rtkCompressionCheckbox])
        let rtkHintRow = hintRow(
            "Filters shell-command output through rtk to cut context tokens. Requires rtk on your PATH; commands run unchanged when it's missing.",
            width: 340
        )

        // PostToolUse output compression: install/remove the dispatcher hook.
        postToolCompressCheckbox.target = self
        postToolCompressCheckbox.action = #selector(postToolCompressChanged)
        let postToolCompressRow = row(label: "", controls: [postToolCompressCheckbox])
        let postToolHintRow = hintRow(
            "Elides tool results over ~30k characters (head + tail + a how-to-narrow marker) before they reach the context window — the built-in tools rtk can't wrap. Requires Claude Code ≥ 2.1.133 and jq; results pass through unchanged on any error.",
            width: 340
        )

        // Read-dedup: same dispatcher hook, --dedup behavior.
        readDedupCheckbox.target = self
        readDedupCheckbox.action = #selector(readDedupChanged)
        let readDedupRow = row(label: "", controls: [readDedupCheckbox])
        let readDedupHintRow = hintRow(
            "A repeat full read of a file that hasn't changed returns a one-line stub instead of the whole file — its content is already in the conversation. Edited files always re-read fully, offset/limit reads are untouched, a second consecutive re-read forces the full file, and every compaction clears the memory.",
            width: 340
        )

        // Token-ignore firewall: the PreToolUse Read hook + the dispatcher's
        // --ignore flag, wired together by one toggle.
        tokenIgnoreCheckbox.target = self
        tokenIgnoreCheckbox.action = #selector(tokenIgnoreChanged)
        let tokenIgnoreRow = row(label: "", controls: [tokenIgnoreCheckbox])
        let tokenIgnoreHintRow = hintRow(
            "Repos listing heavy paths (vendored deps, build output) in .claude/token-ignore get full-file Reads there denied and Grep/Glob results there hidden behind a count marker. Range reads and searches that target the path explicitly always pass.",
            width: 340
        )

        // Shell helpers: the ZDOTDIR shim + run_silent, new zsh terminals only.
        shellExtrasCheckbox.target = self
        shellExtrasCheckbox.action = #selector(shellExtrasChanged)
        let shellExtrasRow = row(label: "", controls: [shellExtrasCheckbox])
        let shellExtrasHintRow = hintRow(
            "Defines run_silent (prints ✓ on success, full output only on failure — cheap builds/tests in Claude sessions) by launching new zsh terminals through a shim that sources your own config first. Never edits your dotfiles; see ~/.suit/scripts/SUIT-SHELL-EXTRAS.md for a CLAUDE.md snippet that tells Claude to use it.",
            width: 340
        )

        // Auto-/compact guardrails: threshold stepper + focus instructions.
        autoCompactCheckbox.target = self
        autoCompactCheckbox.action = #selector(autoCompactEnabledChanged)
        let autoCompactRow = row(
            label: "Compact:",
            controls: [autoCompactCheckbox] + autoCompactThresholdStepper.views
        )
        autoCompactThresholdStepper.stepper.target = self
        autoCompactThresholdStepper.stepper.action = #selector(autoCompactThresholdChanged)
        autoCompactInstructionsField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        autoCompactInstructionsField.placeholderString = "focus instructions — empty = plain /compact"
        autoCompactInstructionsField.delegate = self
        autoCompactInstructionsField.translatesAutoresizingMaskIntoConstraints = false
        autoCompactInstructionsField.widthAnchor.constraint(equalToConstant: 340).isActive = true
        let autoCompactInstructionsRow = row(label: "", controls: [autoCompactInstructionsField])
        let autoCompactHintRow = hintRow(
            "Types /compact with these instructions into a session that idles past the threshold — earlier and more focused than Claude Code's own auto-compact. Fires only at an idle prompt, once per crossing.",
            width: 340
        )

        // Notification sounds: play a system sound when a session finishes a
        // task or asks a question while Suit is in the background. Each event
        // has its own on/off and sound choice; picking a sound previews it.
        let soundTitles = availableSystemSounds()

        taskDoneSoundCheckbox.target = self
        taskDoneSoundCheckbox.action = #selector(taskDoneSoundEnabledChanged)
        taskDoneSoundPopup.removeAllItems()
        taskDoneSoundPopup.addItems(withTitles: soundTitles)
        taskDoneSoundPopup.target = self
        taskDoneSoundPopup.action = #selector(taskDoneSoundChanged)
        let taskDoneSoundRow = row(label: "Sounds:", controls: [taskDoneSoundCheckbox, taskDoneSoundPopup])

        needsInputSoundCheckbox.target = self
        needsInputSoundCheckbox.action = #selector(needsInputSoundEnabledChanged)
        needsInputSoundPopup.removeAllItems()
        needsInputSoundPopup.addItems(withTitles: soundTitles)
        needsInputSoundPopup.target = self
        needsInputSoundPopup.action = #selector(needsInputSoundChanged)
        let needsInputSoundRow = row(label: "", controls: [needsInputSoundCheckbox, needsInputSoundPopup])

        let stack = NSStackView(views: [
            paneTitle("Claude"),
            claudeArgsRow, claudeHintRow, taskIsolateRow, goalProvenanceRow,
            rtkCompressionRow, rtkHintRow,
            postToolCompressRow, postToolHintRow,
            readDedupRow, readDedupHintRow,
            tokenIgnoreRow, tokenIgnoreHintRow,
            shellExtrasRow, shellExtrasHintRow,
            autoCompactRow, autoCompactInstructionsRow, autoCompactHintRow,
            taskDoneSoundRow, needsInputSoundRow,
        ])
        stack.setCustomSpacing(4, after: claudeArgsRow)
        stack.setCustomSpacing(4, after: rtkCompressionRow)
        stack.setCustomSpacing(4, after: autoCompactRow)
        stack.setCustomSpacing(4, after: autoCompactInstructionsRow)
        stack.setCustomSpacing(4, after: taskDoneSoundRow)
        return stack
    }

    // Claude API: per-launch Anthropic env overrides (model, effort, thinking
    // budget, output cap, prompt caching, custom headers, free-form env) that
    // ClaudeAPISettings composes onto the typed `claude` command. A live
    // preview at the bottom shows exactly what will be typed, so the pane is
    // a playground with visible output rather than hidden state.
    private func claudeAPIPane() -> NSStackView {
        for field in [apiModelField, apiSubagentModelField, apiCustomHeadersField, apiExtraEnvField] {
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        apiModelField.placeholderString = "default — e.g. opus, sonnet, haiku"
        apiSubagentModelField.placeholderString = "default — e.g. haiku, or inherit"
        apiCustomHeadersField.placeholderString = "e.g. anthropic-beta: fast-mode-2026-02-01"
        apiExtraEnvField.placeholderString = "KEY=VALUE KEY2=VALUE2"

        let modelRow = row(label: "Model:", controls: [apiModelField])
        let subagentRow = row(label: "Subagents:", controls: [apiSubagentModelField])

        apiEffortPopup.removeAllItems()
        apiEffortPopup.addItems(withTitles: ["Default"] + ClaudeAPISettings.effortLevels)
        apiEffortPopup.target = self
        apiEffortPopup.action = #selector(apiEffortPicked)
        let effortRow = row(label: "Effort:", controls: [apiEffortPopup])
        let effortHintRow = hintRow(
            "Reasoning depth vs. token spend. low/medium suit routine work; xhigh is Claude Code's coding default; max spends the most.",
            width: 340
        )

        for field in [apiThinkingTokensField, apiMaxOutputTokensField] {
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.placeholderString = "default"
            field.delegate = self
            field.alignment = .right
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 80).isActive = true
        }
        let thinkingSuffix = NSTextField(labelWithString: "tokens")
        thinkingSuffix.font = .systemFont(ofSize: 11)
        thinkingSuffix.textColor = Theme.textDim
        let outputSuffix = NSTextField(labelWithString: "tokens")
        outputSuffix.font = .systemFont(ofSize: 11)
        outputSuffix.textColor = Theme.textDim
        let thinkingRow = row(label: "Thinking:", controls: [apiThinkingTokensField, thinkingSuffix])
        let outputRow = row(label: "Max Output:", controls: [apiMaxOutputTokensField, outputSuffix])

        apiPromptCachingCheckbox.target = self
        apiPromptCachingCheckbox.action = #selector(apiPromptCachingChanged)
        let cachingRow = row(label: "Caching:", controls: [apiPromptCachingCheckbox])
        let cachingHintRow = hintRow(
            "Prompt caching serves the repeated prompt prefix at ~10% of the input price. Leave it on outside experiments.",
            width: 340
        )

        let headersRow = row(label: "Headers:", controls: [apiCustomHeadersField])
        let extraEnvRow = row(label: "Extra Env:", controls: [apiExtraEnvField])
        let extraEnvHintRow = hintRow(
            "Space-separated KEY=VALUE pairs appended last, so they can override the knobs above or set variables this pane doesn't cover.",
            width: 340
        )

        apiPreviewLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        apiPreviewLabel.textColor = Theme.textDim
        apiPreviewLabel.lineBreakMode = .byWordWrapping
        apiPreviewLabel.maximumNumberOfLines = 0
        apiPreviewLabel.preferredMaxLayoutWidth = 340
        let previewRow = row(label: "Launch as:", controls: [apiPreviewLabel])
        let previewHintRow = hintRow(
            "Applies to Claude sessions started from Suit (✦, tasks, recipes, review passes) — each variable lasts for that session only. Autopilot runs are unaffected.",
            width: 340
        )

        let stack = NSStackView(views: [
            paneTitle("Claude API"),
            modelRow, subagentRow, effortRow, effortHintRow,
            thinkingRow, outputRow,
            cachingRow, cachingHintRow,
            headersRow, extraEnvRow, extraEnvHintRow,
            previewRow, previewHintRow,
        ])
        stack.setCustomSpacing(4, after: effortRow)
        stack.setCustomSpacing(4, after: cachingRow)
        stack.setCustomSpacing(4, after: extraEnvRow)
        stack.setCustomSpacing(4, after: previewRow)
        return stack
    }

    // Autopilot: ROADMAP autonomy + budget pacing.
    private func autopilotPane() -> NSStackView {
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

        autopilotModePopup.removeAllItems()
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
        let autopilotArgsHintRow = hintRow("Appended to claude for Autopilot runs (--dangerously-skip-permissions is always set)")

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
            paneTitle("Autopilot"),
            autopilotEnabledRow, autopilotProjectRow, autopilotModeRow, autopilotNightRow,
            autopilotFiveHourRow, autopilotWeeklyRow, autopilotHardStopRow, autopilotPaceRow,
            autopilotAttemptsRow, autopilotStallRow,
            autopilotArgsRow, autopilotArgsHintRow,
            autopilotReviewModelRow, autopilotKeepAwakeRow,
        ])
        stack.setCustomSpacing(4, after: autopilotArgsRow)
        return stack
    }

    // Budget: per-session / per-task dollar caps + interrupt.
    private func budgetPane() -> NSStackView {
        for field in [budgetSessionCapField, budgetTaskCapField] {
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.placeholderString = "off"
            field.delegate = self
            field.alignment = .right
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 80).isActive = true
        }
        let budgetSessionDollar = NSTextField(labelWithString: "$")
        budgetSessionDollar.textColor = Theme.textDim
        let budgetTaskDollar = NSTextField(labelWithString: "$")
        budgetTaskDollar.textColor = Theme.textDim
        let budgetSessionCapRow = row(label: "Session Cap:", controls: [budgetSessionDollar, budgetSessionCapField])
        let budgetTaskCapRow = row(label: "Task Cap:", controls: [budgetTaskDollar, budgetTaskCapField])
        budgetAutoInterruptCheckbox.target = self
        budgetAutoInterruptCheckbox.action = #selector(budgetAutoInterruptChanged)
        let budgetAutoInterruptRow = row(label: "On Trip:", controls: [budgetAutoInterruptCheckbox])
        let budgetHintRow = hintRow(
            "Warns when a session or task’s spend crosses its cap; interrupts too when checked. Set a per-session override with Set Budget… on a fleet row.",
            width: 340
        )

        return NSStackView(views: [
            paneTitle("Budget"),
            budgetSessionCapRow, budgetTaskCapRow, budgetAutoInterruptRow, budgetHintRow,
        ])
    }

    // Themes: a catalog list (built-ins + user themes, active one checked) with
    // Apply / Duplicate / Edit / Import / Export / Delete, and — for the selected
    // user theme — a color well per palette token above a live preview strip.
    // Built-ins are read-only; Edit duplicates them into an editable copy. Every
    // action drives ThemeStore, so Apply / token edits live-apply via Theme.didChange.
    private func themesPane() -> NSStackView {
        themeTable.headerView = nil
        themeTable.backgroundColor = Theme.barChrome
        themeTable.rowHeight = 24
        themeTable.intercellSpacing = NSSize(width: 0, height: 2)
        themeTable.selectionHighlightStyle = .regular
        themeTable.style = .sourceList
        themeTable.dataSource = self
        themeTable.delegate = self
        themeTable.focusRingType = .none
        themeTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("theme")))

        let listScroll = NSScrollView()
        listScroll.documentView = themeTable
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = true
        listScroll.backgroundColor = Theme.barChrome
        listScroll.borderType = .lineBorder
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        listScroll.heightAnchor.constraint(equalToConstant: 148).isActive = true
        listScroll.widthAnchor.constraint(equalToConstant: 240).isActive = true

        // A drop target so a shared ".suittheme" dragged in imports like the
        // Import… picker; it wraps the list so the whole area accepts the drop.
        let dropView = ThemeDropView()
        dropView.translatesAutoresizingMaskIntoConstraints = false
        dropView.addSubview(listScroll)
        NSLayoutConstraint.activate([
            listScroll.topAnchor.constraint(equalTo: dropView.topAnchor),
            listScroll.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: dropView.bottomAnchor),
        ])
        dropView.onDrop = { urls in
            for url in urls { ThemeStore.shared.importTheme(from: url) }
        }
        let listRow = row(label: "Themes:", controls: [dropView])

        for (button, sel) in [
            (themeApplyButton,     #selector(themeApply)),
            (themeDuplicateButton, #selector(themeDuplicate)),
            (themeEditButton,      #selector(themeEdit)),
            (themeImportButton,    #selector(themeImport)),
            (themeExportButton,    #selector(themeExport)),
            (themeDeleteButton,    #selector(themeDelete)),
        ] {
            button.target = self
            button.action = sel
        }
        let buttonRow = row(label: "", controls: [
            themeApplyButton, themeDuplicateButton, themeEditButton,
            themeImportButton, themeExportButton, themeDeleteButton,
        ])

        let stack = NSStackView(views: [
            paneTitle("Themes"),
            listRow, buttonRow,
        ])

        // Editable colors for the selected user theme. Built once (one well per
        // token, index-aligned with editableTokens); themeSelectionChanged()
        // repopulates and enables/disables them per selection.
        stack.addArrangedSubview(sectionHeader("Colors"))
        themeEditHint.font = .systemFont(ofSize: 10)
        themeEditHint.textColor = Theme.textDim
        stack.addArrangedSubview(row(label: "", controls: [themeEditHint]))

        themeColorWells = []
        // Lay the ~15 token wells out in two columns so the pane stays compact.
        let tokens = Theme.Palette.editableTokens
        var i = 0
        while i < tokens.count {
            let left = tokenWellControl(label: tokens[i].label)
            var controls: [NSView] = left
            if i + 1 < tokens.count {
                controls += tokenWellControl(label: tokens[i + 1].label)
            }
            stack.addArrangedSubview(row(label: "", controls: controls))
            i += 2
        }

        themePreviewStrip.translatesAutoresizingMaskIntoConstraints = false
        themePreviewStrip.heightAnchor.constraint(equalToConstant: 22).isActive = true
        themePreviewStrip.widthAnchor.constraint(equalToConstant: 300).isActive = true
        stack.addArrangedSubview(row(label: "Preview:", controls: [themePreviewStrip]))
        return stack
    }

    // One labeled color well for a palette token, registered so themeTokenChanged
    // can map it back to its editableTokens index (via themeColorWells order).
    private func tokenWellControl(label: String) -> [NSView] {
        let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        well.target = self
        well.action = #selector(themeTokenChanged)
        themeColorWells.append(well)
        let caption = NSTextField(labelWithString: label + ":")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = Theme.textDim
        caption.alignment = .right
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.widthAnchor.constraint(equalToConstant: 92).isActive = true
        return [caption, well]
    }

    // One catalog row: the theme name, a "· built-in / author" subtitle, and a
    // trailing checkmark on the active theme.
    private func themeCell(row: Int) -> NSView {
        let info = themeRows[row]
        let cell = NSTableCellView()

        let label = NSTextField(labelWithString: info.palette.name)
        label.font = .systemFont(ofSize: 13)
        label.textColor = Theme.textPrimary
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail

        let subtitle = info.isBuiltIn ? "built-in" : (info.author.isEmpty ? "custom" : info.author)
        let sub = NSTextField(labelWithString: subtitle)
        sub.font = .systemFont(ofSize: 10)
        sub.textColor = Theme.textFaint
        sub.translatesAutoresizingMaskIntoConstraints = false
        sub.setContentHuggingPriority(.required, for: .horizontal)
        sub.setContentCompressionResistancePriority(.required, for: .horizontal)

        let check = NSImageView()
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Active")
        check.contentTintColor = Theme.accent
        check.translatesAutoresizingMaskIntoConstraints = false
        check.isHidden = info.id != ThemeStore.shared.selected.id

        cell.addSubview(label)
        cell.addSubview(sub)
        cell.addSubview(check)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            sub.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            sub.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            check.leadingAnchor.constraint(equalTo: sub.trailingAnchor, constant: 8),
            check.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            check.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 12),
        ])
        return cell
    }

    var autopilotSteppers: [LabeledStepper] {
        [autopilotNightStartStepper, autopilotNightEndStepper, autopilotFiveHourStepper,
         autopilotWeeklyStepper, autopilotHardStopStepper, autopilotPaceStepper,
         autopilotAttemptsStepper, autopilotStallStepper]
    }

    // The Shortcuts pane: a read-only reference of every keyboard shortcut,
    // built from KeyboardShortcuts.groups (the single source of truth that
    // README.md and AppDelegate's menu mirror).
    private func buildDocsView() -> NSView {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.translatesAutoresizingMaskIntoConstraints = false

        content.addArrangedSubview(paneTitle("Shortcuts"))
        content.setCustomSpacing(16, after: content.arrangedSubviews.last!)

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

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 22),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -28),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
        ])
        return document
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

    // A pane's large title, shown at the top of each detail form.
    private func paneTitle(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.textColor = Theme.textPrimary
        return label
    }

    private func sectionHeader(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = Theme.textDim
        return label
    }

    // A dimmed, wrapping caption aligned under a form's controls (empty label
    // gutter), used for the per-setting explanatory hints.
    private func hintRow(_ text: String, width: CGFloat = 300) -> NSView {
        let hint = NSTextField(labelWithString: text)
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = Theme.textDim
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 0
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.preferredMaxLayoutWidth = width
        return row(label: "", controls: [hint])
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

// A live preview of a whole palette: its editable tokens drawn as equal-width
// bars in editableTokens order, so an edit shows the theme's full colour set at
// a glance. `palette` is set from the selected/edited theme; setting it redraws.
final class ThemePreviewStrip: NSView {
    var palette: Theme.Palette? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        Theme.raised.setFill()
        bounds.fill()
        guard let colors = palette?.orderedTokenColors, !colors.isEmpty else { return }
        let width = bounds.width / CGFloat(colors.count)
        for (i, color) in colors.enumerated() {
            color.setFill()
            NSRect(x: CGFloat(i) * width, y: 0, width: width.rounded(.up), height: bounds.height).fill()
        }
    }
}

// A drop target that imports ".suittheme" files dragged onto the theme list,
// handing their URLs to `onDrop`. Kept as its own view (rather than draggging
// methods on the shared table delegate) so the two tables stay independent.
final class ThemeDropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func themeURLs(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? [])
            .filter { $0.pathExtension == "suittheme" }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        themeURLs(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = themeURLs(sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}
