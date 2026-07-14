import Cocoa

extension AppDelegate {
    // MARK: - Sidebar & command palette

    @objc func toggleSidebar(_ sender: Any?) {
        activeWindowController()?.toggleSidebar()
    }

    @objc func searchInProject(_ sender: Any?) {
        activeWindowController()?.focusProjectSearch()
    }

    @objc func showGitDiff(_ sender: Any?) {
        activeWindowController()?.openGitDiff()
    }

    // The commit-graph pane for the shown repo.
    @objc func showCommitGraph(_ sender: Any?) {
        activeWindowController()?.openCommitGraph()
    }

    // Sidebar folder pinning.
    @objc func selectSidebarFolder(_ sender: Any?) {
        activeWindowController()?.selectSidebarFolder()
    }

    @objc func showNotes(_ sender: Any?) {
        activeWindowController()?.showNotes()
    }

    @objc func showGit(_ sender: Any?) {
        activeWindowController()?.showGit()
    }

    // Reveal the Git tab's Feedback inbox and refresh it.
    @objc func showFeedbackInbox(_ sender: Any?) {
        activeWindowController()?.showFeedbackInbox()
    }

    // Reveal the Git tab's PR review inbox and refresh it.
    @objc func showPRReviewInbox(_ sender: Any?) {
        activeWindowController()?.showPRReviewInbox()
    }

    // File:line bookmarks.
    @objc func showBookmarks(_ sender: Any?) {
        activeWindowController()?.showBookmarks()
    }

    // "what changed while I was away" markers.
    @objc func markAwayPoint(_ sender: Any?) {
        activeWindowController()?.markAwayPoint()
    }

    @objc func showCatchUpDiff(_ sender: Any?) {
        activeWindowController()?.openCatchUpDiff()
    }

    // Routed through the responder chain to the focused file viewer (like
    // Go to Line); a beep when nothing focused is a viewer.
    @objc func toggleBookmark(_ sender: Any?) {
        if !NSApp.sendAction(#selector(ViewerTextView.toggleBookmark(_:)), to: nil, from: sender) {
            NSSound.beep()
        }
    }

    // "New task": prompt for a name, then claude pane via the
    // window controller. The prompt carries an "Isolate in worktree"
    // switch (seeded from the settings default) so isolation is a per-task
    // choice: on spins a worktree, off runs claude in the current checkout.
    @objc func newClaudeTask(_ sender: Any?) {
        guard let controller = activeWindowController() else {
            NSSound.beep()
            return
        }
        OverlayPromptController.shared.ask(
            caption: "New Claude Task — claude session",
            placeholder: "task name",
            toggleLabel: "Isolate in worktree",
            toggleOn: taskIsolateByDefault,
            over: controller.window
        ) { [weak controller] name, isolate in
            guard !name.isEmpty else { return }
            controller?.startClaudeTask(named: name, isolate: isolate)
        }
    }

    // Install/refresh the Claude Code integration (statusline + session hooks)
    // from the scripts bundled in the app — see ClaudeIntegration.swift.
    @objc func installClaudeIntegration(_ sender: Any?) {
        let confirm = NSAlert()
        var install = "Copies the statusline and session-hook scripts bundled with the app to ~/.suit/scripts and wires them into ~/.claude/settings.json (statusLine plus UserPromptSubmit/Notification/Stop hooks), so the Sessions sidebar and the usage display work. Your settings file is backed up first; nothing else in it is touched."
        switch ClaudeIntegration.status() {
        case .installed:
            confirm.messageText = "Claude Code integration is already installed"
            install = "Scripts and settings are up to date with this build. Reinstall anyway?"
            confirm.addButton(withTitle: "Reinstall")
        case .outdated:
            confirm.messageText = "Update Claude Code integration?"
            install = "The installed scripts differ from the ones bundled with this build. " + install
            confirm.addButton(withTitle: "Update")
        case .notInstalled:
            confirm.messageText = "Install Claude Code integration?"
            confirm.addButton(withTitle: "Install")
        }
        if let foreign = ClaudeIntegration.existingForeignStatusLine() {
            install += "\n\nNote: this replaces your current statusLine command (\(foreign))."
        }
        confirm.informativeText = install
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let result = NSAlert()
        do {
            let report = try ClaudeIntegration.install()
            result.messageText = "Claude Code integration installed"
            var lines = ["Scripts: \(report.scriptsDir)"]
            if report.settingsChanged {
                var line = "Updated ~/.claude/settings.json"
                if let backup = report.backupPath { line += " (backup: \(backup))" }
                lines.append(line)
            } else {
                lines.append("~/.claude/settings.json was already up to date.")
            }
            if let replaced = report.replacedStatusLine {
                lines.append("Replaced the previous statusLine command: \(replaced)")
            }
            if !report.jqFound {
                lines.append("⚠︎ jq was not found — the scripts need it (brew install jq).")
            }
            lines.append("Already-running claude sessions pick this up on their next restart.")
            result.informativeText = lines.joined(separator: "\n")
        } catch {
            result.alertStyle = .warning
            result.messageText = "Install failed"
            result.informativeText = error.localizedDescription
        }
        result.runModal()
    }

