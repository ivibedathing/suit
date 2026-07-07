import Cocoa

// Owns one OS-level window and everything under it: the browser-style tab
// strip (TabStripView) fed by the window's TabStore, the NSSplitView tree of
// panes (viewports displaying one tab each), and the panes themselves.
//
// The tab model (browser-tabs rebuild): the strip owns every tab — terminal,
// viewer, diff, transcript. Panes display a subset; clicking a background
// tab shows it in the focused pane, clicking a visible one focuses its pane.
// Native macOS window tabs are gone — ⌘T opens a tab in the strip.
final class TerminalWindowController: NSObject, NSWindowDelegate, NSSplitViewDelegate, PaneHost {
    let window: NSWindow
    unowned let appDelegate: AppDelegate

    // Every tab in this window, in strip order. Panes only ever display tabs
    // from this store.
    let store = TabStore()
    var strip: TabStripView!
    let tabSwitcher = TabSwitcherController()

    private var rootContainer: WindowRootView!
    var effectView: NSVisualEffectView!

    // Left rail (Files / Notes) and the split that puts it
    // beside the pane tree. The pane tree lives in its own filling container
    // rather than directly in the root, so tree-surgery replaceSubview calls
    // never have to know about the sidebar split around them.
    var sidebarSplit: NSSplitView!
    var sidebar: SidebarView!
    var paneTreeHost: RootContainerView!

    // Tracks whichever view (a PaneContainerView or a nested NSSplitView) is
    // currently the top of the pane tree, since paneTreeHost's subview slot
    // can't itself serve as that marker.
    var paneTreeRoot: NSView!

    // The viewports. Tabs are owned by the store; panes are owned here.
    var panes: [Pane] = []

    // The project this window is looking at — feeds the Files sidebar and the
    // Cmd-P fuzzy opener. Starts at the window's start directory's project and
    // follows wherever Cmd-P last resolved (see currentFileIndex()).
    var projectIndex: FileIndex!

    // Below this, a pane is too small to be usable, so further splits are refused.
    let minPaneWidth: CGFloat = 200
    let minPaneHeight: CGFloat = 100

    // Splits built during a state restore, with the divider fraction each
    // should end up at once the window has its real size — and the viewer
    // scroll positions to apply only after those dividers have settled the
    // final wrap widths (scrolling first would land on the wrong line).
    var pendingDividerFractions: [(NSSplitView, Double)] = []
    // Deferred scroll/zoom restores, run after the window reaches its real size
    // (viewer line, markdown fraction, image zoom, PDF page — ROADMAP Phase 19).
    var pendingScrollRestores: [() -> Void] = []

    // The pane the user last worked in, so tab actions still mean "the tab I
    // was just using" while focus sits in the sidebar or a palette — but a
    // window with no such pane must NOT fall back to an arbitrary one (⌘W
    // would close the wrong tab).
    weak var lastFocusedPane: Pane?

    private var firstResponderObservation: NSKeyValueObservation?

    // The explicitly picked Files-tab root, or nil while the sidebar follows
    // the focused pane's project (the pre-Phase-9 behavior).
    var pinnedSidebarRoot: String?

