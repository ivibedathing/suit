import Cocoa

// App-level verbs over live Claude sessions: focus/steer a session (quick
// actions typed into its pty), the fleet dashboard and broadcast entry points,
// the prompt composer, review / PR-review submission into a session, feedback
// routing, plan approval, and "Set as Goal". Session discovery and state live
// in ClaudeSessions.swift; this file only acts on what the monitor reports.
extension AppDelegate {
    // MARK: - Claude sessions

    // Notification click-through: find the tab running the session, whichever
    // window it's in.
    func focusSession(withId id: String) {
        guard let session = ClaudeSessionMonitor.shared.sessions.first(where: { $0.id == id }) else { return }
        let controller = windowControllers.first { $0.runsClaudeSession(withId: id) }
        (controller ?? activeWindowController())?.focusPane(runningSession: session)
    }

    // MARK: - Session steering

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

    // Fleet dashboard routes its per-row verbs by session id.
    func performQuickAction(_ action: SessionQuickAction, onSessionId id: String) {
        guard let terminal = terminalContent(forSessionId: id) else {
            NSSound.beep()
            return
        }
        action.perform(on: terminal)
    }

    // MARK: - Fleet-supervision dashboard

    // Every session id some pane currently hosts, across all windows — the
    // steerable rows in the dashboard (an unhosted "done" file can't be written).
    func hostedSessionIds() -> Set<String> {
        var ids = Set<String>()
        for controller in windowControllers {
            for tab in controller.store.tabs {
                if let id = tab.claudeSession?.id, tab.content is TerminalPaneContent {
                    ids.insert(id)
                }
            }
        }
        return ids
    }

    // Archive/Stop: close the tab hosting the session, wherever it lives —
    // the same path as ⌘W on that tab (confirms if a foreground process runs).
    func archiveSession(withId id: String) {
        for controller in windowControllers {
            if let tab = controller.store.tabs.first(where: { $0.claudeSession?.id == id }) {
                controller.closeTab(tab)
                return
            }
        }
        NSSound.beep()
    }

    @objc func showFleet(_ sender: Any?) {
        fleetDashboard.toggle(relativeTo: activeWindowController()?.window)
    }

    // The fleet activity feed / daily digest panel.
    @objc func showActivityFeed(_ sender: Any?) {
        activityFeed.toggle(relativeTo: activeWindowController()?.window)
    }

    // MARK: - Broadcast

    // The steerable targets a broadcast will reach, each paired with its
    // terminal, in the fleet's needs-you-first order (so the composer count and
    // the send agree). Resolution is the pure `Broadcast.targetIds`: fleet order
    // → hosted-only → the chosen scope.
    func broadcastTargets(scope: Broadcast.Scope) -> [(session: ClaudeSession, terminal: TerminalPaneContent)] {
        let sessions = ClaudeSessionMonitor.shared.sessions
        let hosted = hostedSessionIds()
        let orderedIds = FleetModel.rows(sessions: sessions, hostedIds: hosted).map { $0.id }
        let ids = Broadcast.targetIds(orderedSessionIds: orderedIds, hostedIds: hosted, scope: scope)
        let byId = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { id in
            guard let session = byId[id], let terminal = terminalContent(forSessionId: id) else { return nil }
            return (session, terminal)
        }
    }

    // Opens the composer in broadcast mode aimed at `scope`'s sessions. @-paths
    // complete against the active window's index since the targets may span
    // projects. Beeps when nothing steerable matches.
    func presentBroadcast(scope: Broadcast.Scope) {
        let targets = broadcastTargets(scope: scope)
        guard !targets.isEmpty else { NSSound.beep(); return }
        promptComposer.showBroadcast(
            terminals: targets.map { $0.terminal },
            fileIndex: activeWindowController()?.currentFileIndex(),
            relativeTo: activeWindowController()?.window
        )
    }

    @objc func broadcastToAllSessions(_ sender: Any?) {
        presentBroadcast(scope: .allLive)
    }