    @objc func showCommandPalette(_ sender: Any?) {
        paletteFileIndex = nil
        commandPalette.show(relativeTo: activeWindowController()?.window)
    }

    // Palette: open a session's transcript pane. One live session opens
    // directly; several reuse the palette in explicit-items mode (the Cmd-P
    // trick) as the session picker.
    @objc func openClaudeTranscript(_ sender: Any?) {
        guard let controller = activeWindowController() else { return }
        let sessions = ClaudeSessionMonitor.shared.sessions
        switch sessions.count {
        case 0:
            NSSound.beep()
        case 1:
            controller.openTranscript(for: sessions[0])
        default:
            paletteFileIndex = nil
            commandPalette.show(
                relativeTo: controller.window,
                commands: sessions.map { session in
                    let project = (session.cwd as NSString?)?.lastPathComponent ?? ""
                    return PaletteCommand(title: "\(session.displayName) — \(session.state.label) · \(project)", shortcut: nil) { [weak controller] in
                        controller?.openTranscript(for: session)
                    }
                },
                placeholder: "Open transcript for session…"
            )
        }
    }

    // Palette: switch the app's color theme. Lists all themes (built-ins + user,
    // active one ticked) and applies the chosen one through ThemeStore — the same
    // live-apply path as the Settings Themes list, no relaunch needed.
    @objc func switchTheme(_ sender: Any?) {
        guard let controller = activeWindowController() else { NSSound.beep(); return }
        let store = ThemeStore.shared
        let activeId = store.selected.id
        paletteFileIndex = nil
        commandPalette.show(
            relativeTo: controller.window,
            commands: store.allThemes.map { info in
                let tag = info.isBuiltIn ? " · built-in" : ""
                let tick = info.id == activeId ? "  ✓" : ""
                return PaletteCommand(title: "\(info.palette.name)\(tag)\(tick)", shortcut: nil) {
                    ThemeStore.shared.apply(id: info.id)
                }
            },
            placeholder: "Switch theme…"
        )
    }

    // Palette / View menu: the cross-transcript search panel.
    @objc func searchTranscripts(_ sender: Any?) {
        transcriptSearch.show(relativeTo: activeWindowController()?.window)
    }

    // Palette: open a session's checkpoint-timeline pane.
    // One live session opens directly; several go through the palette picker,
    // exactly like Open Claude Transcript.
    @objc func openCheckpointTimeline(_ sender: Any?) {
        guard let controller = activeWindowController() else { return }
        let sessions = ClaudeSessionMonitor.shared.sessions
        switch sessions.count {
        case 0:
            NSSound.beep()
        case 1:
            controller.openCheckpointTimeline(for: sessions[0])
        default:
            paletteFileIndex = nil
            commandPalette.show(
                relativeTo: controller.window,
                commands: sessions.map { session in
                    let project = (session.cwd as NSString?)?.lastPathComponent ?? ""
                    return PaletteCommand(title: "\(session.displayName) — \(session.state.label) · \(project)", shortcut: nil) { [weak controller] in
                        controller?.openCheckpointTimeline(for: session)
                    }
                },
                placeholder: "Open checkpoint timeline for session…"
            )
        }
    }