    init(appDelegate: AppDelegate, startDirectory: String, restoring saved: SavedWindow? = nil, adopting adopted: Tab? = nil) {
        self.appDelegate = appDelegate

        let frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window = NSWindow(
            contentRect: frame,
            // A regular title bar owns window dragging (and shows the active
            // tab's title); the strip is its own row below it, so a tab drag
            // can never turn into a window move.
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        // Programmatic NSWindows default to releasing themselves on close, but
        // ARC also owns this one via our strong `window` property — without this
        // the close over-releases and the app segfaults on the next autorelease
        // drain (first seen closing a window with the close button).
        window.isReleasedWhenClosed = false
        // One tab system: the strip. Never let AppKit graft its own on top.
        window.tabbingMode = .disallowed

        super.init()

        store.delegate = self
        window.delegate = self

        // Phase 12: focus is derived, never pushed. AppKit doesn't call
        // resignFirstResponder on a view that's simply removed from the
        // hierarchy (tree surgery, Pane.display content swaps), so any scheme
        // that pushes border state from responder overrides leaves stale
        // borders behind. Instead, one observer repaints every pane from
        // window.firstResponder on each change — a second focused border is
        // structurally impossible.
        firstResponderObservation = window.observe(\.firstResponder) { [weak self] _, _ in
            self?.firstResponderDidChange()
        }

        rootContainer = WindowRootView(frame: frame)

        effectView = NSVisualEffectView(frame: frame)
        effectView.blendingMode = .behindWindow
        effectView.material = .underWindowBackground
        effectView.state = .active
        effectView.isHidden = true
        rootContainer.addSubview(effectView)

        strip = TabStripView(frame: NSRect(x: 0, y: 0, width: frame.width, height: TabStripView.height))
        wireStrip()

        paneTreeHost = RootContainerView(frame: frame)

        // A saved layout replays here; a tab whose content can't come back
        // (file gone, transcript session dead) is dropped, its pane collapses,
        // and if nothing restores the window falls back to a plain shell.
        var restoredRoot: NSView?
        var restoredByIndex: [Int: Tab] = [:]
        if let saved {
            for (i, savedTab) in saved.tabs.enumerated() {
                guard let content = restoredContent(savedTab) else { continue }
                let tab = Tab(content: content)
                tab.isPreview = savedTab.isPreview
                tab.isPinned = savedTab.isPinned ?? false
                tab.customTitle = savedTab.customTitle
                store.insert(tab)
                restoredByIndex[i] = tab
            }
            if let tree = saved.tree {
                restoredRoot = buildNode(tree, restored: restoredByIndex)
            }
            // Tabs restored but not placed in the tree stay backgrounded; a
            // window whose tree fully collapsed shows its first tab.
            if restoredRoot == nil, let first = store.tabs.first {
                restoredRoot = makePane(displaying: first).container
            }
            if let mru = saved.mru {
                store.setMRUOrder(mru.compactMap { restoredByIndex[$0] })
            }
        } else if let adopted {
            // A torn-off tab becomes this window's first tab.
            store.insert(adopted)
            restoredRoot = makePane(displaying: adopted).container
        }

        let fallbackPane: Pane?
        if let restoredRoot {
            paneTreeRoot = restoredRoot
            fallbackPane = nil
        } else {
            let content = TerminalPaneContent()
            let tab = Tab(content: content)
            store.insert(tab)
            let root = makePane(displaying: tab)
            paneTreeRoot = root.container
            fallbackPane = root
        }
        paneTreeHost.addSubview(paneTreeRoot)

        let savedWidth = UserDefaults.standard.double(forKey: "sidebarWidth")
        let sidebarWidth = savedWidth > 0 ? CGFloat(savedWidth) : SidebarView.defaultWidth
        sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: frame.height))
        sidebar.isHidden = !UserDefaults.standard.bool(forKey: "sidebarVisible")

