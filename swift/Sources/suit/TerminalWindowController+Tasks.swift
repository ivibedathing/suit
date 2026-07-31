import Cocoa

// Launching Claude work from this window: the manual task / recipe /
// review-pass launchers (a terminal tab + `claude` typed in after a beat,
// optionally in a fresh task worktree). They use fixed delays rather than any
// session-file handshake — they're one-off interactive actions.
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

    // MARK: - Task lifecycle

    // A task tab finished (worktree merged/discarded and removed): close it
    // without the usual running-process confirmation — the user just confirmed
    // the whole task's fate in the finish dialog.
    func paneFinishedTask(_ pane: Pane) {
        forceCloseTab(pane.tab)
    }
}
