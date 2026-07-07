import Cocoa

extension AppDelegate {
    // MARK: - Claude sessions

    // Notification click-through: find the tab running the session, whichever
    // window it's in.
    func focusSession(withId id: String) {
        guard let session = ClaudeSessionMonitor.shared.sessions.first(where: { $0.id == id }) else { return }
        let controller = windowControllers.first { $0.runsClaudeSession(withId: id) }
        (controller ?? activeWindowController())?.focusPane(runningSession: session)
    }

    // MARK: - Session steering (ROADMAP Phase 8)

    // The terminal tab hosting a session's pty, whichever window and tab it's
    // hidden in — the write-side counterpart of focusSession.
    func terminalContent(forSessionId id: String) -> TerminalPaneContent? {
        for controller in windowControllers {
            if let tab = controller.store.tabs.first(where: { $0.claudeSession?.id == id }) {
                return tab.content as? TerminalPaneContent
            }
        }
        return nil
    }

    func performQuickAction(_ action: SessionQuickAction, on session: ClaudeSession) {
        guard let terminal = terminalContent(forSessionId: session.id) else {
            NSSound.beep()
            return
        }
        action.perform(on: terminal)
    }

    // Opens the prompt composer aimed at `session` — @-completion works over
    // the file index of the session's cwd (so paths complete against the
    // project claude is actually in), falling back to the active window's.
    func composePrompt(for session: ClaudeSession, prefill: String = "") {
        guard let terminal = terminalContent(forSessionId: session.id) else {
            NSSound.beep()
            return
        }
        let index: FileIndex?
        if let cwd = session.cwd {
            index = FileIndex.shared(forDirectory: cwd)
        } else {
            index = activeWindowController()?.currentFileIndex()
        }
        promptComposer.show(
            target: session,
            terminal: terminal,
            fileIndex: index,
            relativeTo: activeWindowController()?.window,
            prefill: prefill
        )
    }

    func composePrompt(forSessionId id: String, prefill: String = "") {
        guard let session = ClaudeSessionMonitor.shared.sessions.first(where: { $0.id == id }) else {
            NSSound.beep()
            return
        }
        composePrompt(for: session, prefill: prefill)
    }

    // ROADMAP Phase 16 — pipe a diff pane's review draft into a chosen session
    // as one structured prompt, then clear the draft (session picker when
    // several are live, same as the other steering verbs).
    func sendReview(from content: DiffPaneContent) {
        guard !content.reviewDraft.isEmpty else {
            NSSound.beep()
            return
        }
        let prompt = content.reviewDraft.composePrompt(ref: content.reviewRef)
        withSession(placeholder: "Send review to session…") { [weak self, weak content] session in
            guard let self, let content, let terminal = self.terminalContent(forSessionId: session.id) else {
                NSSound.beep()
                return
            }
            SessionControl.send(text: prompt, to: terminal, submit: true)
            content.reviewDraft.clear()
            content.reviewChanged()
        }
    }

    @objc func sendReviewToSession(_ sender: Any?) {
        guard let content = activeWindowController()?.currentDiffContent else {
            NSSound.beep()
            return
        }
        sendReview(from: content)
    }

    // ROADMAP Phase 29 — route a machine-feedback event (CI failure, PR review
    // comments, merge conflict) into its originating session as one structured
    // prompt. When attribution resolved a single session whose pty is hosted,
    // send straight there and focus it; otherwise fall back to the picker (the
    // phase's caveat: ambiguous attribution never guesses). Uses the longer
    // submit delay since a failure log can be multi-KB.
    func routeFeedback(_ event: FeedbackEvent) {
        let prompt = FeedbackRouting.composePrompt(for: event)
        if let id = event.sessionId, let terminal = terminalContent(forSessionId: id) {
            SessionControl.send(text: prompt, to: terminal, submit: true, submitDelay: 0.5)
            focusSession(withId: id)
            return
        }
        withSession(placeholder: "Route feedback to session…") { [weak self] session in
            guard let self, let terminal = self.terminalContent(forSessionId: session.id) else {
                NSSound.beep()
                return
            }
            SessionControl.send(text: prompt, to: terminal, submit: true, submitDelay: 0.5)
            self.focusSession(withId: session.id)
        }
    }

    // Palette "Route Feedback to Session…": gathers the active window's Git-tab
    // feedback events; one routes directly, several show a picker to choose
    // which event to route (each event then resolves its own target session).
    @objc func routeFeedbackFromPalette(_ sender: Any?) {
        guard let controller = activeWindowController() else { NSSound.beep(); return }
        let events = controller.currentFeedbackEvents()
        switch events.count {
        case 0:
            NSSound.beep()
        case 1:
            routeFeedback(events[0])
        default:
            paletteFileIndex = nil
            commandPalette.show(
                relativeTo: controller.window,
                commands: events.map { event in
                    let target = event.branch ?? (event.worktreePath as NSString).lastPathComponent
                    return PaletteCommand(title: "\(event.kind.label): \(event.title) · \(target)", shortcut: nil) { [weak self] in
                        self?.routeFeedback(event)
                    }
                },
                placeholder: "Route which feedback…"
            )
        }
    }

    // Palette entry points: with several sessions they go through a picker
    // palette (same machinery as Open Claude Transcript).
    @objc func promptClaudeSession(_ sender: Any?) {
        withSession(placeholder: "Prompt session…") { [weak self] session in
            self?.composePrompt(for: session)
        }
    }

    @objc func continueClaudeSession(_ sender: Any?) {
        withSession(placeholder: "Continue session…") { [weak self] session in
            self?.performQuickAction(.continueSession, on: session)
        }
    }

