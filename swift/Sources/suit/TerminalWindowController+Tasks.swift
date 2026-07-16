import Cocoa

// Launching Claude work from this window: the manual task / recipe /
// review-pass launchers (a terminal tab + `claude` typed in after a beat,
// optionally in a fresh task worktree), and Autopilot's run-tab open/close.
// The manual launchers use fixed delays, not Autopilot's session-file
// handshake — they're one-off interactive actions, not an autonomous loop.
extension TerminalWindowController {

    // MARK: - Manual task launchers

    // Resolves where a named task runs: a dedicated task worktree + branch
    // when isolation is on (alerting on failure), else the current checkout
    // for cheap tasks that don't want the worktree churn.
    private func taskDirectory(named name: String, isolate: Bool, alertTitle: String) -> String? {
        let root = currentFileIndex().root
        guard TaskLaunch.usesWorktree(isolate: isolate) else {
            return TaskLaunch.checkoutDirectory(isolate: isolate, currentRoot: root, worktreeDirectory: nil)
        }
        switch WorktreeTasks.createTask(projectRoot: root, name: name) {
        case .failure(let error):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = alertTitle
            alert.informativeText = error.message
            alert.runModal()
            return nil
        case .success(let worktree):
            return TaskLaunch.checkoutDirectory(isolate: isolate, currentRoot: root, worktreeDirectory: worktree)
        }
    }

