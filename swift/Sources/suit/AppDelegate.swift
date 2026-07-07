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
    var windowControllers: [TerminalWindowController] = []

    // These drive each pane's own background alpha (not window.alphaValue), so the
    // terminal background becomes see-through/blurred while text stays fully opaque.
    // Shared across every window/tab, so kept here rather than per-controller.
    var blurEnabled = false
    var backgroundAlpha: CGFloat = 1
    let opacityStep: CGFloat = 0.05
    let minOpacity: CGFloat = 0.3

    // Same bounds as the settings window's font-size stepper.
    let minFontSize: CGFloat = 8
    let maxFontSize: CGFloat = 36

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
    lazy var settingsWindowController = SettingsWindowController(appDelegate: self)
    lazy var commandPalette = CommandPaletteController { [weak self] in
        self?.paletteCommands() ?? []
    }
    lazy var promptComposer = PromptComposerController()
    // Cross-transcript search (ROADMAP Phase 20): a floating "Search
    // Transcripts…" panel; a picked result opens that session's transcript pane
    // in the active window, anchored to the matching line.
    lazy var transcriptSearch: TranscriptSearchController = {
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

    // MARK: - Claude session bookkeeping (see AppDelegate+ClaudeSessions.swift)

    private var sessionRefreshTimer: Timer?
    private var sessionRefreshTick = 0
    private var attentionCenter: ClaudeAttentionCenter?

    // The session a goal last went to, so a repeat gesture defaults to it
    // (sorted first in the picker) instead of re-choosing from scratch. Session
    // ids are ephemeral, so this is deliberately not persisted.
    var lastGoalSessionId: String?

    // The index feeding the palette while it's in file mode; nil whenever the
    // palette is in command mode. Weak is safe (FileIndex caches per root for
    // the app's lifetime) and keeps this from ever owning an index.
    weak var paletteFileIndex: FileIndex?

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
        }
        attentionCenter = ClaudeAttentionCenter { [weak self] sessionId in
            self?.focusSession(withId: sessionId)
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

    func savedWorkingDirectory() -> String {
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
    func activeWindowController() -> TerminalWindowController? {
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
}
