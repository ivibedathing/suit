import Cocoa

enum SplitOrientation {
    case vertical   // side-by-side, divider is vertical
    case horizontal // stacked, divider is horizontal
}

// A container that sizes every subview to its bounds. Used as the window's
// top-level content view (blur effect view + the sidebar split) and as the
// pane tree's host inside that sidebar split.
final class RootContainerView: NSView {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        for subview in subviews {
            subview.frame = bounds
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    // Every open window; each owns its own TabStore (the browser-style strip)
    // and pane tree independently. Native macOS window tabbing is disabled —
    // the strip is the one tab system, and ⌘T opens a tab there.
    private var windowControllers: [TerminalWindowController] = []

    // These drive each pane's own background alpha (not window.alphaValue), so the
    // terminal background becomes see-through/blurred while text stays fully opaque.
    // Shared across every window/tab, so kept here rather than per-controller.
    var blurEnabled = false
    var backgroundAlpha: CGFloat = 1
    private let opacityStep: CGFloat = 0.05
    private let minOpacity: CGFloat = 0.3

    // Same bounds as the settings window's font-size stepper.
    private let minFontSize: CGFloat = 8
    private let maxFontSize: CGFloat = 36

    var currentFont = TerminalView.FontSet.defaultFont
    lazy var currentTextColor = PaneTerminalView(frame: .zero).nativeForegroundColor
    // Whether file-viewer panes soft-wrap long lines (View ▸ Word Wrap);
    // terminals are unaffected — the shell owns their line discipline.
    var wordWrapEnabled = true
    // Global defaults surfaced in the settings window (Cmd-,). The background
    // color seeds new panes and repaints existing ones when changed; the
    // per-pane right-click menu can still override it pane-by-pane afterwards.
    var defaultTerminalBackground: NSColor = Theme.terminalBg
    var cursorStyle: CursorStyle = .blinkBlock
    // Exec'd by every new terminal tab (always with -l -i, see
    // TerminalPaneContent.start); only ever set to an executable path.
    var shellPath = "/bin/zsh"
    // Extra arguments appended to `claude` by the quick-access launchers
    // (the strip's ✦ button, ⌃⌘C, the palette) — e.g. "--continue" or
    // "--model opus". A raw string handed to the shell, not validated.
    var claudeSessionArgs = ""
    // Bell responses (PaneTerminalView.bell): the white pane flash and the
    // Dock-icon bounce while the app is inactive.
    var bellFlashEnabled = true
    var bellDockBounceEnabled = true
    // Set as Goal (ROADMAP Phase 18): prepend a `From <file>:<lines>:` line so
    // the goal carries where the selection came from. Off by default — the
    // selection alone is usually the directive.
    var goalPrependProvenanceEnabled = false
    // Autopilot (ROADMAP Phase 32) — the §2.9 config table. The engine reads
    // these live through its weak appDelegate reference; the Settings window's
    // Autopilot section writes them through autopilotXChanged(...).
    var autopilotEnabled = false
    var autopilotProjectRoot = ""             // git repo containing ROADMAP.md
    var autopilotMode: AutopilotBudgetMode = .paceToReset
    var autopilotNightStart = 22              // hour, night-shift window start
    var autopilotNightEnd = 7                 // hour, exclusive; wraps midnight
    var autopilotFiveHourCeiling = 85         // %, hard gate in all modes
    var autopilotWeeklyCeiling = 95           // %, maxOut/nightShift ceiling
    var autopilotWeeklyHardStop = 98          // %, hard gate in all modes
    var autopilotPaceTargetPct = 100          // %, where the pace line ends
    var autopilotMaxGateAttempts = 3          // build/review attempts per phase
    var autopilotStallMinutes = 60            // needs-input stall before blocking
    var autopilotExtraArgs = ""               // appended to the worker's claude
    var autopilotReviewModel = ""             // review gate --model; empty = default
    var autopilotPreventSleep = true          // hold .idleSystemSleepDisabled across runs
    private lazy var settingsWindowController = SettingsWindowController(appDelegate: self)
    private lazy var commandPalette = CommandPaletteController { [weak self] in
        self?.paletteCommands() ?? []
    }
    private lazy var promptComposer = PromptComposerController()
    // Cross-transcript search (ROADMAP Phase 20): a floating "Search
    // Transcripts…" panel; a picked result opens that session's transcript pane
    // in the active window, anchored to the matching line.
    private lazy var transcriptSearch: TranscriptSearchController = {
        let controller = TranscriptSearchController()
        controller.onOpen = { [weak self] result in
            self?.activeWindowController()?.openTranscript(
                path: result.transcriptPath,
                cwd: result.session.cwd,
                title: result.session.displayName,
                line: result.lineNumber
            )
        }
        return controller
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Committed dark (ROADMAP Phase 11): the design artifact is one
        // deliberate dark world, not a system-theme chameleon. Pinning the
        // app-wide appearance keeps every system control — menus, alerts,
        // scrollers, panels — consistent with the Theme chrome.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NotificationCenter.default.addObserver(
            self, selector: #selector(fileIndexUpdated(_:)),
            name: FileIndex.didUpdate, object: nil
        )
        loadSettings()
        buildMenu()

        // Reopen with the last quit's layout when one was saved (state
        // restoration); otherwise the classic single shell in the last cwd.
        if let saved = SavedAppState.load() {
            for windowState in saved.windows {
                let controller = TerminalWindowController(
                    appDelegate: self,
                    startDirectory: savedWorkingDirectory(),
                    restoring: windowState
                )
                windowControllers.append(controller)
                controller.window.makeKeyAndOrderFront(nil)
            }
        }
        if windowControllers.isEmpty {
            let controller = openWindow(startDirectory: savedWorkingDirectory())
            controller.window.makeKeyAndOrderFront(nil)
        }

        NSApp.activate(ignoringOtherApps: true)

        // Claude session awareness (ROADMAP Phase 4): remap sessions onto panes
        // whenever the session files change, plus a slow heartbeat — pids and
        // pane cwds drift without any file event, and session staleness only
        // shows up by re-reading. Every 10th tick re-reads the files themselves.
        NotificationCenter.default.addObserver(
            self, selector: #selector(claudeSessionsUpdated(_:)),
            name: ClaudeSessionMonitor.didUpdate, object: nil
        )
        sessionRefreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.sessionRefreshTick += 1
            if self.sessionRefreshTick % 10 == 0 {
                ClaudeSessionMonitor.shared.reload()
            } else {
                self.remapClaudeSessions()
            }
            AutopilotEngine.shared.tick()
        }
        attentionCenter = ClaudeAttentionCenter { [weak self] sessionId in
            self?.focusSession(withId: sessionId)
        }
        // Autopilot notification click-through (§2.11): a live run tab is the
        // interesting surface, otherwise the log — the footer row's routing.
        attentionCenter?.onAutopilotEvent = { [weak self] _ in
            guard let self else { return }
            if AutopilotEngine.shared.workerTabId != nil {
                self.focusAutopilotRunTab()
            } else {
                self.openAutopilotLog()
            }
        }

