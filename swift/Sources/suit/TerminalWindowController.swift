import Cocoa

// Owns one OS-level window and everything under it: the window's TabStore, the
// NSSplitView tree of panes (viewports), and the panes themselves.
//
// The tab model (tabs-on-the-pane): every tab belongs to a pane (its homePane),
// and each pane hosts its own in-pane tab bar (PaneTabBarView) to switch between
// the tabs it owns — the window-level strip is gone. The sidebar's Sessions tab
// is the cross-pane overview (every open tab grouped by pane). ⌘T opens a tab in
// the focused pane; opening a file/diff/etc. adds a tab to that pane's group.
// Native macOS window tabs are gone.
final class TerminalWindowController: NSObject, NSWindowDelegate, NSSplitViewDelegate, PaneHost {
    let window: NSWindow
    unowned let appDelegate: AppDelegate

    // Every tab in this window, in order. Panes only ever display tabs
    // from this store.
    let store = TabStore()
    let tabSwitcher = TabSwitcherController()

    private var rootContainer: WindowRootView!

    // The activity bar (the far-left icon strip), the sidebar panel it drives,
    // and the split that puts that panel beside the pane tree. The bar is not in
    // the split — it's a sibling laid out by rootContainer, so Cmd-B can hide
    // the sidebar out from under it. The pane tree lives in its own filling
    // container rather than directly in the root, so tree-surgery
    // replaceSubview calls never have to know about the sidebar split around them.
    var activityBar: ActivityBarView!
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
    // (viewer line, markdown fraction, image zoom, PDF page).
    var pendingScrollRestores: [() -> Void] = []

    // The pane the user last worked in, so tab actions still mean "the tab I
    // was just using" while focus sits in the sidebar or a palette — but a
    // window with no such pane must NOT fall back to an arbitrary one (⌘W
    // would close the wrong tab).
    weak var lastFocusedPane: Pane?

    private var firstResponderObservation: NSKeyValueObservation?

    // Repaints this window's whole chrome + pane tree on a live theme switch
    // (Theme.didChange), the same centralized-observer spirit as the derived
    // focus above. Removed on close so a torn-down window stops repainting.
    var themeObserver: NSObjectProtocol?

    // The explicitly picked Files-tab root, or nil while the sidebar follows
    // the focused pane's project (the default follow-the-pane behavior).
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