        projectIndex = FileIndex.shared(forDirectory: startDirectory)
        sidebar.fileBrowser.configure(index: projectIndex)
        sidebar.gitView.configure(displayRoot: projectIndex.root)
        // Feed the sidebar's project switcher (a pinned-root restore below
        // overrides both).
        FavoritesStore.shared.noteRecentFolder(projectIndex.root)
        sidebar.recentFolders.currentRoot = projectIndex.root
        sidebar.fileBrowser.onOpenFile = { [weak self] path in
            self?.openFile(atPath: path, line: nil)
        }
        sidebar.sshHostsView.onConnect = { [weak self] host in
            self?.openSSHTab(host: host)
        }
        sidebar.searchView.onOpenMatch = { [weak self] path, line in
            self?.openFile(atPath: path, line: line)
        }
        sidebar.searchView.scopeResolver = { [weak self] scope in
            self?.resolveSearchScope(scope)
        }
        sidebar.fileBrowser.onChooseFolder = { [weak self] in
            self?.selectSidebarFolder()
        }
        sidebar.fileBrowser.onUnpin = { [weak self] in
            self?.unpinSidebarFolder()
        }
        sidebar.gitView.onOpenDiff = { [weak self] root, path in
            self?.openGitDiff(root: root, file: path)
        }
        sidebar.gitView.onOpenFile = { [weak self] path in
            self?.openFile(atPath: path, line: nil)
        }
        sidebar.gitView.onShowFullDiff = { [weak self] root in
            self?.openGitDiff(root: root)
        }
        // File History row → that commit's per-file diff (ROADMAP Phase 17).
        sidebar.gitView.onOpenCommitDiff = { [weak self] path, sha in
            self?.paneRequestedOpenCommitDiff(forFile: path, sha: sha)
        }
        // Switching worktrees is a pin: the whole sidebar (browser, search,
        // git) repoints there, but stays on the Git tab — the user is
        // mid-review, not mid-browse.
        sidebar.gitView.onSwitchWorktree = { [weak self] path in
            self?.pinSidebar(toDirectory: path, showFiles: false)
        }
        sidebar.gitView.onTaskFinished = { [weak self] mainRoot in
            self?.pinSidebar(toDirectory: mainRoot, showFiles: false)
        }
        // Feedback inbox row → route the event into its session, or start a
        // dedicated review pass in its worktree (ROADMAP Phase 29).
        sidebar.gitView.onRouteFeedback = { event in
            (NSApp.delegate as? AppDelegate)?.routeFeedback(event)
        }
        sidebar.gitView.onStartReviewPass = { [weak self] event in
            self?.startReviewPass(for: event)
        }
        sidebar.recentFolders.onSelect = { [weak self] path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                // Stale row (folder deleted since load) — drop it instead of
                // pinning the sidebar to a dead directory.
                FavoritesStore.shared.removeRecentFolder(path)
                return
            }
            self?.pinSidebar(toDirectory: path)
        }
        sidebar.bookmarksView.onOpen = { [weak self] path, line in
            self?.openFile(atPath: path, line: line)
        }
        sidebar.usageFooter.onOpenSettings = { [weak self] in
            self?.appDelegate.installClaudeIntegration(nil)
        }
        // The Autopilot status row (ROADMAP Phase 32): running → the run tab,
        // idle/blocked → the log (a regular viewer tab).
        sidebar.usageFooter.onAutopilotFocusRunTab = { [weak self] in
            self?.appDelegate.focusAutopilotRunTab()
        }
        sidebar.usageFooter.onAutopilotOpenLog = { [weak self] in
            self?.appDelegate.openAutopilotLog()
        }
        // Restore a previously pinned root (one key across windows, like
        // sidebarWidth); a vanished directory silently unpins.
        if let pinned = UserDefaults.standard.string(forKey: "sidebarPinnedRoot") {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: pinned, isDirectory: &isDirectory), isDirectory.boolValue {
                applySidebarPin(pinned)
            } else {
                UserDefaults.standard.removeObject(forKey: "sidebarPinnedRoot")
            }
        }

        sidebarSplit = NSSplitView(frame: frame)
        sidebarSplit.isVertical = true
        sidebarSplit.dividerStyle = .thin
        sidebarSplit.delegate = self
        sidebarSplit.addArrangedSubview(sidebar)
        sidebarSplit.addArrangedSubview(paneTreeHost)

        rootContainer.addSubview(sidebarSplit)
        rootContainer.addSubview(strip)
        rootContainer.strip = strip
        rootContainer.body = sidebarSplit
        rootContainer.background = effectView
        rootContainer.layoutParts()
        layoutSidebarSplit()

        window.contentView = rootContainer
        applyTransparency(alpha: appDelegate.backgroundAlpha, blurEnabled: appDelegate.blurEnabled)

        if let fallbackPane {
            window.title = fallbackPane.displayTitle
            window.makeFirstResponder(fallbackPane.focusTarget)
            fallbackPane.terminalContent?.start(in: startDirectory)
        } else {
            if let saved, saved.frame.width > 100, saved.frame.height > 100 {
                window.setFrame(saved.frame, display: false)
            }
            updateBorderVisibility()
            // Focus the pane that was focused at capture time, if its tab came
            // back visible; otherwise the first pane in layout order.
            let activeTab = saved?.activeTabIndex.flatMap { restoredByIndex[$0] }
            let focusTarget = activeTab?.pane ?? firstPane(in: paneTreeRoot)
            if let focusTarget {
                window.title = focusTarget.displayTitle
                window.makeFirstResponder(focusTarget.focusTarget)
            }
            // Divider fractions need the window's real size; parents were
            // appended after their children in buildNode, so the reversed
            // order sizes outer splits before the splits nested inside them.
            let pending = pendingDividerFractions.reversed()
            pendingDividerFractions = []
            let scrolls = pendingScrollRestores
            pendingScrollRestores = []
            DispatchQueue.main.async {
                for (split, fraction) in pending {
                    split.layoutSubtreeIfNeeded()
                    let total = split.isVertical ? split.frame.width : split.frame.height
                    split.setPosition(total * CGFloat(fraction), ofDividerAt: 0)
                }
                // One more turn so the scroll views re-tile to their final
                // widths before line positions are computed.
                DispatchQueue.main.async {
                    for restore in scrolls { restore() }
                }
            }
        }

        reloadStrip()
        updateUsageLabel()
    }
}