        // Autopilot (ROADMAP Phase 32): the engine hangs off the same 3 s
        // timer (tick added in the closure above) and needs the session
        // monitor, which the observers above have already instantiated.
        AutopilotEngine.shared.appDelegate = self
        AutopilotEngine.shared.adoptOnLaunch()
    }

    // MARK: - Claude sessions

    private var sessionRefreshTimer: Timer?
    private var sessionRefreshTick = 0
    private var attentionCenter: ClaudeAttentionCenter?

    // Notification click-through: find the tab running the session, whichever
    // window it's in.
    func focusSession(withId id: String) {
        guard let session = ClaudeSessionMonitor.shared.sessions.first(where: { $0.id == id }) else { return }
        let controller = windowControllers.first { $0.runsClaudeSession(withId: id) }
        (controller ?? activeWindowController())?.focusPane(runningSession: session)
    }

    // MARK: - Cross-window tab plumbing (browser-tab model)

    // Resolves a dragged tab id to its window and tab, across every window.
    func controllerAndTab(withId id: String) -> (TerminalWindowController, Tab)? {
        for controller in windowControllers {
            if let tab = controller.store.tab(withId: id) {
                return (controller, tab)
            }
        }
        return nil
    }

    // A tab dragged out of every Suit window (or "Move Tab to New Window"):
    // it becomes its own window at the drop point, process and state intact.
    func tearOffTab(withId id: String, at screenPoint: NSPoint) {
        guard let (source, tab) = controllerAndTab(withId: id) else { return }
        // A window's only tab torn off would just recreate the same window.
        guard source.store.tabs.count > 1 else { return }
        // The new window's project (sidebar, Cmd-P) should be the tab's own.
        let startDirectory = tab.content.workingDirectory ?? savedWorkingDirectory()
        source.release(tab)
        let controller = TerminalWindowController(
            appDelegate: self,
            startDirectory: startDirectory,
            adopting: tab
        )
        windowControllers.append(controller)
        controller.window.setFrameTopLeftPoint(screenPoint)
        controller.window.makeKeyAndOrderFront(nil)
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

    // The session a goal last went to, so a repeat gesture defaults to it
    // (sorted first in the picker) instead of re-choosing from scratch. Session
    // ids are ephemeral, so this is deliberately not persisted.
    private var lastGoalSessionId: String?

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

    // The prompt library (ROADMAP Phase 8): ~/.suit/prompts/*.md surfaced
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

    @objc private func claudeSessionsUpdated(_ note: Notification) {
        remapClaudeSessions()
    }

    private func remapClaudeSessions() {
        let assigner = ClaudeSessionMonitor.shared.makeAssigner()
        for controller in windowControllers {
            controller.refreshClaudeSessions(assigner: assigner)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // Cmd-Q never goes through windowShouldClose, so quitting gets its own
    // confirmation if any pane in any window/tab still has a foreground process.
    // Closing the last window doesn't double-prompt: its windowWillClose has
    // already removed its controller by the time termination is evaluated.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let names = windowControllers.flatMap { $0.busyPaneProcessNames() }
        guard !names.isEmpty else { return .terminateNow }
        let confirmed = TerminalWindowController.confirmTermination(
            messageText: "Quit Suit?",
            confirmTitle: "Quit",
            processNames: names
        )
        return confirmed ? .terminateNow : .terminateCancel
    }

    // Closing a window (or Cmd-Q) goes straight to termination without running
    // closePane's cleanup, so this is the only reliable place to catch the
    // shells' cwds while their processes are still alive — both the legacy
    // last-cwd fallback and the full layout snapshot (state restoration).
    func applicationWillTerminate(_ notification: Notification) {
        // A debounced notes save may still be pending; the timer dies with us.
        NotesStore.shared.flush()
        SavedAppState(windows: windowControllers.map { $0.captureState() }).save()
        guard let pane = activeWindowController()?.focusedPane(),
              let cwd = pane.workingDirectory else { return }
        UserDefaults.standard.set(cwd, forKey: "lastWorkingDirectory")
    }

    private func savedWorkingDirectory() -> String {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "lastWorkingDirectory"),
           FileManager.default.fileExists(atPath: saved) {
            return saved
        }
        return NSHomeDirectory()
    }

    // MARK: - Windows & tabs

    @discardableResult
    private func openWindow(startDirectory: String) -> TerminalWindowController {
        let controller = TerminalWindowController(appDelegate: self, startDirectory: startDirectory)
        windowControllers.append(controller)
        return controller
    }

    // isMainWindow, not just isKeyWindow: while the command palette's panel is
    // key (and in the moment right after it orders out), no terminal window is
    // key, but the one the user was working in is still main — without this,
    // palette commands would land on an arbitrary window when several are open.
    private func activeWindowController() -> TerminalWindowController? {
        windowControllers.first(where: { $0.window.isKeyWindow })
            ?? windowControllers.first(where: { $0.window.isMainWindow })
            ?? windowControllers.last
    }

    // A new window/tab starts wherever the pane it was spawned from currently is,
    // matching how splitting a pane already behaves.
    private func startDirectoryForNewWindowOrTab() -> String {
        guard let pane = activeWindowController()?.focusedPane() else { return savedWorkingDirectory() }
        return pane.workingDirectory ?? savedWorkingDirectory()
    }

    @objc func newWindow(_ sender: Any?) {
        let controller = openWindow(startDirectory: startDirectoryForNewWindowOrTab())
        controller.window.makeKeyAndOrderFront(nil)
    }

    // ⌘T: a new terminal tab in the key window's strip (browser rule); with
    // no window open it makes one.
    @objc func newTab(_ sender: Any?) {
        guard let current = activeWindowController() else {
            newWindow(sender)
            return
        }
        current.newTerminalTab()
    }

    // ⌃⌘C / the strip's ✦: a new terminal tab that immediately runs claude
    // (with the settings-configured default arguments).
    @objc func newClaudeSession(_ sender: Any?) {
        guard let current = activeWindowController() else {
            newWindow(sender)
            activeWindowController()?.newClaudeSessionTab()
            return
        }
        current.newClaudeSessionTab()
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        activeWindowController()?.reopenClosedTab()
    }

    func windowControllerDidClose(_ controller: TerminalWindowController) {
        windowControllers.removeAll { $0 === controller }
    }

    // Whether closing `controller` closes the whole app: it's the only window/tab
    // left, and applicationShouldTerminateAfterLastWindowClosed turns that into a
    // quit. Lets Close Pane (Cmd-W) warn before it quietly quits Suit.
    func isLastWindowController(_ controller: TerminalWindowController) -> Bool {
        windowControllers.count == 1 && windowControllers.first === controller
    }

    // MARK: - Tab & pane actions (dispatched to whichever window is key)

    @objc func renameTab(_ sender: Any?) {
        activeWindowController()?.renameActiveTab()
    }

    // ⌘D: Split Screen with a fresh terminal tab (in the focused pane's cwd).
    // Splitting with an *existing* tab stays available via the strip's context
    // menu and the palette's last-used-tab / picker entries.
    @objc func splitScreen(_ sender: Any?) {
        activeWindowController()?.splitScreenWithNewTerminal()
    }

    // ⇧⌘D: like ⌘D but always stacks the fresh terminal below (horizontal split),
    // regardless of the pane's shape.
    @objc func splitScreenHorizontally(_ sender: Any?) {
        activeWindowController()?.splitScreenWithNewTerminal(forcedOrientation: .horizontal)
    }

    @objc func splitScreenWithLastUsedTab(_ sender: Any?) {
        activeWindowController()?.splitScreenWithMRUTab()
    }

    // Palette: pick which background tab to split the screen with.
    func splitScreenWithPicker() {
        guard let controller = activeWindowController() else {
            NSSound.beep()
            return
        }
        let tabs = controller.backgroundTabs()
        guard !tabs.isEmpty else {
            NSSound.beep()
            return
        }
        let commands = tabs.map { tab in
            PaletteCommand(title: tab.title, shortcut: "split screen") { [weak controller, weak tab] in
                guard let controller, let tab else { return }
                controller.splitScreen(with: tab)
            }
        }
        commandPalette.show(relativeTo: controller.window, commands: commands, placeholder: "Split screen with…")
    }

    // ⌃⌘M ("Unsplit All"): back to one viewport; displaced tabs stay open in
    // the strip.
    @objc func mergeAllPanes(_ sender: Any?) {
        activeWindowController()?.mergeAllPanes()
    }

    // ⌘W: close the active tab; the window's last tab closes the window.
    @objc func closeTab(_ sender: Any?) {
        activeWindowController()?.closeActiveTab()
    }

    // ⌥⌘W ("Unsplit"): dissolve the focused viewport; its tab stays in the strip.
    @objc func closePane(_ sender: Any?) {
        activeWindowController()?.closeFocusedPaneKeepTab()
    }

    // ⌘⇧] / ⌘⇧[: strip-order tab cycling.
    @objc func nextTab(_ sender: Any?) {
        activeWindowController()?.activateAdjacentTab(1)
    }

    @objc func previousTab(_ sender: Any?) {
        activeWindowController()?.activateAdjacentTab(-1)
    }

    // ⌃Tab / ⌃⇧Tab: the MRU switcher overlay.
    @objc func cycleRecentTabs(_ sender: Any?) {
        activeWindowController()?.cycleMRUTab(forward: true)
    }

    @objc func cycleRecentTabsBack(_ sender: Any?) {
        activeWindowController()?.cycleMRUTab(forward: false)
    }

    // ⌘1..9 (menu tag = tab number, ⌘9 = last tab, browser rule).
    @objc func goToTab(_ sender: NSMenuItem) {
        activeWindowController()?.activateTab(number: sender.tag)
    }

    // ⌥⌘ arrows (menu tag encodes the direction).
    @objc func focusPaneDirection(_ sender: NSMenuItem) {
        let directions: [PaneDirection] = [.left, .right, .up, .down]
        guard directions.indices.contains(sender.tag) else { return }
        activeWindowController()?.focusPane(direction: directions[sender.tag])
    }

    // Palette: keep the preview tab's file open / pin the active tab.
    @objc func keepPreviewTab(_ sender: Any?) {
        activeWindowController()?.keepActiveTab()
    }

    @objc func togglePinTab(_ sender: Any?) {
        activeWindowController()?.togglePinActiveTab()
    }

    // The palette shown with every open tab in the key window — fuzzy-jump to
    // anything open, visible or backgrounded.
    @objc func showTabPalette(_ sender: Any?) {
        guard let controller = activeWindowController() else {
            NSSound.beep()
            return
        }
        commandPalette.show(relativeTo: controller.window, commands: controller.tabPaletteCommands(), placeholder: "Go to tab…")
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleWordWrap(_:)) {
            menuItem.state = wordWrapEnabled ? .on : .off
            return true
        }
        guard menuItem.action == #selector(goToTab(_:)) else { return true }
        let count = activeWindowController()?.store.tabs.count ?? 0
        // ⌘9 = last tab, enabled whenever anything is open at all.
        return menuItem.tag >= 9 ? count > 0 : menuItem.tag <= count
    }

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

    // Sidebar folder pinning (ROADMAP Phase 9).
    @objc func selectSidebarFolder(_ sender: Any?) {
        activeWindowController()?.selectSidebarFolder()
    }

    @objc func showNotes(_ sender: Any?) {
        activeWindowController()?.showNotes()
    }

    @objc func showGit(_ sender: Any?) {
        activeWindowController()?.showGit()
    }

    // ROADMAP Phase 22 — file:line bookmarks.
    @objc func showBookmarks(_ sender: Any?) {
        activeWindowController()?.showBookmarks()
    }

    // Routed through the responder chain to the focused file viewer (like
    // Go to Line); a beep when nothing focused is a viewer.
    @objc func toggleBookmark(_ sender: Any?) {
        if !NSApp.sendAction(#selector(ViewerTextView.toggleBookmark(_:)), to: nil, from: sender) {
            NSSound.beep()
        }
    }

    // "New task" (ROADMAP Phase 5): prompt for a name, then worktree + claude
    // pane via the window controller.
    @objc func newClaudeTask(_ sender: Any?) {
        guard let controller = activeWindowController() else {
            NSSound.beep()
            return
        }
        OverlayPromptController.shared.ask(
            caption: "New Claude Task — worktree + claude session",
            placeholder: "task name",
            over: controller.window
        ) { [weak controller] name in
            guard !name.isEmpty else { return }
            controller?.startClaudeTask(named: name)
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

    // Palette / View menu: the cross-transcript search panel (Phase 20).
    @objc func searchTranscripts(_ sender: Any?) {
        transcriptSearch.show(relativeTo: activeWindowController()?.window)
    }

    // Palette: open a session's checkpoint-timeline pane (ROADMAP Phase 25).
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

    // Injects /rewind into a session's pty so Claude's native rewind picker
    // opens in the pane (ROADMAP Phase 25). Driven from the timeline's header.
    func rewindSession(withId id: String) {
        guard let terminal = terminalContent(forSessionId: id) else {
            NSSound.beep()
            return
        }
        SessionControl.send(text: "/rewind", to: terminal, submit: true)
    }

    // MARK: - Fuzzy file opener (Cmd-P)

    // The index feeding the palette while it's in file mode; nil whenever the
    // palette is in command mode. Weak is safe (FileIndex caches per root for
    // the app's lifetime) and keeps this from ever owning an index.
    private weak var paletteFileIndex: FileIndex?

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
    @objc private func fileIndexUpdated(_ note: Notification) {
        guard let index = note.object as? FileIndex,
              index === paletteFileIndex,
              commandPalette.isVisible,
              let controller = activeWindowController() else { return }
        commandPalette.refreshCommands(fileCommands(index: index, controller: controller))
    }

    // Every menu action, reachable by typing. Rebuilt on each palette open, so
    // entries can reflect current state without any invalidation plumbing.
    private func paletteCommands() -> [PaletteCommand] {
        [
            PaletteCommand(title: "Open File…", shortcut: "⌘P") { [weak self] in self?.openQuickly(nil) },
            PaletteCommand(title: "Search in Project…", shortcut: "⇧⌘F") { [weak self] in self?.searchInProject(nil) },
            PaletteCommand(title: "Show Git Diff", shortcut: "⌃⌘D") { [weak self] in self?.showGitDiff(nil) },
            PaletteCommand(title: "Review Changes (n/p walk files, o opens, c comments)", shortcut: nil) { [weak self] in self?.showGitDiff(nil) },
            PaletteCommand(title: "Send Review to Session…", shortcut: nil) { [weak self] in self?.sendReviewToSession(nil) },
            PaletteCommand(title: "New Claude Session", shortcut: "⌃⌘C") { [weak self] in self?.newClaudeSession(nil) },
            PaletteCommand(title: "New Claude Task…", shortcut: "⌃⌘T") { [weak self] in self?.newClaudeTask(nil) },
            PaletteCommand(title: "Open Claude Transcript…", shortcut: nil) { [weak self] in self?.openClaudeTranscript(nil) },
            PaletteCommand(title: "Open Checkpoint Timeline…", shortcut: nil) { [weak self] in self?.openCheckpointTimeline(nil) },
            PaletteCommand(title: "Search Transcripts…", shortcut: nil) { [weak self] in self?.searchTranscripts(nil) },
            PaletteCommand(title: "Claude: Prompt Session…", shortcut: nil) { [weak self] in self?.promptClaudeSession(nil) },
            PaletteCommand(title: "Claude: Continue Session", shortcut: nil) { [weak self] in self?.continueClaudeSession(nil) },
            PaletteCommand(title: "Claude: Compact Session (/compact)", shortcut: nil) { [weak self] in self?.compactClaudeSession(nil) },
            PaletteCommand(title: "Claude: Interrupt Session (Esc)", shortcut: nil) { [weak self] in self?.interruptClaudeSession(nil) },
            PaletteCommand(title: "Set Selection as Claude Goal", shortcut: nil) { [weak self] in self?.setSelectionAsGoalFromFocused(nil) },
            PaletteCommand(title: "Go to Line…", shortcut: "⌘L") { NSApp.sendAction(#selector(ViewerTextView.goToLine(_:)), to: nil, from: nil) },
            PaletteCommand(title: "Toggle Blame", shortcut: "⌃⌘B") { NSApp.sendAction(#selector(ViewerTextView.toggleBlame(_:)), to: nil, from: nil) },
            PaletteCommand(title: "Show File History", shortcut: nil) { NSApp.sendAction(#selector(ViewerTextView.showFileHistory(_:)), to: nil, from: nil) },
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
            PaletteCommand(title: "Toggle Bookmark", shortcut: "⇧⌘L") { [weak self] in self?.toggleBookmark(nil) },
            PaletteCommand(title: "Increase Font Size", shortcut: "⌘=") { [weak self] in self?.increaseFontSize(nil) },
            PaletteCommand(title: "Decrease Font Size", shortcut: "⌘-") { [weak self] in self?.decreaseFontSize(nil) },
            PaletteCommand(title: "Increase Font Size (All Panes)", shortcut: "⇧⌘=") { [weak self] in self?.increaseAllFontSizes(nil) },
            PaletteCommand(title: "Decrease Font Size (All Panes)", shortcut: "⇧⌘-") { [weak self] in self?.decreaseAllFontSizes(nil) },
            PaletteCommand(title: "Increase Opacity", shortcut: "⌘]") { [weak self] in self?.increaseOpacity(nil) },
            PaletteCommand(title: "Decrease Opacity", shortcut: "⌘[") { [weak self] in self?.decreaseOpacity(nil) },
            PaletteCommand(title: "Toggle Background Blur", shortcut: "⇧⌘B") { [weak self] in self?.toggleBlur(nil) },
            PaletteCommand(title: "Toggle Word Wrap", shortcut: nil) { [weak self] in self?.toggleWordWrap(nil) },
            PaletteCommand(title: "Settings…", shortcut: "⌘,") { [weak self] in self?.showSettings(nil) },
            PaletteCommand(title: "Install Claude Code Integration…", shortcut: nil) { [weak self] in self?.installClaudeIntegration(nil) },
        ] + autopilotPaletteCommands() + sshHostCommands() + promptLibraryCommands()
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

    // MARK: - Opacity & blur

    @objc func increaseOpacity(_ sender: Any?) {
        opacityChanged(min(1, backgroundAlpha + opacityStep))
    }

    @objc func decreaseOpacity(_ sender: Any?) {
        opacityChanged(max(minOpacity, backgroundAlpha - opacityStep))
    }

    @objc func toggleBlur(_ sender: Any?) {
        blurChanged(!blurEnabled)
    }

    func opacityChanged(_ value: CGFloat) {
        backgroundAlpha = value
        for controller in windowControllers {
            controller.applyTransparency(alpha: backgroundAlpha, blurEnabled: blurEnabled)
        }
        saveSettings()
    }

    func blurChanged(_ enabled: Bool) {
        blurEnabled = enabled
        for controller in windowControllers {
            controller.applyTransparency(alpha: backgroundAlpha, blurEnabled: blurEnabled)
        }
        saveSettings()
    }

    // MARK: - Word wrap (file viewers)

    @objc func toggleWordWrap(_ sender: Any?) {
        wordWrapChanged(!wordWrapEnabled)
    }

    func wordWrapChanged(_ wrap: Bool) {
        wordWrapEnabled = wrap
        for controller in windowControllers {
            controller.applyWordWrap(wordWrapEnabled)
        }
        saveSettings()
    }

    // MARK: - Settings

    @objc func showSettings(_ sender: Any?) {
        settingsWindowController.show()
    }

    func beginChoosingFont() {
        NSFontManager.shared.target = self
        NSFontManager.shared.setSelectedFont(currentFont, isMultiple: false)
        NSFontManager.shared.orderFrontFontPanel(self)
    }

    // The exact selector NSFontManager sends up the responder chain when the user
    // picks a font in the font panel.
    @objc func changeFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        currentFont = sender.convert(currentFont)
        for controller in windowControllers {
            controller.applyFont(currentFont)
        }
        settingsWindowController.updateFontLabel(currentFont)
        saveSettings()
    }

    // Cmd-=/Cmd--: size just the focused pane. Cmd-Shift-=/Cmd-Shift--: every
    // pane steps relative to its own size (so per-pane overrides keep their
    // offset) and the global default moves with them for future panes.
    @objc func increaseFontSize(_ sender: Any?) {
        adjustFocusedPaneFontSize(by: 1)
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        adjustFocusedPaneFontSize(by: -1)
    }

    @objc func increaseAllFontSizes(_ sender: Any?) {
        adjustAllPaneFontSizes(by: 1)
    }

    @objc func decreaseAllFontSizes(_ sender: Any?) {
        adjustAllPaneFontSizes(by: -1)
    }

    private func adjustFocusedPaneFontSize(by delta: CGFloat) {
        guard let pane = activeWindowController()?.focusedPane() else {
            NSSound.beep()
            return
        }
        adjustPaneFontSize(pane, by: delta)
    }

    private func adjustAllPaneFontSizes(by delta: CGFloat) {
        currentFont = NSFontManager.shared.convert(currentFont, toSize: clampedFontSize(currentFont.pointSize + delta))
        for controller in windowControllers {
            for pane in controller.panes {
                adjustPaneFontSize(pane, by: delta)
            }
        }
        settingsWindowController.updateFontLabel(currentFont)
        saveSettings()
    }

    private func adjustPaneFontSize(_ pane: Pane, by delta: CGFloat) {
        let font = pane.appliedFont ?? currentFont
        pane.setFont(NSFontManager.shared.convert(font, toSize: clampedFontSize(font.pointSize + delta)))
    }

    private func clampedFontSize(_ size: CGFloat) -> CGFloat {
        min(maxFontSize, max(minFontSize, size))
    }

    func fontSizeChanged(_ size: CGFloat) {
        currentFont = NSFontManager.shared.convert(currentFont, toSize: size)
        for controller in windowControllers {
            controller.applyFont(currentFont)
        }
        settingsWindowController.updateFontLabel(currentFont)
        saveSettings()
    }

    func textColorChanged(_ color: NSColor) {
        currentTextColor = color
        for controller in windowControllers {
            controller.applyTextColor(color)
        }
        saveSettings()
    }

    // Like textColorChanged, the new default repaints every pane — including
    // ones with a per-pane menu override, which the user can re-pick.
    func defaultBackgroundChanged(_ color: NSColor) {
        defaultTerminalBackground = color
        for controller in windowControllers {
            controller.applyDefaultBackground(color)
        }
        saveSettings()
    }

    func cursorStyleChanged(_ style: CursorStyle) {
        cursorStyle = style
        for controller in windowControllers {
            controller.applyCursorStyle(style)
        }
        saveSettings()
    }

    // Only accepts executable paths (a bad shell would exec-fail every new
    // tab); returns whether the value was taken so the settings field can
    // revert. Running shells are untouched — this is a new-tab default.
    @discardableResult
    func shellPathChanged(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: expanded) else { return false }
        shellPath = expanded
        saveSettings()
        return true
    }

    func claudeSessionArgsChanged(_ args: String) {
        claudeSessionArgs = args.trimmingCharacters(in: .whitespaces)
        saveSettings()
    }

    func bellFlashChanged(_ enabled: Bool) {
        bellFlashEnabled = enabled
        saveSettings()
    }

    func bellDockBounceChanged(_ enabled: Bool) {
        bellDockBounceEnabled = enabled
        saveSettings()
    }

    func goalProvenanceChanged(_ enabled: Bool) {
        goalPrependProvenanceEnabled = enabled
        saveSettings()
    }

    // MARK: - Autopilot (ROADMAP Phase 32)

    // Enabling runs the §2.3 enable-time checks: the hook/statusline scripts
    // are Autopilot's nervous system (refuse without them), and gh gets an
    // install hint (missing gh is an expected, recoverable blocked state).
    // Returns whether the value was taken so the settings checkbox can revert.
    @discardableResult
    func autopilotEnabledChanged(_ enabled: Bool) -> Bool {
        if enabled, !autopilotEnabled {
            guard ClaudeIntegration.status() == .installed else {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Install the Claude Code integration first"
                alert.informativeText = "Autopilot watches its worker sessions through the session files and usage snapshot written by Suit's statusline and hook scripts — without them it is blind. Run “Install Claude Code Integration…” from the app menu, then enable Autopilot."
                alert.runModal()
                return false
            }
            if !GitHubCLI.isAvailable {
                let alert = NSAlert()
                alert.messageText = "The gh CLI isn’t installed"
                alert.informativeText = "Autopilot uses GitHub’s gh to open and merge PRs (brew install gh, then gh auth login). Autopilot will stay blocked until gh is available."
                alert.runModal()
            }
        }
        autopilotEnabled = enabled
        saveSettings()
        AutopilotStore.shared.log(enabled ? "Autopilot enabled" : "Autopilot disabled")
        AutopilotEngine.shared.settingsChanged()
        return true
    }

    // Only accepts a git repository that contains ROADMAP.md (the steering
    // file the engine parses); clearing the path is always allowed. Returns
    // whether the value was taken so the settings field can revert.
    @discardableResult
    func autopilotProjectRootChanged(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        if !expanded.isEmpty {
            guard FileIndex.gitRoot(of: expanded) != nil,
                  FileManager.default.fileExists(atPath: expanded + "/ROADMAP.md") else { return false }
        }
        autopilotProjectRoot = expanded
        saveSettings()
        AutopilotEngine.shared.settingsChanged()
        return true
    }

    func autopilotModeChanged(_ mode: AutopilotBudgetMode) {
        autopilotMode = mode
        saveSettings()
        AutopilotEngine.shared.settingsChanged()
    }

    func autopilotNightStartChanged(_ hour: Int) {
        autopilotNightStart = min(23, max(0, hour))
        saveSettings()
        AutopilotEngine.shared.settingsChanged()
    }

    func autopilotNightEndChanged(_ hour: Int) {
        autopilotNightEnd = min(23, max(0, hour))
        saveSettings()
        AutopilotEngine.shared.settingsChanged()
    }

    func autopilotFiveHourCeilingChanged(_ pct: Int) {
        autopilotFiveHourCeiling = min(100, max(0, pct))
        saveSettings()
        AutopilotEngine.shared.settingsChanged()
    }

    func autopilotWeeklyCeilingChanged(_ pct: Int) {
        autopilotWeeklyCeiling = min(100, max(0, pct))
        saveSettings()
        AutopilotEngine.shared.settingsChanged()
    }

    func autopilotWeeklyHardStopChanged(_ pct: Int) {
        autopilotWeeklyHardStop = min(100, max(0, pct))
        saveSettings()
        AutopilotEngine.shared.settingsChanged()
    }

    func autopilotPaceTargetChanged(_ pct: Int) {
        autopilotPaceTargetPct = min(100, max(1, pct))
        saveSettings()
        AutopilotEngine.shared.settingsChanged()
    }

    func autopilotMaxGateAttemptsChanged(_ attempts: Int) {
        autopilotMaxGateAttempts = min(9, max(1, attempts))
        saveSettings()
        AutopilotEngine.shared.settingsChanged()
    }

    func autopilotStallMinutesChanged(_ minutes: Int) {
        autopilotStallMinutes = min(24 * 60, max(5, minutes))
        saveSettings()
        AutopilotEngine.shared.settingsChanged()
    }

    // Newline-free (the launch path types this into zsh as one line, §2.5).
    func autopilotExtraArgsChanged(_ args: String) {
        autopilotExtraArgs = args
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        saveSettings()
        AutopilotEngine.shared.settingsChanged()
    }

    func autopilotReviewModelChanged(_ model: String) {
        autopilotReviewModel = model.trimmingCharacters(in: .whitespaces)
        saveSettings()
        AutopilotEngine.shared.settingsChanged()
    }

    func autopilotPreventSleepChanged(_ enabled: Bool) {
        autopilotPreventSleep = enabled
        saveSettings()
        AutopilotEngine.shared.settingsChanged()
    }

    // Footer row / palette "Open Run Tab" / notification click-through: focus
    // the worker tab wherever it lives. The one deliberate focus steal in the
    // Autopilot flow — the user explicitly asked for the run.
    func focusAutopilotRunTab() {
        guard let id = AutopilotEngine.shared.workerTabId,
              let (controller, tab) = controllerAndTab(withId: id) else {
            AutopilotStore.shared.log("Open Run Tab: no run tab is open")
            NSSound.beep()
            return
        }
        controller.activate(tab)
        controller.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // The engine's tab factory (§2.5 launch stage): the run tab opens in the
    // active window without stealing focus. Nil only when no window exists.
    func openAutopilotRunTab(directory: String, title: String, continueSession: Bool) -> Tab? {
        activeWindowController()?.openAutopilotRunTab(
            directory: directory, title: title, continueSession: continueSession
        )
    }

    // The engine's notification hook (§2.11): merged / blocked / idle events
    // ride the attention center's existing UNUserNotificationCenter plumbing
    // (it already owns the delegate and the no-bundle-identity guard).
    func postAutopilotNotification(title: String, body: String, identifier: String) {
        attentionCenter?.postAutopilotEvent(title: title, body: body, identifier: identifier)
    }

    // "Autopilot: Show Log" / footer click while idle or blocked: the log is a
    // regular file, so it opens as a first-class viewer tab.
    func openAutopilotLog() {
        let path = AutopilotStore.shared.logFileURL.path
        if !FileManager.default.fileExists(atPath: path) {
            AutopilotStore.shared.log("log created")
        }
        guard let controller = activeWindowController() else {
            NSSound.beep()
            return
        }
        controller.openFile(atPath: path, line: nil)
    }

    // The §2.10 palette entries. Rebuilt per palette invocation (like the rest
    // of paletteCommands), so titles reflect the engine's current state. The
    // run-control verbs only appear while Autopilot is enabled.
    private func autopilotPaletteCommands() -> [PaletteCommand] {
        var commands = [
            PaletteCommand(title: autopilotEnabled ? "Autopilot: Disable" : "Autopilot: Enable", shortcut: nil) { [weak self] in
                guard let self else { return }
                self.autopilotEnabledChanged(!self.autopilotEnabled)
            },
            PaletteCommand(title: "Autopilot: Show Log", shortcut: nil) { [weak self] in
                self?.openAutopilotLog()
            },
        ]
        guard autopilotEnabled else { return commands }
        // §2.9: Retry appears only while blocked — it clears the block and
        // re-adopts the kept run (or re-runs preflight when none exists).
        if case .blocked = AutopilotEngine.shared.state {
            commands.append(PaletteCommand(title: "Autopilot: Retry", shortcut: nil) {
                AutopilotEngine.shared.retryAfterBlock()
            })
        }
        let paused = AutopilotEngine.shared.state == .paused
        commands.append(contentsOf: [
            PaletteCommand(title: "Autopilot: Run Next Phase Now", shortcut: nil) {
                AutopilotEngine.shared.runNextPhaseNow()
            },
            PaletteCommand(title: paused ? "Autopilot: Resume" : "Autopilot: Pause After Current Run", shortcut: nil) {
                if paused {
                    AutopilotEngine.shared.resume()
                } else {
                    AutopilotEngine.shared.pauseAfterCurrentRun()
                }
            },
            PaletteCommand(title: "Autopilot: Skip Current Phase", shortcut: nil) {
                AutopilotEngine.shared.skipCurrentPhase()
            },
            PaletteCommand(title: "Autopilot: Open Run Tab", shortcut: nil) { [weak self] in
                self?.focusAutopilotRunTab()
            },
        ])
        return commands
    }

    private func loadSettings() {
        let defaults = UserDefaults.standard
        if let fontName = defaults.string(forKey: "fontName") {
            let size = defaults.double(forKey: "fontSize")
            currentFont = NSFont(name: fontName, size: size > 0 ? CGFloat(size) : currentFont.pointSize) ?? currentFont
        }
        if defaults.object(forKey: "textColorR") != nil {
            currentTextColor = NSColor(
                calibratedRed: CGFloat(defaults.double(forKey: "textColorR")),
                green: CGFloat(defaults.double(forKey: "textColorG")),
                blue: CGFloat(defaults.double(forKey: "textColorB")),
                alpha: CGFloat(defaults.double(forKey: "textColorA"))
            )
        }
        if defaults.object(forKey: "backgroundAlpha") != nil {
            backgroundAlpha = CGFloat(defaults.double(forKey: "backgroundAlpha"))
        }
        blurEnabled = defaults.bool(forKey: "blurEnabled")
        if defaults.object(forKey: "wordWrapEnabled") != nil {
            wordWrapEnabled = defaults.bool(forKey: "wordWrapEnabled")
        }
        if defaults.object(forKey: "defaultBgR") != nil {
            defaultTerminalBackground = NSColor(
                calibratedRed: CGFloat(defaults.double(forKey: "defaultBgR")),
                green: CGFloat(defaults.double(forKey: "defaultBgG")),
                blue: CGFloat(defaults.double(forKey: "defaultBgB")),
                alpha: 1
            )
        }
        if let raw = defaults.string(forKey: "cursorStyle"), let style = CursorStyle.from(string: raw) {
            cursorStyle = style
        }
        // Re-validate at load: the shell may have been uninstalled since.
        if let shell = defaults.string(forKey: "shellPath"),
           FileManager.default.isExecutableFile(atPath: shell) {
            shellPath = shell
        }
        if defaults.object(forKey: "bellFlashEnabled") != nil {
            bellFlashEnabled = defaults.bool(forKey: "bellFlashEnabled")
        }
        if defaults.object(forKey: "bellDockBounceEnabled") != nil {
            bellDockBounceEnabled = defaults.bool(forKey: "bellDockBounceEnabled")
        }
        if defaults.object(forKey: "goalPrependProvenanceEnabled") != nil {
            goalPrependProvenanceEnabled = defaults.bool(forKey: "goalPrependProvenanceEnabled")
        }
        if let args = defaults.string(forKey: "claudeSessionArgs") {
            claudeSessionArgs = args
        }
        // Autopilot (§2.9): bare camelCase keys, one per table row.
        autopilotEnabled = defaults.bool(forKey: "autopilotEnabled")
        if let root = defaults.string(forKey: "autopilotProjectRoot") {
            autopilotProjectRoot = root
        }
        if let raw = defaults.string(forKey: "autopilotMode"),
           let mode = AutopilotBudgetMode(rawValue: raw) {
            autopilotMode = mode
        }
        if defaults.object(forKey: "autopilotNightStart") != nil {
            autopilotNightStart = defaults.integer(forKey: "autopilotNightStart")
        }
        if defaults.object(forKey: "autopilotNightEnd") != nil {
            autopilotNightEnd = defaults.integer(forKey: "autopilotNightEnd")
        }
        if defaults.object(forKey: "autopilotFiveHourCeiling") != nil {
            autopilotFiveHourCeiling = defaults.integer(forKey: "autopilotFiveHourCeiling")
        }
        if defaults.object(forKey: "autopilotWeeklyCeiling") != nil {
            autopilotWeeklyCeiling = defaults.integer(forKey: "autopilotWeeklyCeiling")
        }
        if defaults.object(forKey: "autopilotWeeklyHardStop") != nil {
            autopilotWeeklyHardStop = defaults.integer(forKey: "autopilotWeeklyHardStop")
        }
        if defaults.object(forKey: "autopilotPaceTargetPct") != nil {
            autopilotPaceTargetPct = defaults.integer(forKey: "autopilotPaceTargetPct")
        }
        if defaults.object(forKey: "autopilotMaxGateAttempts") != nil {
            autopilotMaxGateAttempts = defaults.integer(forKey: "autopilotMaxGateAttempts")
        }
        if defaults.object(forKey: "autopilotStallMinutes") != nil {
            autopilotStallMinutes = defaults.integer(forKey: "autopilotStallMinutes")
        }
        if let args = defaults.string(forKey: "autopilotExtraArgs") {
            autopilotExtraArgs = args
        }
        if let model = defaults.string(forKey: "autopilotReviewModel") {
            autopilotReviewModel = model
        }
        if defaults.object(forKey: "autopilotPreventSleep") != nil {
            autopilotPreventSleep = defaults.bool(forKey: "autopilotPreventSleep")
        }
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(currentFont.fontName, forKey: "fontName")
        defaults.set(Double(currentFont.pointSize), forKey: "fontSize")
        let color = currentTextColor.usingColorSpace(.deviceRGB) ?? currentTextColor
        defaults.set(Double(color.redComponent), forKey: "textColorR")
        defaults.set(Double(color.greenComponent), forKey: "textColorG")
        defaults.set(Double(color.blueComponent), forKey: "textColorB")
        defaults.set(Double(color.alphaComponent), forKey: "textColorA")
        defaults.set(Double(backgroundAlpha), forKey: "backgroundAlpha")
        defaults.set(blurEnabled, forKey: "blurEnabled")
        defaults.set(wordWrapEnabled, forKey: "wordWrapEnabled")
        let background = defaultTerminalBackground.usingColorSpace(.deviceRGB) ?? defaultTerminalBackground
        defaults.set(Double(background.redComponent), forKey: "defaultBgR")
        defaults.set(Double(background.greenComponent), forKey: "defaultBgG")
        defaults.set(Double(background.blueComponent), forKey: "defaultBgB")
        defaults.set(cursorStyle.persistedName, forKey: "cursorStyle")
        defaults.set(shellPath, forKey: "shellPath")
        defaults.set(bellFlashEnabled, forKey: "bellFlashEnabled")
        defaults.set(bellDockBounceEnabled, forKey: "bellDockBounceEnabled")
        defaults.set(goalPrependProvenanceEnabled, forKey: "goalPrependProvenanceEnabled")
        defaults.set(claudeSessionArgs, forKey: "claudeSessionArgs")
        defaults.set(autopilotEnabled, forKey: "autopilotEnabled")
        defaults.set(autopilotProjectRoot, forKey: "autopilotProjectRoot")
        defaults.set(autopilotMode.rawValue, forKey: "autopilotMode")
        defaults.set(autopilotNightStart, forKey: "autopilotNightStart")
        defaults.set(autopilotNightEnd, forKey: "autopilotNightEnd")
        defaults.set(autopilotFiveHourCeiling, forKey: "autopilotFiveHourCeiling")
        defaults.set(autopilotWeeklyCeiling, forKey: "autopilotWeeklyCeiling")
        defaults.set(autopilotWeeklyHardStop, forKey: "autopilotWeeklyHardStop")
        defaults.set(autopilotPaceTargetPct, forKey: "autopilotPaceTargetPct")
        defaults.set(autopilotMaxGateAttempts, forKey: "autopilotMaxGateAttempts")
        defaults.set(autopilotStallMinutes, forKey: "autopilotStallMinutes")
        defaults.set(autopilotExtraArgs, forKey: "autopilotExtraArgs")
        defaults.set(autopilotReviewModel, forKey: "autopilotReviewModel")
        defaults.set(autopilotPreventSleep, forKey: "autopilotPreventSleep")
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        let aboutItem = appMenu.addItem(withTitle: "About Suit", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        aboutItem.target = NSApp
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        let integrationItem = appMenu.addItem(withTitle: "Install Claude Code Integration…", action: #selector(installClaudeIntegration(_:)), keyEquivalent: "")
        integrationItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Suit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        let openQuicklyItem = fileMenu.addItem(withTitle: "Open Quickly…", action: #selector(openQuickly(_:)), keyEquivalent: "p")
        openQuicklyItem.target = self
        fileMenuItem.submenu = fileMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(PaneTerminalView.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(PaneTerminalView.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())

        // These route through the responder chain to whichever pane is focused, the same
        // way Copy/Paste above do. TerminalView already implements the find bar (overlay,
        // case/regex/whole-word options, next/prev) behind performFindPanelAction(_:) —
        // see SwiftTerm's MacTerminalView.swift — these are just the standard macOS Find
        // menu items/shortcuts/tags (NSFindPanelAction) that trigger it.
        let findItem = editMenu.addItem(withTitle: "Find…", action: #selector(TerminalView.performFindPanelAction(_:)), keyEquivalent: "f")
        findItem.tag = Int(NSFindPanelAction.showFindPanel.rawValue)

        let findNextItem = editMenu.addItem(withTitle: "Find Next", action: #selector(TerminalView.performFindPanelAction(_:)), keyEquivalent: "g")
        findNextItem.tag = Int(NSFindPanelAction.next.rawValue)

        let findPreviousItem = editMenu.addItem(withTitle: "Find Previous", action: #selector(TerminalView.performFindPanelAction(_:)), keyEquivalent: "g")
        findPreviousItem.keyEquivalentModifierMask = [.command, .shift]
        findPreviousItem.tag = Int(NSFindPanelAction.previous.rawValue)

        let useSelectionItem = editMenu.addItem(withTitle: "Use Selection for Find", action: #selector(TerminalView.performFindPanelAction(_:)), keyEquivalent: "e")
        useSelectionItem.tag = Int(NSFindPanelAction.setFindString.rawValue)

        let projectSearchItem = editMenu.addItem(withTitle: "Search in Project…", action: #selector(searchInProject(_:)), keyEquivalent: "f")
        projectSearchItem.keyEquivalentModifierMask = [.command, .shift]
        projectSearchItem.target = self

        editMenu.addItem(.separator())

        // Responder-chain routed: only enabled while a file viewer is focused.
        // Cmd-L rather than the roadmap's Cmd-G, which macOS convention (and
        // the Find items above) already reserve for Find Next.
        editMenu.addItem(withTitle: "Go to Line…", action: #selector(ViewerTextView.goToLine(_:)), keyEquivalent: "l")

        // ⇧⌘L: bookmark the caret's line (ROADMAP Phase 22), routed to the
        // focused viewer through the responder chain.
        let toggleBookmarkItem = editMenu.addItem(withTitle: "Toggle Bookmark", action: #selector(toggleBookmark(_:)), keyEquivalent: "l")
        toggleBookmarkItem.keyEquivalentModifierMask = [.command, .shift]

        editMenuItem.submenu = editMenu

        // The Tabs menu (browser-tab model): one strip per window owns every
        // tab; these commands operate on it.
        let tabMenuItem = NSMenuItem()
        mainMenu.addItem(tabMenuItem)
        let tabMenu = NSMenu(title: "Tabs")

        let newTabItem = tabMenu.addItem(withTitle: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "t")
        newTabItem.target = self

        let reopenTabItem = tabMenu.addItem(withTitle: "Reopen Closed Tab", action: #selector(reopenClosedTab(_:)), keyEquivalent: "t")
        reopenTabItem.keyEquivalentModifierMask = [.command, .shift]
        reopenTabItem.target = self

        tabMenu.addItem(.separator())

        // ⌘W closes the active tab; the window's last tab closes the window.
        let closeTabItem = tabMenu.addItem(withTitle: "Close Tab", action: #selector(closeTab(_:)), keyEquivalent: "w")
        closeTabItem.target = self

        let closePaneItem = tabMenu.addItem(withTitle: "Unsplit (Keep Tab)", action: #selector(closePane(_:)), keyEquivalent: "w")
        closePaneItem.keyEquivalentModifierMask = [.command, .option]
        closePaneItem.target = self

        let renameTabItem = tabMenu.addItem(withTitle: "Rename Tab…", action: #selector(renameTab(_:)), keyEquivalent: "")
        renameTabItem.target = self

        tabMenu.addItem(.separator())

        let nextTabItem = tabMenu.addItem(withTitle: "Next Tab", action: #selector(nextTab(_:)), keyEquivalent: "]")
        nextTabItem.keyEquivalentModifierMask = [.command, .shift]
        nextTabItem.target = self

        let previousTabItem = tabMenu.addItem(withTitle: "Previous Tab", action: #selector(previousTab(_:)), keyEquivalent: "[")
        previousTabItem.keyEquivalentModifierMask = [.command, .shift]
        previousTabItem.target = self

        // ⌃Tab cycles most-recently-used with the switcher overlay (hold ⌃ to
        // pick from the list, tap to toggle between the last two).
        let cycleItem = tabMenu.addItem(withTitle: "Cycle Recent Tabs", action: #selector(cycleRecentTabs(_:)), keyEquivalent: "\t")
        cycleItem.keyEquivalentModifierMask = [.control]
        cycleItem.target = self

        let cycleBackItem = tabMenu.addItem(withTitle: "Cycle Recent Tabs (Back)", action: #selector(cycleRecentTabsBack(_:)), keyEquivalent: "\t")
        cycleBackItem.keyEquivalentModifierMask = [.control, .shift]
        cycleBackItem.target = self

        // ⌘1..9 addresses strip tabs directly; ⌘9 is the last tab (browser rule).
        let goToTabItem = tabMenu.addItem(withTitle: "Go to Tab", action: nil, keyEquivalent: "")
        let goToTabMenu = NSMenu(title: "Go to Tab")
        for i in 1...8 {
            let item = goToTabMenu.addItem(withTitle: "Tab \(i)", action: #selector(goToTab(_:)), keyEquivalent: "\(i)")
            item.target = self
            item.tag = i
        }
        let lastTabItem = goToTabMenu.addItem(withTitle: "Last Tab", action: #selector(goToTab(_:)), keyEquivalent: "9")
        lastTabItem.target = self
        lastTabItem.tag = 9
        goToTabItem.submenu = goToTabMenu

        tabMenuItem.submenu = tabMenu

        // The Screen menu (Phase 13): the main screen shows one tab; splitting
        // it is a tab operation (strip right-click ▸ Split Screen, or drag a
        // tab to an edge), so only unsplit and focus movement live here.
        let paneMenuItem = NSMenuItem()
        mainMenu.addItem(paneMenuItem)
        let paneMenu = NSMenu(title: "Screen")

        // ⌘D: split with a fresh shell; the strip's right-click ▸ Split Screen
        // and the menu's last-used-tab entry cover splitting with existing tabs.
        let splitScreenItem = paneMenu.addItem(withTitle: "Split Screen with New Terminal", action: #selector(splitScreen(_:)), keyEquivalent: "d")
        splitScreenItem.target = self

        let splitScreenHorizontalItem = paneMenu.addItem(withTitle: "Split Screen Horizontally", action: #selector(splitScreenHorizontally(_:)), keyEquivalent: "d")
        splitScreenHorizontalItem.keyEquivalentModifierMask = [.command, .shift]
        splitScreenHorizontalItem.target = self

        let splitScreenMRUItem = paneMenu.addItem(withTitle: "Split Screen with Last Used Tab", action: #selector(splitScreenWithLastUsedTab(_:)), keyEquivalent: "")
        splitScreenMRUItem.target = self

        let mergeItem = paneMenu.addItem(withTitle: "Unsplit All", action: #selector(mergeAllPanes(_:)), keyEquivalent: "m")
        mergeItem.keyEquivalentModifierMask = [.command, .control]
        mergeItem.target = self

        paneMenu.addItem(.separator())

        // ⌥⌘ arrows: directional split focus (tags index PaneDirection).
        let arrows: [(String, String)] = [
            ("Focus Split Left", String(UnicodeScalar(NSLeftArrowFunctionKey)!)),
            ("Focus Split Right", String(UnicodeScalar(NSRightArrowFunctionKey)!)),
            ("Focus Split Above", String(UnicodeScalar(NSUpArrowFunctionKey)!)),
            ("Focus Split Below", String(UnicodeScalar(NSDownArrowFunctionKey)!)),
        ]
        for (tag, (title, key)) in arrows.enumerated() {
            let item = paneMenu.addItem(withTitle: title, action: #selector(focusPaneDirection(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = [.command, .option]
            item.target = self
            item.tag = tag
        }

        paneMenuItem.submenu = paneMenu

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")

        let commandPaletteItem = viewMenu.addItem(withTitle: "Command Palette…", action: #selector(showCommandPalette(_:)), keyEquivalent: "k")
        commandPaletteItem.target = self

        let toggleSidebarItem = viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar(_:)), keyEquivalent: "b")
        toggleSidebarItem.target = self

        // Ctrl-Cmd-D: Cmd-D/Cmd-Shift-D are the split commands.
        let gitDiffItem = viewMenu.addItem(withTitle: "Show Git Diff", action: #selector(showGitDiff(_:)), keyEquivalent: "d")
        gitDiffItem.keyEquivalentModifierMask = [.command, .control]
        gitDiffItem.target = self

        let newSessionItem = viewMenu.addItem(withTitle: "New Claude Session", action: #selector(newClaudeSession(_:)), keyEquivalent: "c")
        newSessionItem.keyEquivalentModifierMask = [.command, .control]
        newSessionItem.target = self

        let newTaskItem = viewMenu.addItem(withTitle: "New Claude Task…", action: #selector(newClaudeTask(_:)), keyEquivalent: "t")
        newTaskItem.keyEquivalentModifierMask = [.command, .control]
        newTaskItem.target = self

        let searchTranscriptsItem = viewMenu.addItem(withTitle: "Search Transcripts…", action: #selector(searchTranscripts(_:)), keyEquivalent: "f")
        searchTranscriptsItem.keyEquivalentModifierMask = [.command, .control]
        searchTranscriptsItem.target = self

        viewMenu.addItem(.separator())

        // "=" rather than "+" so plain Cmd-= works without holding Shift; the
        // all-panes variants use the shifted characters ("+", "_") — AppKit's
        // way of spelling Cmd-Shift-= / Cmd-Shift-- as key equivalents.
        let increaseFontItem = viewMenu.addItem(withTitle: "Increase Font Size", action: #selector(increaseFontSize(_:)), keyEquivalent: "=")
        increaseFontItem.target = self

        let decreaseFontItem = viewMenu.addItem(withTitle: "Decrease Font Size", action: #selector(decreaseFontSize(_:)), keyEquivalent: "-")
        decreaseFontItem.target = self

        let increaseAllFontItem = viewMenu.addItem(withTitle: "Increase Font Size (All Panes)", action: #selector(increaseAllFontSizes(_:)), keyEquivalent: "+")
        increaseAllFontItem.target = self

        let decreaseAllFontItem = viewMenu.addItem(withTitle: "Decrease Font Size (All Panes)", action: #selector(decreaseAllFontSizes(_:)), keyEquivalent: "_")
        decreaseAllFontItem.target = self

        let wordWrapItem = viewMenu.addItem(withTitle: "Word Wrap", action: #selector(toggleWordWrap(_:)), keyEquivalent: "")
        wordWrapItem.target = self

        // Blame gutter + file history (ROADMAP Phase 17) — responder-routed to
        // the focused viewer, so both auto-disable when no viewer is focused.
        let toggleBlameItem = viewMenu.addItem(withTitle: "Toggle Blame", action: #selector(ViewerTextView.toggleBlame(_:)), keyEquivalent: "b")
        toggleBlameItem.keyEquivalentModifierMask = [.command, .control]

        viewMenu.addItem(withTitle: "Show File History", action: #selector(ViewerTextView.showFileHistory(_:)), keyEquivalent: "")

        viewMenu.addItem(.separator())

        let increaseOpacityItem = viewMenu.addItem(withTitle: "Increase Opacity", action: #selector(increaseOpacity(_:)), keyEquivalent: "]")
        increaseOpacityItem.target = self

        let decreaseOpacityItem = viewMenu.addItem(withTitle: "Decrease Opacity", action: #selector(decreaseOpacity(_:)), keyEquivalent: "[")
        decreaseOpacityItem.target = self

        let toggleBlurItem = viewMenu.addItem(withTitle: "Toggle Background Blur", action: #selector(toggleBlur(_:)), keyEquivalent: "b")
        toggleBlurItem.keyEquivalentModifierMask = [.command, .shift]
        toggleBlurItem.target = self

        viewMenuItem.submenu = viewMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")

        let newWindowItem = windowMenu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        newWindowItem.target = self

        windowMenuItem.submenu = windowMenu
        // AppKit appends the open-window list to this menu on its own once it's
        // registered as the app's Window menu. (Native window-tab commands
        // don't appear — window.tabbingMode is .disallowed; the strip is the
        // one tab system.)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}

// The inverse of SwiftTerm's CursorStyle.from(string:), for UserDefaults.
extension CursorStyle {
    var persistedName: String {
        switch self {
        case .blinkBlock: return "blinkBlock"
        case .steadyBlock: return "steadyBlock"
        case .blinkUnderline: return "blinkUnderline"
        case .steadyUnderline: return "steadyUnderline"
        case .blinkBar: return "blinkBar"
        case .steadyBar: return "steadyBar"
        }
    }
}