    @objc func compactClaudeSession(_ sender: Any?) {
        withSession(placeholder: "Compact session…") { [weak self] session in
            self?.performQuickAction(.compact, on: session)
        }
    }

    @objc func interruptClaudeSession(_ sender: Any?) {
        withSession(placeholder: "Interrupt session…") { [weak self] session in
            self?.performQuickAction(.interrupt, on: session)
        }
    }

    // Runs `body` on the one session, or shows a session-picker palette when
    // several are live. Only sessions whose pty is actually hosted by some
    // pane are offered — the others can't be written to.
    private func withSession(placeholder: String, _ body: @escaping (ClaudeSession) -> Void) {
        let sessions = ClaudeSessionMonitor.shared.sessions.filter { terminalContent(forSessionId: $0.id) != nil }
        switch sessions.count {
        case 0:
            NSSound.beep()
        case 1:
            body(sessions[0])
        default:
            paletteFileIndex = nil
            commandPalette.show(
                relativeTo: activeWindowController()?.window,
                commands: sessions.map { session in
                    let project = (session.cwd as NSString?)?.lastPathComponent ?? ""
                    return PaletteCommand(title: "\(session.displayName) — \(session.state.label) · \(project)", shortcut: nil) {
                        body(session)
                    }
                },
                placeholder: placeholder
            )
        }
    }

    // MARK: - Set as Goal (ROADMAP Phase 18)

    // Composes `/goal ` + the selection (optionally prefixed with provenance)
    // and sends it into a chosen Claude session's pty, bracketed-paste-wrapped
    // and submitted — turning "this is what I want done" into a two-click
    // gesture. `file`/`startLine` are known for viewer selections and drive the
    // provenance line when the setting is on; terminal/transcript selections
    // pass nil (no meaningful source location).
    func setSelectionAsGoal(_ selection: String, file: String? = nil, startLine: Int? = nil, endLine: Int? = nil) {
        guard let goalText = Self.composeGoalText(
            selection: selection, file: file, startLine: startLine, endLine: endLine,
            includeProvenance: goalPrependProvenanceEnabled
        ) else { NSSound.beep(); return }
        withGoalSession { [weak self] session in
            guard let self, let terminal = self.terminalContent(forSessionId: session.id) else {
                NSSound.beep()
                return
            }
            self.lastGoalSessionId = session.id
            SessionControl.send(text: goalText, to: terminal, submit: true)
        }
    }

    // The `/goal `-prefixed text sent into the session, factored out so the
    // provenance formatting is verifiable on its own. nil for an all-whitespace
    // selection (nothing to steer with).
    static func composeGoalText(selection: String, file: String?, startLine: Int?, endLine: Int?, includeProvenance: Bool) -> String? {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var payload = trimmed
        if includeProvenance, let file, let startLine {
            let name = (file as NSString).lastPathComponent
            let range = (endLine.map { $0 != startLine } ?? false) ? "\(startLine)-\(endLine!)" : "\(startLine)"
            payload = "From \(name):\(range):\n" + trimmed
        }
        return "/goal " + payload
    }

    // Palette "Set Selection as Claude Goal": reads the selection from whatever
    // the focused pane is showing (viewer, transcript, or terminal).
    @objc func setSelectionAsGoalFromFocused(_ sender: Any?) {
        guard let pane = activeWindowController()?.focusedPane() else { NSSound.beep(); return }
        if let viewer = pane.content as? FileViewerPaneContent {
            viewer.setSelectionAsGoal()
        } else if let transcript = pane.content as? TranscriptPaneContent {
            transcript.setSelectionAsGoal()
        } else if let terminal = pane.terminalContent {
            guard let text = terminal.terminalView.getSelection() else { NSSound.beep(); return }
            setSelectionAsGoal(text)
        } else {
            NSSound.beep()
        }
    }

    // Like withSession, but orders the last-targeted session first so the
    // picker's default (Enter) repeats it.
    private func withGoalSession(_ body: @escaping (ClaudeSession) -> Void) {
        var sessions = ClaudeSessionMonitor.shared.sessions.filter { terminalContent(forSessionId: $0.id) != nil }
        switch sessions.count {
        case 0:
            NSSound.beep()
        case 1:
            body(sessions[0])
        default:
            if let idx = sessions.firstIndex(where: { $0.id == lastGoalSessionId }), idx != 0 {
                sessions.insert(sessions.remove(at: idx), at: 0)
            }
            paletteFileIndex = nil
            commandPalette.show(
                relativeTo: activeWindowController()?.window,
                commands: sessions.map { session in
                    let project = (session.cwd as NSString?)?.lastPathComponent ?? ""
                    let marker = session.id == lastGoalSessionId ? " ⟲" : ""
                    return PaletteCommand(title: "\(session.displayName) — \(session.state.label) · \(project)\(marker)", shortcut: nil) {
                        body(session)
                    }
                },
                placeholder: "Set as goal in session…"
            )
        }
    }

    @objc func claudeSessionsUpdated(_ note: Notification) {
        remapClaudeSessions()
    }

    func remapClaudeSessions() {
        let assigner = ClaudeSessionMonitor.shared.makeAssigner()
        for controller in windowControllers {
            controller.refreshClaudeSessions(assigner: assigner)
        }
    }

    // Injects /rewind into a session's pty so Claude's native rewind picker
    // opens in the pane (ROADMAP Phase 25). Driven from the timeline's header.
    func rewindSession(withId id: String) {
        guard let terminal = terminalContent(forSessionId: id) else {
            NSSound.beep()
            return
        }
        SessionControl.send(text: "/rewind", to: terminal, submit: true)
    }
}