    // The background-task monitor. Scoped to the focused
    // terminal pane's shell when there is one, otherwise the whole window's
    // tracked tasks.
    @objc func showBackgroundTasks(_ sender: Any?) {
        guard let controller = activeWindowController() else { NSSound.beep(); return }
        if let shellPid = controller.focusedPane()?.terminalContent?.shellPid, shellPid > 0 {
            controller.openBackgroundTasks(forShellPid: shellPid, title: "Background Tasks")
        } else {
            controller.openBackgroundTasks(forShellPid: 0, title: "Background Tasks")
        }
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

    // Pipe a diff pane's review draft into a chosen session
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

    // Submit the diff tab's review straight to GitHub as a
    // `gh pr review`. One dialog picks the verdict (Approve / Request Changes /
    // Comment) and an optional overall note; the line comments fold
    // into the body via PRReviewComposer. Confirmed before send, posted off the
    // main thread, and the inbox refreshes on success.
    func submitPRReview(from content: DiffPaneContent) {
        guard let pr = content.reviewingPR else { NSSound.beep(); return }
        let comments = content.reviewDraft.comments

        let alert = NSAlert()
        alert.messageText = "Submit review for PR #\(pr.number)"
        let summary = comments.isEmpty ? "no line comments" : "\(comments.count) line comment\(comments.count == 1 ? "" : "s")"
        alert.informativeText = "\(pr.title)\n\nIncludes \(summary). Pick a verdict and add an optional overall note:"

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 92))
        let picker = NSSegmentedControl(labels: PRReviewDecision.allCases.map { $0.label },
                                        trackingMode: .selectOne, target: nil, action: nil)
        picker.selectedSegment = 0
        picker.frame = NSRect(x: 0, y: 64, width: 340, height: 24)
        let note = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 56))
        note.placeholderString = "Overall note (required for Request Changes / Comment)…"
        accessory.addSubview(picker)
        accessory.addSubview(note)
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Submit")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = note
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Segment order matches PRReviewDecision.allCases (approve/request/comment).
        let index = max(0, picker.selectedSegment)
        let decision = PRReviewDecision.allCases[index]
        let body = PRReviewComposer.composeBody(overall: note.stringValue, comments: comments)
        if decision.requiresBody && body.isEmpty {
            let warn = NSAlert()
            warn.messageText = "A “\(decision.label)” review needs a note"
            warn.informativeText = "Add an overall note or at least one line comment, then submit again."
            warn.runModal()
            return
        }

        let root = pr.root, number = pr.number
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak content] in
            let result = GitHubCLI.prReview(root: root, number: number, decision: decision, body: body)
            DispatchQueue.main.async {
                switch result {
                case .success:
                    content?.reviewDraft.clear()
                    content?.reviewChanged()
                    self?.activeWindowController()?.reloadPRInbox()
                case .failure(let error):
                    let a = NSAlert()
                    a.messageText = "Couldn’t submit review for PR #\(number)"
                    a.informativeText = error.message
                    a.alertStyle = .warning
                    a.runModal()
                }
            }
        }
    }

    @objc func submitPRReviewCommand(_ sender: Any?) {
        guard let content = activeWindowController()?.currentDiffContent, content.reviewingPR != nil else {
            NSSound.beep()
            return
        }
        submitPRReview(from: content)
    }

    // Route a machine-feedback event (CI failure, PR review
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

    // MARK: - Live slash-command menu

    // The command menu: pick a session (picker when several are live), then a
    // palette of that session's available slash commands — built-ins plus the
    // discovered custom commands and skills — each injected into its pty.
    @objc func showSlashCommandMenu(_ sender: Any?) {
        withSession(placeholder: "Slash command in session…") { [weak self] session in
            self?.presentSlashCommands(for: session)
        }
    }

    private func presentSlashCommands(for session: ClaudeSession) {
        guard let terminal = terminalContent(forSessionId: session.id) else {
            NSSound.beep()
            return
        }
        let catalog = SlashCommandCatalog.forSession(cwd: session.cwd)
        let project = (session.cwd as NSString?)?.lastPathComponent ?? session.displayName
        paletteFileIndex = nil
        commandPalette.show(
            relativeTo: activeWindowController()?.window,
            commands: catalog.map { command in
                PaletteCommand(title: command.menuTitle, shortcut: command.source.rawValue) { [weak terminal] in
                    guard let terminal else { NSSound.beep(); return }
                    SessionControl.send(text: command.name, to: terminal, submit: true)
                }
            },
            placeholder: "Slash command → \(project)"
        )
    }

    // The context bar action: /compact the focused pane's session
    // directly (no picker) — the keyboard binding behind the title-bar meter tap.
    @objc func compactFocusedSession(_ sender: Any?) {
        guard let pane = activeWindowController()?.focusedPane(), pane.compactContextSession() else {
            NSSound.beep()
            return
        }
    }

    // Runs `body` on the one session, or shows a session-picker palette when
    // several are live. Only sessions whose pty is actually hosted by some
    // pane are offered — the others can't be written to.
    // Cost budget guardrails: the palette route to the
    // per-session "Set Budget…" override (the fleet row's context menu is the
    // other). Picks a hosted session, then hands off to the OverlayPrompt.
    @objc func setSessionBudgetFromPalette(_ sender: Any?) {
        withSession(placeholder: "Set budget for session…") { [weak self] session in
            self?.setBudget(forSessionId: session.id)
        }
    }

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

    // MARK: - Mode control

    // Switch a session to a permission mode by writing Shift+Tab presses into
    // its pty — the palette-side counterpart of the title bar's mode control.
    // Session-scoped (not pane-scoped) so it works even when the session's tab
    // is backgrounded; the visible pane, if any, repaints its control.
    func switchClaudeMode(_ target: ClaudeMode, forSessionId id: String) {
        guard let terminal = terminalContent(forSessionId: id),
              let session = ClaudeSessionMonitor.shared.sessions.first(where: { $0.id == id }) else {
            NSSound.beep()
            return
        }
        let current = ClaudeModeTracker.shared.effectiveMode(for: session)
        let payload = ClaudeModeControl.payload(from: current, to: target)
        if !payload.isEmpty {
            terminal.terminalView.send(txt: payload)
        }
        ClaudeModeTracker.shared.record(target, forSessionId: id)
        terminal.pane?.refreshChrome()
    }

    @objc func setSessionModeAsk(_ sender: Any?) {
        withSession(placeholder: "Set Ask mode in session…") { [weak self] in self?.switchClaudeMode(.ask, forSessionId: $0.id) }
    }

    @objc func setSessionModePlan(_ sender: Any?) {
        withSession(placeholder: "Set Plan mode in session…") { [weak self] in self?.switchClaudeMode(.plan, forSessionId: $0.id) }
    }

    @objc func setSessionModeAgent(_ sender: Any?) {
        withSession(placeholder: "Set Agent mode in session…") { [weak self] in self?.switchClaudeMode(.agent, forSessionId: $0.id) }
    }

    // MARK: - Plan approval

    // Palette: open a session's plan-approval pane. One session opens directly;
    // several go through the picker, exactly like Open Claude Transcript.
    @objc func openPlanForReview(_ sender: Any?) {
        guard let controller = activeWindowController() else { return }
        let sessions = ClaudeSessionMonitor.shared.sessions
        switch sessions.count {
        case 0:
            NSSound.beep()
        case 1:
            controller.openPlanApproval(for: sessions[0])
        default:
            paletteFileIndex = nil
            commandPalette.show(
                relativeTo: controller.window,
                commands: sessions.map { session in
                    let project = (session.cwd as NSString?)?.lastPathComponent ?? ""
                    return PaletteCommand(title: "\(session.displayName) — \(session.state.label) · \(project)", shortcut: nil) { [weak controller] in
                        controller?.openPlanApproval(for: session)
                    }
                },
                placeholder: "Open plan for session…"
            )
        }
    }

    // Dispatch a plan-approval button into the session's pty: the exact hotkey
    // for the matching ExitPlanMode menu option, submitted with a return.
    func dispatchPlanApproval(_ action: PlanApprovalAction, forSessionId id: String) {
        guard let terminal = terminalContent(forSessionId: id) else {
            NSSound.beep()
            return
        }
        SessionControl.send(text: action.ptyPayload, to: terminal, submit: true)
    }

    // MARK: - Set as Goal

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
    // opens in the pane. Driven from the timeline's header.
    func rewindSession(withId id: String) {
        guard let terminal = terminalContent(forSessionId: id) else {
            NSSound.beep()
            return
        }
        SessionControl.send(text: "/rewind", to: terminal, submit: true)
    }
}