        // Focus is derived, never pushed. AppKit doesn't call
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
        // Files-tab footer branch switcher (moved off the removed Git tab):
        // pick a worktree to repoint the sidebar there, or a branch to check
        // out in the shown repo.
        sidebar.fileBrowser.onSwitchWorktree = { [weak self] path in
            self?.switchWorktree(toDirectory: path)
        }
        sidebar.fileBrowser.onCheckoutBranch = { [weak self] root, branch in
            self?.checkoutBranch(root: root, branch: branch)
        }
        // Branch-row git actions (fetch/pull/push, stash, discard, branches)
        // and the sync badge's local↔upstream diff.
        sidebar.fileBrowser.onBranchAction = { [weak self] root, action in
            self?.runBranchAction(root: root, action: action)
        }
        sidebar.fileBrowser.onShowUpstreamDiff = { [weak self] root, branch in
            self?.openUpstreamDiff(root: root, branch: branch)
        }
        sidebar.fileBrowser.onNewBranch = { [weak self] root in
            self?.promptForNewBranch(root: root)
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
        // Commit graph pane for the shown repo.
        sidebar.gitView.onShowCommitGraph = { [weak self] root in
            self?.openCommitGraph(root: root)
        }
        // File History row → that commit's per-file diff.
        sidebar.gitView.onOpenCommitDiff = { [weak self] path, sha in
            self?.paneRequestedOpenCommitDiff(forFile: path, sha: sha)
        }
        // Away markers: drop a checkpoint / review the
        // aggregate catch-up diff since it.
        sidebar.gitView.onMarkNow = { [weak self] root in
            self?.markAwayPoint(root: root)
        }
        sidebar.gitView.onCatchUp = { [weak self] root in
            self?.openCatchUpDiff(root: root)
        }
        // Switching worktrees is a pin: the whole sidebar (browser, search,
        // git) repoints there, but stays on the Git tab — the user is
        // mid-review, not mid-browse.
        sidebar.gitView.onSwitchWorktree = { [weak self] path in
            self?.switchWorktree(toDirectory: path, showFiles: false)
        }
        sidebar.gitView.onTaskFinished = { [weak self] mainRoot in
            self?.pinSidebar(toDirectory: mainRoot, showFiles: false)
        }
        // Feedback inbox row → route the event into its session, or start a
        // dedicated review pass in its worktree.
        sidebar.gitView.onRouteFeedback = { event in
            (NSApp.delegate as? AppDelegate)?.routeFeedback(event)
        }
        sidebar.gitView.onStartReviewPass = { [weak self] event in
            self?.startReviewPass(for: event)
        }
        // PR review inbox row → open that PR's diff for review.
        sidebar.gitView.onOpenPR = { [weak self] pr in
            self?.openPRDiff(pr)
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
        // Sessions tab: click a row to bring that tab forward in its pane, or
        // its close box to shut it (the cross-pane overview replacing the strip).
        sidebar.sessionsView.onSelectTab = { [weak self] id in
            guard let self, let tab = self.store.tab(withId: id) else { return }
            self.activate(tab)
        }
        sidebar.sessionsView.onCloseTab = { [weak self] id in
            guard let self, let tab = self.store.tab(withId: id) else { return }
            self.closeTab(tab)
        }
        sidebar.usageFooter.onOpenSettings = { [weak self] in
            self?.appDelegate.installClaudeIntegration(nil)
        }
        // The Autopilot status row: running → the run tab,
        // idle/blocked → the log (a regular viewer tab).
        sidebar.usageFooter.onAutopilotFocusRunTab = { [weak self] in
            self?.appDelegate.focusAutopilotRunTab()
        }
        sidebar.usageFooter.onAutopilotOpenLog = { [weak self] in
            self?.appDelegate.openAutopilotLog()
        }
        sidebar.usageFooter.onAutopilotOpenDashboard = { [weak self] in
            self?.appDelegate.showAutopilotDashboard()
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

        // The bar renders the sidebar's selection and reports clicks back into
        // it; seed it from the restored tab, which SidebarView.init set without
        // going through select(tab:), so onTabChange hasn't fired for it.
        activityBar = ActivityBarView(
            frame: NSRect(x: 0, y: 0, width: ActivityBarView.width, height: frame.height)
        )
        activityBar.selectedTab = sidebar.selectedTab
        activityBar.onSelect = { [weak self] tab in self?.activateSidebarTab(tab) }
        sidebar.onTabChange = { [weak self] tab in self?.activityBar.selectedTab = tab }

        rootContainer.addSubview(activityBar)
        rootContainer.addSubview(sidebarSplit)
        rootContainer.activityBar = activityBar
        rootContainer.body = sidebarSplit
        rootContainer.layoutParts()
        layoutSidebarSplit()

        window.contentView = rootContainer
        applyTransparency(
            alpha: appDelegate.backgroundAlpha,
            blurEnabled: appDelegate.blurEnabled,
            blurRadius: appDelegate.blurRadius
        )

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

        // Any restored tab not placed in the split tree (a former window-level
        // background tab, from before per-pane ownership existed) has no home
        // pane yet. Give each to the focused/first pane so it appears in that
        // pane's tab bar and the Sessions list rather than being stranded.
        if let home = firstPane(in: paneTreeRoot) {
            for tab in store.tabs where tab.homePane == nil {
                tab.homePane = home
            }
        }

        refreshTabSurfaces()
        startObservingTheme()
    }
}