    // Multi-definition picker: several definitions of one
    // symbol reuse the palette in explicit-items mode (the Cmd-P trick), each
    // row `file:line` with the ctags kind, jumping straight to the chosen one.
    func showDefinitionPicker(symbol: String, definitions: [SymbolDefinition], root: String, controller: TerminalWindowController) {
        paletteFileIndex = nil
        commandPalette.show(
            relativeTo: controller.window,
            commands: definitions.map { definition in
                let kind = definition.kind.map { " · \($0)" } ?? ""
                let title = "\(definition.relativePath):\(definition.lineNumber)\(kind)"
                return PaletteCommand(title: title, shortcut: nil) { [weak controller] in
                    controller?.openDefinition(definition, root: root)
                }
            },
            placeholder: "Go to definition of \(symbol)…"
        )
    }

    // MARK: - Fuzzy file opener (Cmd-P)

    @objc func openQuickly(_ sender: Any?) {
        guard let controller = activeWindowController() else { return }
        let index = controller.currentFileIndex()
        paletteFileIndex = index
        commandPalette.show(
            relativeTo: controller.window,
            commands: fileCommands(index: index, controller: controller),
            placeholder: openQuicklyPlaceholder(for: index)
        )
    }

    private func openQuicklyPlaceholder(for index: FileIndex) -> String {
        let name = (index.root as NSString).lastPathComponent
        return index.isScanning && index.files.isEmpty ? "Indexing \(name)…" : "Open file in \(name)…"
    }

    private func fileCommands(index: FileIndex, controller: TerminalWindowController) -> [PaletteCommand] {
        let root = index.root
        return index.files.map { relativePath in
            PaletteCommand(title: relativePath, shortcut: nil) { [weak controller] in
                controller?.openFile(atPath: root + "/" + relativePath, line: nil)
            }
        }
    }

    // The first scan of a large project can land after Cmd-P was pressed; this
    // swaps the fresh list under the open palette instead of leaving it empty.
    @objc func fileIndexUpdated(_ note: Notification) {
        guard let index = note.object as? FileIndex,
              index === paletteFileIndex,
              commandPalette.isVisible,
              let controller = activeWindowController() else { return }
        commandPalette.refreshCommands(fileCommands(index: index, controller: controller))
    }