    // The launch shape all three manual verbs share: a terminal tab titled for
    // the task, `claude` typed in once zsh is ready to read it, and an
    // optional prompt sent after a beat, once claude's TUI is up.
    private func launchClaudeTab(in directory: String, title: String, prompt: String? = nil) {
        let content = TerminalPaneContent()
        let tab = Tab(content: content)
        tab.customTitle = title
        store.insert(tab)
        content.start(in: directory)
        activate(tab)
        let command = "claude"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak content] in
            content?.terminalView.send(txt: command + "\r")
        }
        guard let prompt, !prompt.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak content] in
            guard let content else { return }
            SessionControl.send(text: prompt, to: content, submit: true, submitDelay: 0.5)
        }
    }

    // "New task": a tab running claude, tagged with the task name (originally
    // one keystroke). Isolation is a per-task choice.
    func startClaudeTask(named name: String, isolate: Bool = true) {
        guard let directory = taskDirectory(named: name, isolate: isolate,
                                            alertTitle: "New Claude Task") else { return }
        launchClaudeTab(in: directory, title: name)
    }

    // Session task recipe: startClaudeTask plus the already-substituted
    // recipe prompt, sent once the TUI is up.
    func startRecipeTask(named name: String, promptText: String, isolate: Bool = true) {
        guard let directory = taskDirectory(named: name, isolate: isolate,
                                            alertTitle: "Recipe Task") else { return }
        launchClaudeTab(in: directory, title: name,
                        prompt: promptText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // The <FILE> / <SELECTION> a recipe fills from the focused pane: the viewer's
    // open file + selected text, or a terminal's selection. Empty when there's
    // no such context (the placeholders then collapse to nothing).
    func recipeContext() -> (file: String, selection: String) {
        guard let content = focusedPane()?.content else { return ("", "") }
        if let viewer = content as? FileViewerPaneContent {
            let range = viewer.textView.selectedRange()
            let selection = range.length > 0 ? (viewer.textView.string as NSString).substring(with: range) : ""
            return (viewer.filePath ?? "", selection)
        }
        if let terminal = content as? TerminalPaneContent {
            return ("", terminal.terminalView.getSelection() ?? "")
        }
        return ("", "")
    }

    // Reviewer-agent lane (optional): open a fresh claude in
    // the feedback event's worktree, primed to review the branch's changes with
    // the machine feedback as context — a dedicated review pass alongside the
    // working session.
    func startReviewPass(for event: FeedbackEvent) {
        let directory = event.worktreePath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            NSSound.beep()
            return
        }
        let label = event.branch.map { ($0 as NSString).lastPathComponent } ?? (directory as NSString).lastPathComponent
        launchClaudeTab(in: directory, title: "Review — \(label)",
                        prompt: FeedbackRouting.reviewPassPrompt(for: event))
    }

    // MARK: - Task & Autopilot run-tab lifecycle

    // A task tab finished (worktree merged/discarded and removed): close it
    // without the usual running-process confirmation — the user just confirmed
    // the whole task's fate in the finish dialog.
    func paneFinishedTask(_ pane: Pane) {
        forceCloseTab(pane.tab)
    }

    // Autopilot cleanup: a merged run's worker
    // tab closes without the running-process confirmation — the merge already
    // decided the run's fate (the paneFinishedTask trust, but tab-addressed:
    // the worker tab is usually backgrounded with no pane).
    func closeAutopilotRunTab(_ tab: Tab) {
        guard store.tab(withId: tab.id) != nil else { return }
        // The run tab as the window's only tab (torn off into its own window,
        // or every other tab closed overnight): forceCloseTab's count==1
        // branch would close the window — quitting the app when it's the last
        // one — killing the Autopilot loop mid-sequence. Open a replacement
        // shell tab first so the window (and the loop) survives; the pane's
        // MRU fallback then displays it.
        if store.tabs.count == 1 {
            let content = TerminalPaneContent()
            let replacement = Tab(content: content)
            store.insert(replacement)
            let root = appDelegate.autopilotProjectRoot
            content.start(in: root.isEmpty ? NSHomeDirectory() : root)
        }
        forceCloseTab(tab)
    }

    // Autopilot run tab (launch stage): the
    // startClaudeTask recipe minus worktree creation — the engine already made
    // the worktree. Inserted WITHOUT stealing focus (attention is signaled via
    // the footer, never forced); only a window with no tab at all
    // activates it, since there is nothing to steal focus from then.
    // `continueSession` is the §2.7 watchdog respawn: `claude --continue`
    // resumes the dead worker's conversation. `model`/`effort` are the
    // phase's routing annotations (ROADMAP.md "model:"/"effort:" body lines,
    // snapshotted on the run): they prefix the command with ANTHROPIC_MODEL /
    // CLAUDE_CODE_EFFORT_LEVEL so a mechanical phase can run on a cheaper
    // tier; the roadmap annotation is the explicit opt-in.
    @discardableResult
    func openAutopilotRunTab(directory: String, title: String, continueSession: Bool = false,
                             model: String? = nil, effort: String? = nil) -> Tab {
        let wasEmpty = store.tabs.isEmpty
        let content = TerminalPaneContent()
        let tab = Tab(content: content)
        tab.customTitle = title
        // MRU tail, not head: a background-spawned run must not hijack the
        // ⌃Tab quick-toggle or become the ⌘W close-tab fallback (keystrokes
        // would land in the autonomous worker's input box).
        store.insert(tab, background: true)
        content.start(in: directory)
        if wasEmpty {
            activate(tab)
        }
        refreshTabSurfaces()
        // One short line typed into zsh; the multi-KB instructions arrive
        // separately once the session file appears (§2.5 two-stage delivery,
        // which avoids every shell-quoting hazard). The extra args are kept
        // newline-free by the settings setter; strip again defensively — a
        // stray newline here would submit a truncated command line.
        var command = "claude --dangerously-skip-permissions"
        if continueSession { command += " --continue" }
        var envPrefix = ""
        if let model = model.map(Self.sanitizeEnvValue), !model.isEmpty {
            envPrefix += "ANTHROPIC_MODEL=\(Self.shellQuote(model)) "
        }
        if let effort = effort.map(Self.sanitizeEnvValue), !effort.isEmpty {
            envPrefix += "CLAUDE_CODE_EFFORT_LEVEL=\(Self.shellQuote(effort)) "
        }
        command = envPrefix + command
        let extraArgs = appDelegate.autopilotExtraArgs
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if !extraArgs.isEmpty { command += " " + extraArgs }
        // The pty input queue holds this until zsh is ready to read it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak content] in
            content?.terminalView.send(txt: command + "\n")
        }
        return tab
    }

    /// Newlines would submit a truncated pty command line; strip them and trim.
    private static func sanitizeEnvValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Single-quote a value for the zsh command line ('…' with embedded quotes escaped).
    private static func shellQuote(_ value: String) -> String {
        "'" + sanitizeEnvValue(value).replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
