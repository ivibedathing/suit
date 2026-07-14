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
    // Frost softness (gaussian radius, points). 30 is what the system frost
    // ships with, so the default look is unchanged; 0 = tinted but sharp glass.
    var blurRadius: CGFloat = 30
    let maxBlurRadius: CGFloat = 64
    var backgroundAlpha: CGFloat = 1
    let opacityStep: CGFloat = 0.05
    let minOpacity: CGFloat = 0.05

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
    // Claude API tuning (Settings → Claude API): per-launch Anthropic env
    // overrides (model, effort, thinking budget, caching, …) composed onto the
    // typed `claude` command by ClaudeAPISettings.launchCommand(base:). All
    // defaults = no change to the command line.
    var claudeAPI = ClaudeAPISettings()
    // New Claude Task isolation default: whether the
    // "New Claude Task" prompt's "Isolate in worktree" switch starts on. On
    // reproduces the always-a-worktree behavior; off runs claude in the
    // current checkout. The prompt's per-task choice overrides it.
    var taskIsolateByDefault = true
    // Bell responses (PaneTerminalView.bell): the white pane flash and the
    // Dock-icon bounce while the app is inactive.
    var bellFlashEnabled = true
    var bellDockBounceEnabled = true
    // Claude notification sounds (ClaudeAttentionCenter): play a system sound
    // on the done / needs-input transition while the app is inactive. Each
    // event has its own on/off and chosen NSSound name (see NotificationSounds).
    var taskDoneSoundEnabled = true
    var needsInputSoundEnabled = true
    var taskDoneSoundName = "Glass"
    var needsInputSoundName = "Ping"
    // Set as Goal: prepend a `From <file>:<lines>:` line so
    // the goal carries where the selection came from. Off by default — the
    // selection alone is usually the directive.
    var goalPrependProvenanceEnabled = false
    // rtk output compression: when on, Suit installs a Claude Code PreToolUse
    // hook that runs Bash commands through rtk so their output is compressed
    // before it reaches the context window. Off by default — the hook rewrites
    // the commands Claude runs, so it's opt-in (RtkHook / rtkCompressionChanged).
    var rtkCompressionEnabled = false
    // PostToolUse output filtering: one dispatcher hook + script
    // (suit-posttool-filter.sh) serving two toggles — compress elides giant
    // Read/Grep/Glob/Bash results via updatedToolOutput (the side of a tool
    // call rtk can't reach); dedup (read-once) stubs re-reads of unchanged
    // files. Both off by default — the hook rewrites what Claude reads back,
    // so it's opt-in (PostToolHook / applyPostToolHook).
    var postToolCompressEnabled = false
    var readDedupEnabled = false
    // Token-ignore firewall: denies full-file Reads under the prefixes in a
    // repo's .claude/token-ignore (TokenIgnoreHook, PreToolUse) and hides
    // Grep/Glob results there via the dispatcher's --ignore flag. Off by
    // default like the other token filters.
    var tokenIgnoreEnabled = false
    // Shell helpers (run_silent): launch zsh terminals with the
    // ZDOTDIR shim so suit-shell-extras.zsh loads after the user's own config
    // (ShellInjection). Off by default; applies to new terminals only.
    var shellExtrasEnabled = false
    // Autopilot — the §2.9 config table. The engine reads
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
    // Cost budget guardrails: per-session / per-task spend
    // ceilings in dollars (0 = no ceiling), whether crossing one auto-interrupts
    // the run (Esc over the pty) or only warns, and the per-session "Set Budget…"
    // overrides keyed by session id. The guard reads these live each heartbeat.
    var budgetSessionCap = 0.0                // $, default per-session ceiling
    var budgetTaskCap = 0.0                   // $, default per-task (worktree) ceiling
    var budgetAutoInterrupt = false           // trip → Esc (else warn only)
    var budgetPerSession: [String: Double] = [:]  // session-id → override $
    // The heartbeat-driven monitor; created lazily so its closures capture self.
    lazy var budgetGuard: BudgetGuard = BudgetGuard(
        caps: { [weak self] in self?.budgetCaps() ?? BudgetCaps() },
        autoInterrupt: { [weak self] in self?.budgetAutoInterrupt ?? false },
        onTrip: { [weak self] trip in self?.handleBudgetTrip(trip) }
    )
    // Auto-/compact guardrails: when a session idles past the
    // context threshold, type `/compact <instructions>` into it — reclaim
    // context on the user's terms before Claude Code's own late, generic
    // auto-compact has to. Off by default (it types into the pty, so opt-in);
    // the instructions replace Claude Code's default summarization focus.
    var autoCompactEnabled = false
    var autoCompactThreshold = 70             // %, context_pct that trips
    var autoCompactInstructions =
        "Preserve the current task, recent decisions, exact file paths, and next steps."
    lazy var compactGuard: CompactGuard = CompactGuard(
        enabled: { [weak self] in self?.autoCompactEnabled ?? false },
        threshold: { [weak self] in self?.autoCompactThreshold ?? 70 },
        hosted: { [weak self] id in self?.terminalContent(forSessionId: id) != nil },
        onTrip: { [weak self] trip in self?.handleCompactTrip(trip) }
    )
    // Cache hit-rate meter: rolling prompt-cache hit rate per
    // session from the transcript's usage blocks; one notification per
    // collapse (CacheStats / CacheStatsGuard). The fleet dashboard reads its
    // per-session rate for the row metrics.
    lazy var cacheGuard: CacheStatsGuard = CacheStatsGuard(
        onAlert: { [weak self] alert in self?.handleCacheAlert(alert) }
    )
    lazy var settingsWindowController = SettingsWindowController(appDelegate: self)
    lazy var commandPalette = CommandPaletteController { [weak self] in
        self?.paletteCommands() ?? []
    }
    lazy var promptComposer = PromptComposerController()
    // Fleet-supervision dashboard: a floating cross-window
    // view of every live Claude session, sorted needs-you-first, with per-row
    // steering routed through the same paths as the palette's session verbs.
    // Autopilot dashboard: the multi-run supervision panel — one row per active
    // autopilot instance with its status and per-repo controls (focus / pause /
    // resume / skip / retry / log / stop).
    lazy var autopilotDashboard: AutopilotDashboardController = {
        let controller = AutopilotDashboardController()
        controller.onFocusRunTab = { [weak self] engine in self?.focusAutopilotRunTab(engine: engine) }
        controller.onOpenLog = { [weak self] engine in self?.openAutopilotLog(engine: engine) }
        controller.onStartHere = { [weak self] in self?.startAutopilotHere() }
        return controller
    }()

    lazy var fleetDashboard: FleetDashboardController = {
        let controller = FleetDashboardController()
        controller.hostedIds = { [weak self] in self?.hostedSessionIds() ?? [] }
        controller.onFocus = { [weak self] id in self?.focusSession(withId: id) }
        controller.onInterrupt = { [weak self] id in self?.performQuickAction(.interrupt, onSessionId: id) }
        controller.onContinue = { [weak self] id in self?.performQuickAction(.continueSession, onSessionId: id) }
        controller.onArchive = { [weak self] id in self?.archiveSession(withId: id) }
        controller.onBroadcast = { [weak self] scope in self?.presentBroadcast(scope: scope) }
        controller.onSetBudget = { [weak self] id in self?.setBudget(forSessionId: id) }
        controller.cacheRate = { [weak self] id in self?.cacheGuard.hitRatePct(forSession: id) }
        return controller
    }()
    // Fleet activity feed / daily digest: a floating
    // cross-window timeline of what *moved* — sessions finishing, PRs/CI,
    // Autopilot runs — with a "what happened today" recap. The recorder is the
    // producer side (session transitions + the once-daily digest); the panel is
    // the reader. A row click routes to the thing it names.
    lazy var activityFeed: ActivityFeedController = {
        let controller = ActivityFeedController()
        controller.onFocusSession = { [weak self] id in self?.focusSession(withId: id) }
        controller.onOpenPR = { url in
            guard let link = URL(string: url) else { NSSound.beep(); return }
            NSWorkspace.shared.open(link)
        }
        controller.onOpenAutopilotLog = { [weak self] in self?.openAutopilotLog() }
        return controller
    }()
    lazy var activityRecorder: ActivityRecorder = ActivityRecorder { [weak self] digest in
        self?.attentionCenter?.postAutopilotEvent(
            title: "What happened today",
            body: digest.summary,
            identifier: "activity-digest"
        )
    }
    // Cross-transcript search: a floating "Search
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

    // Claude session awareness heartbeat.
    private var sessionRefreshTimer: Timer?
    private var sessionRefreshTick = 0
    var attentionCenter: ClaudeAttentionCenter?

    // GitHub release update check: notification when a newer tag ships, the
    // App menu's manual Check for Updates…, and the download offer alert.
    var updateChecker: UpdateChecker?

    // The session a goal last went to, so a repeat gesture defaults to it
    // (sorted first in the picker) instead of re-choosing from scratch. Session
    // ids are ephemeral, so this is deliberately not persisted.
    var lastGoalSessionId: String?

    // The index feeding the palette while it's in file mode; nil whenever the
    // palette is in command mode. Weak is safe (FileIndex caches per root for
    // the app's lifetime) and keeps this from ever owning an index.
    weak var paletteFileIndex: FileIndex?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Committed dark: the design artifact is one
        // deliberate dark world, not a system-theme chameleon. Pinning the
        // app-wide appearance keeps every system control — menus, alerts,
        // scrollers, panels — consistent with the Theme chrome.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Load the persisted theme selection into Theme.current before any
        // window is built, so the app opens already skinned (no flash of the
        // default palette). Safe to run this early — ThemeStore depends only on
        // Theme.swift and the filesystem.
        ThemeStore.shared.applySelectedThemeAtLaunch()
        NotificationCenter.default.addObserver(
            self, selector: #selector(fileIndexUpdated(_:)),
            name: FileIndex.didUpdate, object: nil
        )
        loadSettings()
        buildMenu()
        // Push-to-talk dictation: hold 🌐 (Fn/Globe) to speak into the focused
        // pane (see AppDelegate+Dictation / Dictation.swift).
        installDictationHotkey()

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

        // Claude session awareness: remap sessions onto panes
        // whenever the session files change, plus a slow heartbeat — pids and
        // pane cwds drift without any file event, and session staleness only
        // shows up by re-reading. Every 10th tick re-reads the files themselves.
        NotificationCenter.default.addObserver(
            self, selector: #selector(claudeSessionsUpdated(_:)),
            name: ClaudeSessionMonitor.didUpdate, object: nil
        )
        // Start the background-task record watcher up front,
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
            AutopilotManager.shared.tick()
            // Background-task monitor: a job that crashed
            // without the wrapper's exit trap firing changes no record file, so
            // the same heartbeat re-runs the liveness sweep that catches it.
            BackgroundTaskStore.shared.reload()
            // Fleet activity feed: deliver yesterday's digest
            // once per calendar day, on the first heartbeat past local midnight.
            self.activityRecorder.maybePostDailyDigest()
            // Cost budget guardrails: check each live
            // session's cost against its cap and trip (warn / interrupt) once
            // on a crossing.
            self.budgetGuard.tick(sessions: ClaudeSessionMonitor.shared.sessions)
            // Auto-/compact guardrails: /compact a session that
            // idles past the context threshold, once per crossing.
            self.compactGuard.tick(sessions: ClaudeSessionMonitor.shared.sessions)
            // Cache hit-rate meter: refresh each session's rolling
            // prompt-cache hit rate from its transcript tail and alert once
            // per collapse (misses bill input near full price).
            self.cacheGuard.tick(sessions: ClaudeSessionMonitor.shared.sessions)
        }
        attentionCenter = ClaudeAttentionCenter { [weak self] sessionId in
            self?.focusSession(withId: sessionId)
        }
        // Fleet activity feed: start recording session
        // transitions now, so the feed captures movement even before it's first
        // opened. The recorder is lazily created here (its first didUpdate seeds
        // the baseline without recording the already-live sessions).
        _ = activityRecorder
        // Autopilot notification click-through (§2.11): a live run tab is the
        // interesting surface, otherwise the log — the footer row's routing.
        attentionCenter?.onAutopilotEvent = { [weak self] _ in
            guard let self else { return }
            if AutopilotManager.shared.allEngines.contains(where: { $0.workerTabId != nil }) {
                self.focusAutopilotRunTab()
            } else {
                self.openAutopilotLog()
            }
        }
        // Activity digest click-through: open the feed.
        attentionCenter?.onActivityEvent = { [weak self] in
            self?.activityFeed.show(relativeTo: self?.activeWindowController()?.window)
        }
        // Budget-trip click-through: focus the pane whose run
        // blew its cap.
        attentionCenter?.onBudgetEvent = { [weak self] sessionId in
            self?.focusSession(withId: sessionId)
        }

        // Update check: daily GitHub-release poll; a hit posts a notification
        // whose click presents the download offer.
        updateChecker = UpdateChecker { [weak self] title, body in
            self?.attentionCenter?.postUpdateEvent(title: title, body: body)
        }
        attentionCenter?.onUpdateEvent = { [weak self] in
            self?.updateChecker?.presentPendingUpdate()
        }
        updateChecker?.startAutomaticChecks()

        // Autopilot: the engine hangs off the same 3 s
        // timer (tick added in the closure above) and needs the session
        // monitor, which the observers above have already instantiated.
        AutopilotManager.shared.appDelegate = self
        AutopilotManager.shared.adoptOnLaunch()
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
        // Likewise flush any editable viewer's pending autosave, so
        // the sub-second debounce window never loses edits across a quit — the
        // file on disk is then current and restoration just reloads it.
        for controller in windowControllers {
            for tab in controller.store.tabs {
                controller.flushDirtyViewer(tab)
            }
        }
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