    // Every menu action, reachable by typing. Rebuilt on each palette open, so
    // entries can reflect current state without any invalidation plumbing.
    func paletteCommands() -> [PaletteCommand] {
        [
            PaletteCommand(title: "Open File…", shortcut: "⌘P") { [weak self] in self?.openQuickly(nil) },
            PaletteCommand(title: "Search in Project…", shortcut: "⇧⌘F") { [weak self] in self?.searchInProject(nil) },
            PaletteCommand(title: "Show Git Diff", shortcut: "⌃⌘D") { [weak self] in self?.showGitDiff(nil) },
            PaletteCommand(title: "Show Commit Graph", shortcut: nil) { [weak self] in self?.showCommitGraph(nil) },
            PaletteCommand(title: "Review Changes (n/p walk files, o opens, c comments)", shortcut: nil) { [weak self] in self?.showGitDiff(nil) },
            PaletteCommand(title: "Send Review to Session…", shortcut: nil) { [weak self] in self?.sendReviewToSession(nil) },
            PaletteCommand(title: "Show Fleet (all sessions)", shortcut: "⇧⌘O") { [weak self] in self?.showFleet(nil) },
            PaletteCommand(title: "Show Activity Feed", shortcut: nil) { [weak self] in self?.showActivityFeed(nil) },
            PaletteCommand(title: "Search Command History…", shortcut: "⌃R") { [weak self] in self?.showCommandHistory(nil) },
            PaletteCommand(title: "Broadcast to All Sessions…", shortcut: nil) { [weak self] in self?.broadcastToAllSessions(nil) },
            PaletteCommand(title: "Set Session Budget…", shortcut: nil) { [weak self] in self?.setSessionBudgetFromPalette(nil) },
            PaletteCommand(title: "Show Background Tasks", shortcut: nil) { [weak self] in self?.showBackgroundTasks(nil) },
            PaletteCommand(title: "Show Feedback Inbox", shortcut: nil) { [weak self] in self?.showFeedbackInbox(nil) },
            PaletteCommand(title: "Route Feedback to Session…", shortcut: nil) { [weak self] in self?.routeFeedbackFromPalette(nil) },
            PaletteCommand(title: "Show PR Review Inbox", shortcut: nil) { [weak self] in self?.showPRReviewInbox(nil) },
            PaletteCommand(title: "Submit PR Review…", shortcut: nil) { [weak self] in self?.submitPRReviewCommand(nil) },
            PaletteCommand(title: "Dictate (hold 🌐 Globe to talk)", shortcut: nil) { [weak self] in self?.startDictation(nil) },
            PaletteCommand(title: "New Claude Session", shortcut: "⌃⌘C") { [weak self] in self?.newClaudeSession(nil) },
            PaletteCommand(title: "New Claude Task…", shortcut: "⌃⌘T") { [weak self] in self?.newClaudeTask(nil) },
            PaletteCommand(title: "Open Claude Transcript…", shortcut: nil) { [weak self] in self?.openClaudeTranscript(nil) },
            PaletteCommand(title: "Open Checkpoint Timeline…", shortcut: nil) { [weak self] in self?.openCheckpointTimeline(nil) },
            PaletteCommand(title: "Search Transcripts…", shortcut: nil) { [weak self] in self?.searchTranscripts(nil) },
            PaletteCommand(title: "Claude: Prompt Session…", shortcut: nil) { [weak self] in self?.promptClaudeSession(nil) },
            PaletteCommand(title: "Claude: Continue Session", shortcut: nil) { [weak self] in self?.continueClaudeSession(nil) },
            PaletteCommand(title: "Claude: Compact Session (/compact)", shortcut: nil) { [weak self] in self?.compactClaudeSession(nil) },
            PaletteCommand(title: "Claude: Compact Focused Session (/compact)", shortcut: "⌃⌘K") { [weak self] in self?.compactFocusedSession(nil) },
            PaletteCommand(title: "Claude: Slash Command Menu…", shortcut: "⌃⌘/") { [weak self] in self?.showSlashCommandMenu(nil) },
            PaletteCommand(title: "Claude: Interrupt Session (Esc)", shortcut: nil) { [weak self] in self?.interruptClaudeSession(nil) },
            PaletteCommand(title: "Claude: Ask Mode", shortcut: nil) { [weak self] in self?.setSessionModeAsk(nil) },
            PaletteCommand(title: "Claude: Plan Mode", shortcut: nil) { [weak self] in self?.setSessionModePlan(nil) },
            PaletteCommand(title: "Claude: Agent Mode", shortcut: nil) { [weak self] in self?.setSessionModeAgent(nil) },
            PaletteCommand(title: "Claude: Review Plan…", shortcut: nil) { [weak self] in self?.openPlanForReview(nil) },
            PaletteCommand(title: "Set Selection as Claude Goal", shortcut: nil) { [weak self] in self?.setSelectionAsGoalFromFocused(nil) },
            PaletteCommand(title: "Save File", shortcut: "⌘S") { NSApp.sendAction(#selector(ViewerTextView.saveFile(_:)), to: nil, from: nil) },
            PaletteCommand(title: "Go to Line…", shortcut: "⌘L") { NSApp.sendAction(#selector(ViewerTextView.goToLine(_:)), to: nil, from: nil) },
            PaletteCommand(title: "Toggle Blame", shortcut: "⌃⌘B") { NSApp.sendAction(#selector(ViewerTextView.toggleBlame(_:)), to: nil, from: nil) },
            PaletteCommand(title: "Show File History", shortcut: nil) { NSApp.sendAction(#selector(ViewerTextView.showFileHistory(_:)), to: nil, from: nil) },
            PaletteCommand(title: "Time Travel", shortcut: "⌃⌘H") { NSApp.sendAction(#selector(ViewerTextView.toggleTimeTravel(_:)), to: nil, from: nil) },
            PaletteCommand(title: "Go to Definition", shortcut: "⌃⌘J") { NSApp.sendAction(#selector(ViewerTextView.goToDefinition(_:)), to: nil, from: nil) },
            PaletteCommand(title: "Find References", shortcut: "⌃⌘R") { NSApp.sendAction(#selector(ViewerTextView.findReferences(_:)), to: nil, from: nil) },
            PaletteCommand(title: "Save Layout As…", shortcut: nil) { [weak self] in self?.saveLayoutAs(nil) },
            PaletteCommand(title: "Open Layout…", shortcut: nil) { [weak self] in self?.openLayout(nil) },
            PaletteCommand(title: "Rename Layout…", shortcut: nil) { [weak self] in self?.renameLayout(nil) },
            PaletteCommand(title: "Delete Layout…", shortcut: nil) { [weak self] in self?.deleteLayout(nil) },
            PaletteCommand(title: "Split Screen (new terminal)", shortcut: "⌘D") { [weak self] in self?.splitScreen(nil) },
            PaletteCommand(title: "Split Screen Horizontally (new terminal)", shortcut: "⇧⌘D") { [weak self] in self?.splitScreenHorizontally(nil) },
            PaletteCommand(title: "Split Screen (last used tab)", shortcut: "") { [weak self] in self?.splitScreenWithLastUsedTab(nil) },
            PaletteCommand(title: "Split Screen with Tab…", shortcut: "") { [weak self] in self?.splitScreenWithPicker() },
            PaletteCommand(title: "Unsplit All", shortcut: "⌃⌘M") { [weak self] in self?.mergeAllPanes(nil) },
            PaletteCommand(title: "New Tab", shortcut: "⌘T") { [weak self] in self?.newTab(nil) },
            PaletteCommand(title: "Reopen Closed Tab", shortcut: "⇧⌘T") { [weak self] in self?.reopenClosedTab(nil) },
            PaletteCommand(title: "Next Tab", shortcut: "⇧⌘]") { [weak self] in self?.nextTab(nil) },
            PaletteCommand(title: "Previous Tab", shortcut: "⇧⌘[") { [weak self] in self?.previousTab(nil) },
            PaletteCommand(title: "Go to Tab… (all open tabs)", shortcut: nil) { [weak self] in self?.showTabPalette(nil) },
            PaletteCommand(title: "Keep Preview Tab Open", shortcut: nil) { [weak self] in self?.keepPreviewTab(nil) },
            PaletteCommand(title: "Pin / Unpin Tab", shortcut: nil) { [weak self] in self?.togglePinTab(nil) },
            PaletteCommand(title: "Rename Tab…", shortcut: nil) { [weak self] in self?.renameTab(nil) },
            PaletteCommand(title: "Close Tab", shortcut: "⌘W") { [weak self] in self?.closeTab(nil) },
            PaletteCommand(title: "Unsplit (keep tab)", shortcut: "⌥⌘W") { [weak self] in self?.closePane(nil) },
            PaletteCommand(title: "New Window", shortcut: "⌘N") { [weak self] in self?.newWindow(nil) },
            PaletteCommand(title: "Toggle Sidebar", shortcut: "⌘B") { [weak self] in self?.toggleSidebar(nil) },
            PaletteCommand(title: "Select Sidebar Folder…", shortcut: nil) { [weak self] in self?.selectSidebarFolder(nil) },
            PaletteCommand(title: "Show Notes", shortcut: nil) { [weak self] in self?.showNotes(nil) },
            PaletteCommand(title: "Show Git", shortcut: nil) { [weak self] in self?.showGit(nil) },
            PaletteCommand(title: "Show Bookmarks", shortcut: nil) { [weak self] in self?.showBookmarks(nil) },
            PaletteCommand(title: "Mark Now (checkpoint for “what changed”)", shortcut: nil) { [weak self] in self?.markAwayPoint(nil) },
            PaletteCommand(title: "What Changed Since Mark", shortcut: nil) { [weak self] in self?.showCatchUpDiff(nil) },
            PaletteCommand(title: "Toggle Bookmark", shortcut: "⇧⌘L") { [weak self] in self?.toggleBookmark(nil) },
            PaletteCommand(title: "Increase Font Size", shortcut: "⌘=") { [weak self] in self?.increaseFontSize(nil) },
            PaletteCommand(title: "Decrease Font Size", shortcut: "⌘-") { [weak self] in self?.decreaseFontSize(nil) },
            PaletteCommand(title: "Increase Font Size (All Panes)", shortcut: "⇧⌘=") { [weak self] in self?.increaseAllFontSizes(nil) },
            PaletteCommand(title: "Decrease Font Size (All Panes)", shortcut: "⇧⌘-") { [weak self] in self?.decreaseAllFontSizes(nil) },
            PaletteCommand(title: "Increase Opacity", shortcut: "⌘]") { [weak self] in self?.increaseOpacity(nil) },
            PaletteCommand(title: "Decrease Opacity", shortcut: "⌘[") { [weak self] in self?.decreaseOpacity(nil) },
            PaletteCommand(title: "Toggle Background Blur", shortcut: "⇧⌘B") { [weak self] in self?.toggleBlur(nil) },
            PaletteCommand(title: "Toggle Word Wrap", shortcut: nil) { [weak self] in self?.toggleWordWrap(nil) },
            PaletteCommand(title: "Switch Theme…", shortcut: nil) { [weak self] in self?.switchTheme(nil) },
            PaletteCommand(title: "Settings…", shortcut: "⌘,") { [weak self] in self?.showSettings(nil) },
            PaletteCommand(title: "Install Claude Code Integration…", shortcut: nil) { [weak self] in self?.installClaudeIntegration(nil) },
            PaletteCommand(title: "Check for Updates…", shortcut: nil) { [weak self] in self?.checkForUpdates(nil) },
        ] + autopilotPaletteCommands() + sshHostCommands() + recipeCommands() + promptLibraryCommands()
    }

    // Session task recipes: each ~/.suit/recipes/*.md surfaces
    // as a "Recipe: <name>" entry that spins a worktree + claude + a
    // parameterized prompt in one keystroke.
    private func recipeCommands() -> [PaletteCommand] {
        // Re-read the directory each open so a freshly-added recipe file shows
        // up without a relaunch (the prompt library's freshness).
        RecipesStore.shared.reload()
        return RecipesStore.shared.recipes.map { recipe in
            PaletteCommand(title: "Recipe: \(recipe.name)", shortcut: nil) { [weak self] in
                self?.launchRecipe(recipe)
            }
        }
    }

    // Prompts for the task name (+ the isolation toggle), fills the
    // recipe's <NAME>/<SELECTION>/<FILE> from the input and the focused pane's
    // context, then launches the task.
    private func launchRecipe(_ recipe: Recipe) {
        guard let controller = activeWindowController() else {
            NSSound.beep()
            return
        }
        let context = controller.recipeContext()
        OverlayPromptController.shared.ask(
            caption: "Recipe: \(recipe.name) — task name",
            placeholder: "task name",
            toggleLabel: "Isolate in worktree",
            toggleOn: taskIsolateByDefault,
            over: controller.window
        ) { [weak controller] name, isolate in
            guard !name.isEmpty else { return }
            let prompt = recipe.filled(name: name, selection: context.selection, file: context.file)
            controller?.startRecipeTask(named: name, promptText: prompt, isolate: isolate)
        }
    }

    // Saved SSH hosts (the sidebar's SSH tab) as palette entries, so a
    // connection is reachable from ⌘K without the sidebar.
    private func sshHostCommands() -> [PaletteCommand] {
        SSHHostsStore.shared.hosts.map { host in
            PaletteCommand(title: "SSH: \(host.displayName)", shortcut: nil) { [weak self] in
                guard let controller = self?.activeWindowController() else {
                    NSSound.beep()
                    return
                }
                controller.openSSHTab(host: host)
            }
        }
    }

    // The prompt library: ~/.suit/prompts/*.md surfaced
    // as palette entries that send into the focused pane's terminal. Saved
    // prompts as files, not a settings UI.
    private func promptLibraryCommands() -> [PaletteCommand] {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let dir = home + "/.suit/prompts"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.filter { $0.hasSuffix(".md") }.sorted().map { name in
            PaletteCommand(title: "Prompt: \((name as NSString).deletingPathExtension)", shortcut: nil) { [weak self] in
                guard let self,
                      let text = try? String(contentsOfFile: dir + "/" + name, encoding: .utf8),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let terminal = self.activeWindowController()?.focusedPane()?.terminalContent else {
                    NSSound.beep()
                    return
                }
                SessionControl.send(text: text.trimmingCharacters(in: .whitespacesAndNewlines), to: terminal, submit: true)
            }
        }
    }
}
