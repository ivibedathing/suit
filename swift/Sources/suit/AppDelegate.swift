import Cocoa

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
    // New Claude Task isolation default (ROADMAP Phase 31): whether the
    // "New Claude Task" prompt's "Isolate in worktree" switch starts on. On
    // reproduces Phase 5's always-a-worktree behavior; off runs claude in the
    // current checkout. The prompt's per-task choice overrides it.
    var taskIsolateByDefault = true
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
    lazy var settingsWindowController = SettingsWindowController(appDelegate: self)
    lazy var commandPalette = CommandPaletteController { [weak self] in
        self?.paletteCommands() ?? []
    }
    lazy var promptComposer = PromptComposerController()
    // Fleet-supervision dashboard (ROADMAP Phase 28): a floating cross-window
    // view of every live Claude session, sorted needs-you-first, with per-row
    // steering routed through the same paths as the palette's session verbs.
    lazy var fleetDashboard: FleetDashboardController = {
        let controller = FleetDashboardController()
        controller.hostedIds = { [weak self] in self?.hostedSessionIds() ?? [] }
        controller.onFocus = { [weak self] id in self?.focusSession(withId: id) }
        controller.onInterrupt = { [weak self] id in self?.performQuickAction(.interrupt, onSessionId: id) }
        controller.onContinue = { [weak self] id in self?.performQuickAction(.continueSession, onSessionId: id) }
        controller.onArchive = { [weak self] id in self?.archiveSession(withId: id) }
        return controller
    }()
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

    // Claude session awareness heartbeat (ROADMAP Phase 4).
    private var sessionRefreshTimer: Timer?
    private var sessionRefreshTick = 0
    var attentionCenter: ClaudeAttentionCenter?

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
        // Start the background-task record watcher up front (ROADMAP Phase 30),
        // so tracked jobs surface even before the first heartbeat.
        _ = BackgroundTaskStore.shared
        sessionRefreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.sessionRefreshTick += 1
            if self.sessionRefreshTick % 10 == 0 {
                ClaudeSessionMonitor.shared.reload()
            } else {
                self.remapClaudeSessions()
            }
            AutopilotEngine.shared.tick()
            // Background-task monitor (ROADMAP Phase 30): a job that crashed
            // without the wrapper's exit trap firing changes no record file, so
            // the same heartbeat re-runs the liveness sweep that catches it.
            BackgroundTaskStore.shared.reload()
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
}
