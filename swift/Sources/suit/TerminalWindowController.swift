import Cocoa

// Directional pane focus (⌥⌘ arrows).
enum PaneDirection {
    case left, right, up, down
}

// The window's top-level content view: the tab strip as its own row at the
// top of the content area (directly under the real title bar, which owns
// window dragging), the body (sidebar split + pane tree) below it, and the
// blur effect view behind everything.
final class WindowRootView: NSView {
    weak var strip: NSView?
    weak var body: NSView?
    weak var background: NSView?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutParts()
    }

    func layoutParts() {
        background?.frame = bounds
        let stripHeight = TabStripView.height
        strip?.frame = NSRect(x: 0, y: bounds.height - stripHeight, width: bounds.width, height: stripHeight)
        body?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - stripHeight))
    }
}

// Owns one OS-level window and everything under it: the browser-style tab
// strip (TabStripView) fed by the window's TabStore, the NSSplitView tree of
// panes (viewports displaying one tab each), and the panes themselves.
//
// The tab model (browser-tabs rebuild): the strip owns every tab — terminal,
// viewer, diff, transcript. Panes display a subset; clicking a background
// tab shows it in the focused pane, clicking a visible one focuses its pane.
// Native macOS window tabs are gone — ⌘T opens a tab in the strip.
final class TerminalWindowController: NSObject, NSWindowDelegate, NSSplitViewDelegate, PaneHost, TabStoreDelegate {
    let window: NSWindow
    private unowned let appDelegate: AppDelegate

    // Every tab in this window, in strip order. Panes only ever display tabs
    // from this store.
    let store = TabStore()
    private var strip: TabStripView!
    private let tabSwitcher = TabSwitcherController()

    private var rootContainer: WindowRootView!
    private var effectView: NSVisualEffectView!

    // Left rail (Files / Notes) and the split that puts it
    // beside the pane tree. The pane tree lives in its own filling container
    // rather than directly in the root, so tree-surgery replaceSubview calls
    // never have to know about the sidebar split around them.
    private var sidebarSplit: NSSplitView!
    private var sidebar: SidebarView!
    private var paneTreeHost: RootContainerView!

    // Tracks whichever view (a PaneContainerView or a nested NSSplitView) is
    // currently the top of the pane tree, since paneTreeHost's subview slot
    // can't itself serve as that marker.
    private var paneTreeRoot: NSView!

    // The viewports. Tabs are owned by the store; panes are owned here.
    private(set) var panes: [Pane] = []

    // The project this window is looking at — feeds the Files sidebar and the
    // Cmd-P fuzzy opener. Starts at the window's start directory's project and
    // follows wherever Cmd-P last resolved (see currentFileIndex()).
    private var projectIndex: FileIndex!

    // Below this, a pane is too small to be usable, so further splits are refused.
    private let minPaneWidth: CGFloat = 200
    private let minPaneHeight: CGFloat = 100

    // Splits built during a state restore, with the divider fraction each
    // should end up at once the window has its real size — and the viewer
    // scroll positions to apply only after those dividers have settled the
    // final wrap widths (scrolling first would land on the wrong line).
    private var pendingDividerFractions: [(NSSplitView, Double)] = []
    // Deferred scroll/zoom restores, run after the window reaches its real size
    // (viewer line, markdown fraction, image zoom, PDF page — ROADMAP Phase 19).
    private var pendingScrollRestores: [() -> Void] = []

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

    // MARK: - Strip wiring

    private func wireStrip() {
        strip.tabsProvider = { [weak self] in self?.store.tabs ?? [] }
        strip.activeTabProvider = { [weak self] in self?.activeTab }
        strip.onSelect = { [weak self] tab in self?.activate(tab) }
        strip.onClose = { [weak self] tab in self?.closeTab(tab) }
        strip.onNewTab = { [weak self] in self?.newTerminalTab() }
        strip.onNewClaudeTab = { [weak self] in self?.newClaudeSessionTab() }
        strip.onKeep = { [weak self] tab in self?.keepTab(tab) }
        strip.onRename = { [weak self] tab in self?.renameTab(tab) }
        strip.contextMenuProvider = { [weak self] tab in self?.tabContextMenu(for: tab) }
        strip.onDropTab = { [weak self] id, index in self?.handleStripDrop(tabId: id, insertionIndex: index) ?? false }
        strip.onTearOff = { [weak self] id, point in self?.appDelegate.tearOffTab(withId: id, at: point) }
    }

    func reloadStrip(animated: Bool = false) {
        strip.reload(animated: animated)
    }

    // MARK: - The tab model core

    // The pane the user last worked in, so tab actions still mean "the tab I
    // was just using" while focus sits in the sidebar or a palette — but a
    // window with no such pane must NOT fall back to an arbitrary one (⌘W
    // would close the wrong tab).
    private weak var lastFocusedPane: Pane?

    private var firstResponderObservation: NSKeyValueObservation?

    // The single writer of pane focus visuals: repaints every pane against
    // the actual first responder (idempotent — exactly one border no matter
    // how focus moved), and keeps lastFocusedPane / window title / MRU / the
    // strip's raised tab in agreement with it.
    private func firstResponderDidChange() {
        let focused = focusedPane()
        for pane in panes {
            pane.setFocused(pane === focused)
        }
        guard let focused else { return }
        lastFocusedPane = focused
        window.title = focused.displayTitle
        store.touchMRU(focused.tab)
        reloadStrip()
    }

    private func lastFocusedPaneIfValid() -> Pane? {
        guard let pane = lastFocusedPane, panes.contains(where: { $0 === pane }) else { return nil }
        return pane
    }

    // The active tab: whatever the focused (or most recently focused) pane
    // is displaying. Nil when the window has no meaningful pane focus.
    var activeTab: Tab? {
        (focusedPane() ?? lastFocusedPaneIfValid())?.tab
    }

    // Where a newly shown tab should land: the focused pane, else the last
    // focused one, else anywhere.
    private func displayTargetPane() -> Pane? {
        focusedPane() ?? lastFocusedPaneIfValid() ?? panes.first
    }

    // Strip click / ⌘1..9 / palette / switcher: a background tab appears in
    // the focused pane; a visible tab's pane gets focus instead — content
    // never jumps between panes on a click.
    func activate(_ tab: Tab) {
        guard store.tab(withId: tab.id) != nil else { return }
        if let pane = tab.pane {
            focusPane(pane)
        } else if let pane = displayTargetPane() {
            pane.display(tab)
            focusPane(pane)
        }
        store.touchMRU(tab)
        reloadStrip()
    }

    private func focusPane(_ pane: Pane) {
        lastFocusedPane = pane
        window.makeFirstResponder(pane.focusTarget)
        // The observation already fired if the responder moved; this covers
        // the no-move cases (already focused, or the target refused) so the
        // visuals still settle against reality. Idempotent either way.
        firstResponderDidChange()
    }

    // ⌘T / the strip's "+": a fresh shell tab starting in the focused pane's
    // cwd, shown right there.
    @discardableResult
    func newTerminalTab() -> Tab {
        let target = displayTargetPane()
        let cwd = target?.workingDirectory ?? NSHomeDirectory()
        let content = TerminalPaneContent()
        let tab = Tab(content: content)
        store.insert(tab)
        content.start(in: cwd)
        if let target {
            target.display(tab)
            focusPane(target)
        }
        reloadStrip(animated: true)
        return tab
    }

    // A sidebar SSH host row: a fresh shell tab that types the ssh command
    // itself (and, for password hosts, answers the password prompt from the
    // Keychain — see SSHPaneContent).
    @discardableResult
    func openSSHTab(host: SSHHost) -> Tab {
        let content = SSHPaneContent(host: host)
        let tab = Tab(content: content)
        store.insert(tab)
        content.start(in: NSHomeDirectory())
        content.connect()
        activate(tab)
        return tab
    }

    // ⌃⌘C / the strip's ✦ / the palette: a fresh shell tab (same placement
    // rules as ⌘T) that immediately launches claude, with the default
    // arguments configured in Settings appended verbatim.
    func newClaudeSessionTab() {
        let tab = newTerminalTab()
        let args = appDelegate.claudeSessionArgs
        let command = args.isEmpty ? "claude" : "claude \(args)"
        let content = tab.content as? TerminalPaneContent
        // The pty input queue holds this until zsh is ready to read it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak content] in
            content?.terminalView.send(txt: command + "\r")
        }
    }

    // ⇧⌘T: bring back the most recently closed tab.
    func reopenClosedTab() {
        guard let saved = store.popClosed(), let content = restoredContent(saved) else {
            NSSound.beep()
            return
        }
        let tab = Tab(content: content)
        tab.isPreview = saved.isPreview
        tab.isPinned = saved.isPinned ?? false
        tab.customTitle = saved.customTitle
        store.insert(tab)
        activate(tab)
        flushPendingScrollRestores()
    }

    private func flushPendingScrollRestores() {
        let scrolls = pendingScrollRestores
        pendingScrollRestores = []
        guard !scrolls.isEmpty else { return }
        DispatchQueue.main.async {
            for restore in scrolls { restore() }
        }
    }

    // MARK: - Closing

    // ⌘W: close the active tab (browser rule; the last tab closes the window).
    func closeActiveTab() {
        guard let tab = activeTab else {
            NSSound.beep()
            return
        }
        closeTab(tab)
    }

    func closeTab(_ tab: Tab) {
        guard store.tab(withId: tab.id) != nil else { return }
        // The window's last tab: closing it closes the window — and quits the
        // app outright when this is the last window
        // (applicationShouldTerminateAfterLastWindowClosed) — so it confirms
        // even when the shell is idle.
        if store.tabs.count == 1 {
            if confirmCloseWindow(processNames: busyPaneProcessNames()) {
                teardownAndClose()
            }
            return
        }
        if let name = tab.runningProcessName,
           !Self.confirmTermination(messageText: "Close Tab?", confirmTitle: "Close", processNames: [name]) {
            return
        }
        forceCloseTab(tab)
    }

    // Close without confirmation (already confirmed, or the process exited).
    // Guarded by store membership: callers can hold stale snapshots (e.g.
    // "Close Other Tabs" iterating while a clean exit auto-closed one of
    // them mid-loop) and must not re-close — the count==1 branch would take
    // the whole window with it.
    private func forceCloseTab(_ tab: Tab, alreadyTerminated: Bool = false) {
        guard store.tab(withId: tab.id) != nil else { return }
        if store.tabs.count == 1 {
            teardownAndClose(alreadyTerminated: alreadyTerminated)
            return
        }
        store.rememberClosed(savedTab(for: tab))
        if let pane = tab.pane {
            let wasFocused = focusedPane() === pane
            if let fallback = store.mruBackgroundTab(excluding: tab) {
                pane.display(fallback)
                store.touchMRU(fallback)
                if wasFocused { focusPane(pane) }
            } else {
                // Every other tab is on screen in some other pane, so this
                // viewport has nothing left to show: it dissolves and its
                // space returns to its neighbors.
                tab.pane = nil
                tab.content.pane = nil
                dissolvePane(pane)
            }
        }
        store.remove(tab)
        tabSwitcher.tabClosed(tab)
        if !alreadyTerminated {
            tab.content.teardown()
        }
        reloadStrip(animated: true)
    }

    private func teardownAndClose(alreadyTerminated: Bool = false) {
        if !alreadyTerminated {
            for tab in store.tabs {
                tab.content.teardown()
            }
        }
        for pane in panes {
            pane.teardown()
        }
        window.close()
    }

    // ⌥⌘W ("Unsplit"): the focused viewport goes away, its tab stays in the strip.
    func closeFocusedPaneKeepTab() {
        guard let pane = focusedPane() else {
            NSSound.beep()
            return
        }
        unsplit(pane.tab)
    }

    // Removes a viewport from the split tree. The tab it displayed is the
    // caller's responsibility (already unlinked or being closed).
    private func dissolvePane(_ pane: Pane) {
        pane.teardown()
        if let parentSplit = pane.container.superview as? NSSplitView {
            if let sibling = detachFromPaneTree(pane.container, parentSplit: parentSplit),
               let nextFocus = firstPane(in: sibling) {
                window.makeFirstResponder(nextFocus.focusTarget)
            }
        }
        panes.removeAll { $0 === pane }
        updateBorderVisibility()
    }

    // MARK: - TabStoreDelegate

    func tabDidChange(_ tab: Tab) {
        reloadStrip()
        tab.pane?.refreshChrome()
        if let pane = tab.pane, focusedPane() === pane {
            window.title = tab.title
        }
    }

    // Clean exits close the tab like Terminal.app/iTerm2 do by default.
    // Non-clean exits (nonzero status, or killed by a signal such as SIGPIPE)
    // leave the tab on screen with its indicator red, so the user can read
    // whatever the process last printed before closing it themselves (⌘W).
    func tabProcessDidExit(_ tab: Tab) {
        reloadStrip()
        tab.pane?.refreshChrome()
        guard tab.exitStatus?.isClean == true else { return }
        DispatchQueue.main.async { [weak self, weak tab] in
            guard let self, let tab, self.store.tab(withId: tab.id) != nil else { return }
            self.forceCloseTab(tab, alreadyTerminated: true)
        }
    }

    func tabWantsAttention(_ tab: Tab) {
        strip.flashTab(withId: tab.id)
    }

    // MARK: - Tab drag & drop

    // Strip drop: same-window reorder (crossing the pin boundary pins), or
    // adopting a tab dragged over from another window's strip.
    private func handleStripDrop(tabId: String, insertionIndex: Int) -> Bool {
        if let tab = store.tab(withId: tabId) {
            store.move(tab, toInsertionIndex: insertionIndex)
            reloadStrip(animated: true)
            return true
        }
        guard let (source, tab) = appDelegate.controllerAndTab(withId: tabId), source !== self else { return false }
        source.release(tab)
        store.insert(tab, at: insertionIndex)
        activate(tab)
        return true
    }

    func canDropTab(withId id: String, onto target: Pane) -> Bool {
        guard let (_, tab) = appDelegate.controllerAndTab(withId: id) else { return false }
        if tab.pane !== target { return true }
        // The tab's own pane: a center drop means nothing, but an edge drop
        // splits the tab out into a new pane — meaningful whenever some
        // background tab can backfill the vacated viewport.
        return store.mruBackgroundTab(excluding: tab) != nil
    }

    func dropTab(withId id: String, onto target: Pane, drop: TabDropTarget) -> Bool {
        guard let (source, tab) = appDelegate.controllerAndTab(withId: id) else { return false }

        switch drop {
        case .show:
            guard tab.pane !== target else { return false }
            prepareForDisplay(tab, from: source)
            target.display(tab)
            focusPane(target)
            store.touchMRU(tab)
            reloadStrip()
            return true

        case .edge(let zone):
            guard zone != .swap else { return false }
            // Splitting the tab out of its own pane needs a background tab
            // to leave behind, or the vacated pane would just dissolve.
            if tab.pane === target, store.mruBackgroundTab(excluding: tab) == nil {
                NSSound.beep()
                return false
            }
            let orientation: SplitOrientation = (zone == .left || zone == .right) ? .vertical : .horizontal
            // Same usability floor as split(): refuse drops that would produce
            // unusably small panes.
            let available = orientation == .vertical ? target.container.frame.width : target.container.frame.height
            guard available >= (orientation == .vertical ? minPaneWidth : minPaneHeight) * 2 else {
                NSSound.beep()
                return false
            }
            prepareForDisplay(tab, from: source)
            let newPane = makePane(displaying: tab)
            insert(newPane.container, besides: target.container, orientation: orientation, before: zone == .left || zone == .top)
            focusPane(newPane)
            store.touchMRU(tab)
            reloadStrip()
            return true
        }
    }

    // Makes `tab` a background tab of *this* window: vacates the viewport
    // that showed it (here or in another window) and adopts it across
    // windows when needed.
    private func prepareForDisplay(_ tab: Tab, from source: TerminalWindowController) {
        if source === self {
            if let pane = tab.pane {
                tab.pane = nil
                tab.content.pane = nil
                if let fallback = store.mruBackgroundTab(excluding: tab) {
                    pane.display(fallback)
                } else {
                    dissolvePane(pane)
                }
            }
        } else {
            source.release(tab)
            store.insert(tab)
        }
    }

    // Gives a tab up to another window (drop or tear-off): vacate its
    // viewport, drop it from this store, and close the window if that was
    // everything it had.
    func release(_ tab: Tab) {
        if let pane = tab.pane {
            let wasFocused = focusedPane() === pane
            tab.pane = nil
            tab.content.pane = nil
            if let fallback = store.mruBackgroundTab(excluding: tab) {
                pane.display(fallback)
                store.touchMRU(fallback)
                // Removing the dragged view can reset the first responder to
                // the window itself; re-establish it so keystrokes keep
                // landing in the vacated pane.
                if wasFocused {
                    window.makeFirstResponder(pane.focusTarget)
                }
            } else if panes.count > 1 {
                dissolvePane(pane)
            }
        }
        store.remove(tab)
        tabSwitcher.tabClosed(tab)
        if store.tabs.isEmpty {
            // The whole window went with the tab. The moved tab's content
            // lives on in its new window — only pane-owned extras (screensaver
            // timers) need stopping here.
            for pane in panes {
                pane.teardown()
            }
            window.close()
        } else {
            reloadStrip(animated: true)
        }
    }

    // MARK: - Keyboard navigation

    // ⌘⇧] / ⌘⇧[: next/previous tab in strip order.
    func activateAdjacentTab(_ delta: Int) {
        guard store.tabs.count > 1, let current = activeTab, let index = store.index(of: current) else {
            NSSound.beep()
            return
        }
        let count = store.tabs.count
        activate(store.tabs[((index + delta) % count + count) % count])
    }

    // ⌘1..9 — browser rule: ⌘9 is the last tab.
    func activateTab(number: Int) {
        let tabs = store.tabs
        guard !tabs.isEmpty else {
            NSSound.beep()
            return
        }
        if number >= 9 {
            activate(tabs[tabs.count - 1])
        } else if tabs.indices.contains(number - 1) {
            activate(tabs[number - 1])
        } else {
            NSSound.beep()
        }
    }

    // ⌃Tab / ⌃⇧Tab: the MRU switcher overlay (hold ⌃ to see it, tap to toggle).
    func cycleMRUTab(forward: Bool) {
        tabSwitcher.cycle(tabs: store.tabsInMRUOrder(), forward: forward, over: window) { [weak self] tab in
            self?.activate(tab)
        }
    }

    // ⌥⌘ arrows: focus the nearest pane in that direction.
    func focusPane(direction: PaneDirection) {
        guard panes.count > 1, let current = focusedPane() else {
            NSSound.beep()
            return
        }
        let currentFrame = current.container.convert(current.container.bounds, to: nil)
        let origin = NSPoint(x: currentFrame.midX, y: currentFrame.midY)
        var best: (pane: Pane, score: CGFloat)?
        for pane in panes where pane !== current {
            let frame = pane.container.convert(pane.container.bounds, to: nil)
            let center = NSPoint(x: frame.midX, y: frame.midY)
            let dx = center.x - origin.x
            let dy = center.y - origin.y
            let forward: CGFloat
            switch direction {
            case .left: forward = -dx
            case .right: forward = dx
            case .up: forward = dy      // window coordinates: y grows upward
            case .down: forward = -dy
            }
            guard forward > 1 else { continue }
            let lateral = (direction == .left || direction == .right) ? abs(dy) : abs(dx)
            let score = forward + lateral * 2
            if best == nil || score < best!.score {
                best = (pane, score)
            }
        }
        if let best {
            focusPane(best.pane)
        } else {
            NSSound.beep()
        }
    }

    // MARK: - Tab niceties (rename / keep / pin)

    func renameActiveTab() {
        guard let tab = activeTab else {
            NSSound.beep()
            return
        }
        renameTab(tab)
    }

    func renameTab(_ tab: Tab) {
        OverlayPromptController.shared.ask(
            caption: "Rename Tab", text: tab.title, placeholder: "Tab name",
            over: window
        ) { [weak self, weak tab] newTitle in
            guard let self, let tab else { return }
            tab.customTitle = newTitle.isEmpty ? nil : newTitle
            self.tabDidChange(tab)
        }
    }

    // Double-click a preview tab / palette: keep its content open — the next
    // openFile stops replacing it.
    func keepTab(_ tab: Tab) {
        tab.isPreview = false
        reloadStrip()
    }

    func keepActiveTab() {
        guard let tab = activeTab, tab.isPreview else {
            NSSound.beep()
            return
        }
        keepTab(tab)
    }

    func togglePinActiveTab() {
        guard let tab = activeTab else {
            NSSound.beep()
            return
        }
        store.setPinned(!tab.isPinned, for: tab)
        reloadStrip(animated: true)
    }

    // MARK: - Strip context menu

    private func tabContextMenu(for tab: Tab) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = tab.id
        }
        // Tab-first splitting (Phase 13): showing a second tab is something
        // you do to a tab, not to a pane.
        if tab.pane == nil {
            add("Split Screen", #selector(contextSplitScreen(_:)))
        } else if panes.count > 1 {
            add("Unsplit", #selector(contextUnsplit(_:)))
        }
        if menu.items.isEmpty == false {
            menu.addItem(.separator())
        }
        if tab.isPreview {
            add("Keep Open", #selector(contextKeepTab(_:)))
        }
        add(tab.isPinned ? "Unpin Tab" : "Pin Tab", #selector(contextTogglePin(_:)))
        add("Rename Tab…", #selector(contextRenameTab(_:)))
        menu.addItem(.separator())
        add("Close Tab", #selector(contextCloseTab(_:)))
        if store.tabs.contains(where: { $0 !== tab && !$0.isPinned }) {
            add("Close Other Tabs", #selector(contextCloseOthers(_:)))
        }
        if store.tabs.count > 1 {
            menu.addItem(.separator())
            add("Move Tab to New Window", #selector(contextMoveToNewWindow(_:)))
        }
        return menu
    }

    private func contextTab(_ sender: Any?) -> Tab? {
        guard let id = (sender as? NSMenuItem)?.representedObject as? String else { return nil }
        return store.tab(withId: id)
    }

    @objc private func contextKeepTab(_ sender: Any?) {
        if let tab = contextTab(sender) { keepTab(tab) }
    }

    @objc private func contextSplitScreen(_ sender: Any?) {
        if let tab = contextTab(sender) { splitScreen(with: tab) }
    }

    @objc private func contextUnsplit(_ sender: Any?) {
        if let tab = contextTab(sender) { unsplit(tab) }
    }

    @objc private func contextTogglePin(_ sender: Any?) {
        guard let tab = contextTab(sender) else { return }
        store.setPinned(!tab.isPinned, for: tab)
        reloadStrip(animated: true)
    }

    @objc private func contextRenameTab(_ sender: Any?) {
        if let tab = contextTab(sender) { renameTab(tab) }
    }

    @objc private func contextCloseTab(_ sender: Any?) {
        if let tab = contextTab(sender) { closeTab(tab) }
    }

    @objc private func contextCloseOthers(_ sender: Any?) {
        guard let keep = contextTab(sender) else { return }
        let others = store.tabs.filter { $0 !== keep && !$0.isPinned }
        let names = others.compactMap { $0.runningProcessName }
        if !names.isEmpty,
           !Self.confirmTermination(messageText: "Close Other Tabs?", confirmTitle: "Close", processNames: names) {
            return
        }
        // Make sure the kept tab is what the focused pane shows before its
        // neighbors' viewports start dissolving.
        activate(keep)
        for tab in others {
            forceCloseTab(tab)
        }
    }

    @objc private func contextMoveToNewWindow(_ sender: Any?) {
        guard let tab = contextTab(sender) else { return }
        let point = NSPoint(x: window.frame.midX - 100, y: window.frame.maxY - 60)
        appDelegate.tearOffTab(withId: tab.id, at: point)
    }

    // MARK: - State restoration

    func captureState() -> SavedWindow {
        var savedTabs: [SavedTab] = []
        var indexById: [String: Int] = [:]
        for tab in store.tabs {
            if let saved = savedTab(for: tab) {
                indexById[tab.id] = savedTabs.count
                savedTabs.append(saved)
            }
        }
        let tree = captureNode(paneTreeRoot, indexById: indexById)
        let mru = store.tabsInMRUOrder().compactMap { indexById[$0.id] }
        return SavedWindow(
            frame: window.frame,
            tabs: savedTabs,
            tree: tree,
            mru: mru,
            activeTabIndex: activeTab.flatMap { indexById[$0.id] }
        )
    }

    private func savedTab(for tab: Tab) -> SavedTab? {
        switch tab.content {
        // Before the TerminalPaneContent arm — SSHPaneContent is a subclass.
        case let ssh as SSHPaneContent:
            return SavedTab(
                kind: .ssh, cwd: ssh.workingDirectory,
                isPreview: tab.isPreview, isPinned: tab.isPinned, customTitle: tab.customTitle,
                sshHostId: ssh.sshHost.id.uuidString
            )
        case let terminal as TerminalPaneContent:
            return SavedTab(
                kind: .terminal, cwd: terminal.workingDirectory,
                isPreview: tab.isPreview, isPinned: tab.isPinned, customTitle: tab.customTitle
            )
        case let viewer as FileViewerPaneContent:
            guard let path = viewer.filePath else { return nil }
            return SavedTab(
                kind: .viewer, filePath: path, firstVisibleLine: viewer.firstVisibleLine,
                isPreview: tab.isPreview, isPinned: tab.isPinned, customTitle: tab.customTitle
            )
        case let markdown as MarkdownPaneContent:
            guard let path = markdown.filePath else { return nil }
            return SavedTab(
                kind: .markdown, filePath: path,
                isPreview: tab.isPreview, isPinned: tab.isPinned, customTitle: tab.customTitle,
                scrollFraction: markdown.scrollFraction
            )
        case let image as ImagePaneContent:
            guard let path = image.filePath else { return nil }
            return SavedTab(
                kind: .image, filePath: path,
                isPreview: tab.isPreview, isPinned: tab.isPinned, customTitle: tab.customTitle,
                imageActualSize: image.isActualSize
            )
        case let pdf as PDFPaneContent:
            guard let path = pdf.filePath else { return nil }
            return SavedTab(
                kind: .pdf, filePath: path,
                isPreview: tab.isPreview, isPinned: tab.isPinned, customTitle: tab.customTitle,
                pdfPage: pdf.currentPageIndex
            )
        case let diff as DiffPaneContent:
            guard let root = diff.gitRoot else { return nil }
            let comments = diff.reviewDraft.comments
            return SavedTab(
                kind: .diff, diffRoot: root,
                reviewComments: comments.isEmpty ? nil : comments,
                isPreview: tab.isPreview, isPinned: tab.isPinned, customTitle: tab.customTitle
            )
        default:
            // Transcript tabs: the session won't exist next launch.
            return nil
        }
    }

    private func captureNode(_ view: NSView, indexById: [String: Int]) -> SavedNode? {
        if let split = view as? NSSplitView, split.arrangedSubviews.count == 2 {
            let firstView = split.arrangedSubviews[0]
            let total = split.isVertical ? split.frame.width : split.frame.height
            let firstSize = split.isVertical ? firstView.frame.width : firstView.frame.height
            let first = captureNode(firstView, indexById: indexById)
            let second = captureNode(split.arrangedSubviews[1], indexById: indexById)
            guard let first else { return second }
            guard let second else { return first }
            return .split(
                vertical: split.isVertical,
                fraction: total > 0 ? Double(firstSize / total) : 0.5,
                first: first,
                second: second
            )
        }
        guard let pane = (view as? PaneContainerView)?.pane,
              let index = indexById[pane.tab.id] else { return nil }
        // Only a size that differs from the global font is a per-pane override
        // worth carrying across the relaunch.
        let paneSize = pane.appliedFont?.pointSize
        let fontSize = paneSize == appDelegate.currentFont.pointSize ? nil : paneSize.map(Double.init)
        return .pane(tabIndex: index, fontSize: fontSize)
    }

    private func buildNode(_ node: SavedNode, restored: [Int: Tab]) -> NSView? {
        switch node {
        case .pane(let tabIndex, let fontSize):
            // A tab can only be displayed once; a stale tree that references
            // the same tab twice keeps the first viewport.
            guard let tab = restored[tabIndex], tab.pane == nil else { return nil }
            let pane = makePane(displaying: tab)
            if let fontSize {
                pane.setFont(NSFontManager.shared.convert(appDelegate.currentFont, toSize: CGFloat(fontSize)))
            }
            return pane.container
        case .split(let vertical, let fraction, let first, let second):
            let a = buildNode(first, restored: restored)
            let b = buildNode(second, restored: restored)
            guard let a else { return b }
            guard let b else { return a }
            let split = NSSplitView(frame: .zero)
            split.isVertical = vertical
            split.dividerStyle = .thin
            split.delegate = self
            split.addArrangedSubview(a)
            split.addArrangedSubview(b)
            pendingDividerFractions.append((split, fraction))
            return split
        }
    }

    private func restoredContent(_ tab: SavedTab) -> PaneContent? {
        switch tab.kind {
        case .terminal:
            let terminal = TerminalPaneContent()
            let cwd = tab.cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            terminal.start(in: cwd ?? NSHomeDirectory())
            return terminal
        case .viewer:
            guard let path = tab.filePath, FileManager.default.fileExists(atPath: path) else { return nil }
            let viewer = FileViewerPaneContent()
            viewer.setWordWrap(appDelegate.wordWrapEnabled)
            viewer.load(path: path, line: nil)
            if let line = tab.firstVisibleLine, line > 1 {
                pendingScrollRestores.append { viewer.scrollTo(firstVisibleLine: line) }
            }
            return viewer
        case .markdown:
            guard let path = tab.filePath, FileManager.default.fileExists(atPath: path) else { return nil }
            let markdown = MarkdownPaneContent()
            markdown.load(path: path, line: nil)
            if let fraction = tab.scrollFraction, fraction > 0 {
                pendingScrollRestores.append { markdown.restore(scrollFraction: fraction) }
            }
            return markdown
        case .image:
            guard let path = tab.filePath, FileManager.default.fileExists(atPath: path) else { return nil }
            let image = ImagePaneContent()
            image.load(path: path, line: nil)
            if tab.imageActualSize == true {
                pendingScrollRestores.append { image.restoreZoom(actualSize: true) }
            }
            return image
        case .pdf:
            guard let path = tab.filePath, FileManager.default.fileExists(atPath: path) else { return nil }
            let pdf = PDFPaneContent()
            pdf.load(path: path, line: nil)
            if let page = tab.pdfPage, page > 0 {
                pendingScrollRestores.append { pdf.restore(pageIndex: page) }
            }
            return pdf
        case .diff:
            guard let root = tab.diffRoot, FileManager.default.fileExists(atPath: root) else { return nil }
            let diff = DiffPaneContent()
            diff.loadGitDiff(root: root)
            diff.restoreComments(tab.reviewComments)
            return diff
        case .ssh:
            let cwd = tab.cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            guard let host = tab.sshHostId
                .flatMap(UUID.init(uuidString:))
                .flatMap({ SSHHostsStore.shared.host(withId: $0) }) else {
                // The saved host is gone — restore the tab as a plain shell
                // rather than dropping it.
                let terminal = TerminalPaneContent()
                terminal.start(in: cwd ?? NSHomeDirectory())
                return terminal
            }
            let ssh = SSHPaneContent(host: host)
            ssh.start(in: NSHomeDirectory())
            // Pre-typed, not submitted: relaunching the app must never
            // reconnect to servers on its own.
            ssh.prepareReconnect()
            return ssh
        }
    }

    // MARK: - Claude sessions (ROADMAP Phase 4)

    private func updateUsageLabel() {
        guard let usage = ClaudeSessionMonitor.shared.usage else {
            strip.setUsage(text: "", color: Theme.textDim)
            return
        }
        var parts: [String] = []
        if let five = usage.fiveHourPct {
            parts.append("5h \(Int(five.rounded()))%")
        }
        if let week = usage.sevenDayPct {
            parts.append("7d \(Int(week.rounded()))%")
        }
        let worst = max(usage.fiveHourPct ?? 0, usage.sevenDayPct ?? 0)
        strip.setUsage(text: parts.joined(separator: " · "), color: Theme.usageLevelColor(worst))
    }

    // Re-maps sessions onto this window's terminal tabs (pid ancestry, cwd
    // fallback — see ClaudeSessionAssigner). Called by AppDelegate on session
    // updates and on a slow heartbeat, since process trees change silently.
    // Every tab carries its own session so background tabs still route
    // attention (strip dot + pane header when visible).
    func refreshClaudeSessions(assigner: ClaudeSessionAssigner) {
        var changed = false
        for tab in store.tabs {
            let session: ClaudeSession?
            if tab.exitStatus == nil, let terminal = tab.content as? TerminalPaneContent {
                session = assigner.session(forShellPid: terminal.shellPid, cwd: terminal.workingDirectory)
            } else {
                session = nil
            }
            if session?.id != tab.claudeSession?.id || session?.state != tab.claudeSession?.state
                || session?.contextPct != tab.claudeSession?.contextPct {
                changed = true
            }
            tab.claudeSession = session
        }
        if changed {
            reloadStrip()
            for pane in panes {
                pane.refreshChrome()
            }
        }
        updateUsageLabel()
    }

    func runsClaudeSession(withId id: String) -> Bool {
        store.tabs.contains { $0.claudeSession?.id == id }
    }

    // Notification click-through (ClaudeAttentionCenter): bring the exact tab
    // running that session forward, wherever it's hiding.
    func focusPane(runningSession session: ClaudeSession) {
        guard let tab = store.tabs.first(where: { $0.claudeSession?.id == session.id }) else {
            NSSound.beep()
            return
        }
        window.makeKeyAndOrderFront(nil)
        activate(tab)
    }

    // MARK: - Sidebar

    func toggleSidebar() {
        sidebar.isHidden.toggle()
        layoutSidebarSplit()
        UserDefaults.standard.set(!sidebar.isHidden, forKey: "sidebarVisible")
    }

    // Cmd-Shift-F: reveal the sidebar's Files tab and put the cursor in the
    // search field above the file tree.
    func focusProjectSearch() {
        if sidebar.isHidden {
            sidebar.isHidden = false
            layoutSidebarSplit()
            UserDefaults.standard.set(true, forKey: "sidebarVisible")
        }
        sidebar.showSearch()
    }

    // Turns the picked search scope into the directory rg runs in. "Project" is
    // the current file index's root (which follows the focused pane, like Cmd-P);
    // "Sub-project" is the deepest marker-file directory above the focused
    // pane's cwd (falling back to the project root); "Pane Directory" is the
    // cwd itself.
    private func resolveSearchScope(_ scope: SearchScope) -> (root: String, label: String)? {
        // While the sidebar is pinned (Phase 9), "Project" means what the
        // Files tab shows, not the focused pane's project.
        let index = pinnedSidebarRoot.map { FileIndex.shared(forExactDirectory: $0) } ?? currentFileIndex()
        let projectRoot = index.root
        let projectLabel = (projectRoot as NSString).lastPathComponent

        switch scope {
        case .project:
            return (projectRoot, projectLabel)
        case .subproject:
            guard let cwd = focusedPane()?.workingDirectory,
                  cwd == projectRoot || cwd.hasPrefix(projectRoot + "/") else {
                return (projectRoot, projectLabel)
            }
            let relative = cwd == projectRoot ? "" : String(cwd.dropFirst(projectRoot.count + 1))
            // Deepest sub-project root that is the cwd or one of its parents.
            var best: String?
            for dir in index.subprojectBadges.keys where !dir.isEmpty {
                if relative == dir || relative.hasPrefix(dir + "/") {
                    if best == nil || dir.count > best!.count {
                        best = dir
                    }
                }
            }
            guard let best else { return (projectRoot, projectLabel) }
            return (projectRoot + "/" + best, (best as NSString).lastPathComponent)
        case .paneDirectory:
            guard let cwd = focusedPane()?.workingDirectory else {
                return (projectRoot, projectLabel)
            }
            return (cwd, (cwd as NSString).lastPathComponent)
        }
    }

    // The sidebar keeps its width; the pane tree absorbs all window resizing.
    private func layoutSidebarSplit() {
        let bounds = sidebarSplit.bounds
        if sidebar.isHidden {
            paneTreeHost.frame = bounds
            return
        }
        let width = min(max(sidebar.frame.width, SidebarView.minWidth), SidebarView.maxWidth)
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        let treeX = width + sidebarSplit.dividerThickness
        paneTreeHost.frame = NSRect(x: treeX, y: 0, width: max(0, bounds.width - treeX), height: bounds.height)
    }

    // MARK: - Project files & viewer tabs

    // The index for the project the user is actually in right now (the focused
    // pane's cwd), falling back to the window's current project. When Cmd-P
    // resolves a different project than the sidebar is showing, the sidebar
    // follows, so the two navigation surfaces never disagree — unless the
    // sidebar is pinned to an explicit folder (Phase 9), which stops it from
    // trailing pane cwds until unpinned.
    func currentFileIndex() -> FileIndex {
        let directory = focusedPane()?.workingDirectory ?? projectIndex.root
        let index = FileIndex.shared(forDirectory: directory)
        if index !== projectIndex {
            projectIndex = index
            if pinnedSidebarRoot == nil {
                sidebar.fileBrowser.configure(index: index)
                sidebar.gitView.configure(displayRoot: index.root)
                // Following the pane into another project counts as opening
                // that folder — feed the sidebar's project switcher.
                FavoritesStore.shared.noteRecentFolder(index.root)
                sidebar.recentFolders.currentRoot = index.root
            }
        }
        return index
    }

    // MARK: - Sidebar folder pinning (ROADMAP Phase 9)

    // The explicitly picked Files-tab root, or nil while the sidebar follows
    // the focused pane's project (the pre-Phase-9 behavior).
    private var pinnedSidebarRoot: String?

    // "Select Folder…" (Files-tab header button / palette): pin the sidebar's
    // browser and project-scoped search to a picked directory.
    func selectSidebarFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Pin the sidebar's Files tab to a folder."
        panel.directoryURL = URL(fileURLWithPath: pinnedSidebarRoot ?? currentFileIndex().root)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let path = panel.url?.path else { return }
            self?.pinSidebar(toDirectory: path)
        }
    }

    // showFiles: false keeps the current sidebar tab (the Git tab's worktree
    // switcher pins without yanking the user over to the file tree).
    func pinSidebar(toDirectory path: String, showFiles: Bool = true) {
        applySidebarPin(path)
        UserDefaults.standard.set(path, forKey: "sidebarPinnedRoot")
        // Show the result: unhide the sidebar if needed and land on Files.
        if sidebar.isHidden {
            sidebar.isHidden = false
            layoutSidebarSplit()
            UserDefaults.standard.set(true, forKey: "sidebarVisible")
        }
        if showFiles {
            sidebar.select(tab: .files)
        }
    }

    private func applySidebarPin(_ path: String) {
        pinnedSidebarRoot = path
        // Exact directory, not the enclosing git root: picking a repo
        // subfolder means "browse this subfolder".
        sidebar.fileBrowser.configure(index: FileIndex.shared(forExactDirectory: path))
        sidebar.fileBrowser.setPinned(true)
        sidebar.gitView.configure(displayRoot: path)
        FavoritesStore.shared.noteRecentFolder(path)
        sidebar.recentFolders.currentRoot = path
    }

    func unpinSidebarFolder() {
        pinnedSidebarRoot = nil
        UserDefaults.standard.removeObject(forKey: "sidebarPinnedRoot")
        sidebar.fileBrowser.setPinned(false)
        // Back to following the focused pane's project.
        let index = currentFileIndex()
        sidebar.fileBrowser.configure(index: index)
        sidebar.gitView.configure(displayRoot: index.root)
        sidebar.recentFolders.currentRoot = index.root
    }

    // Reveal the Notes tab (palette) and put the caret in it.
    func showNotes() {
        if sidebar.isHidden {
            sidebar.isHidden = false
            layoutSidebarSplit()
            UserDefaults.standard.set(true, forKey: "sidebarVisible")
        }
        sidebar.select(tab: .notes)
    }

    // Reveal the Git tab (palette).
    func showGit() {
        if sidebar.isHidden {
            sidebar.isHidden = false
            layoutSidebarSplit()
            UserDefaults.standard.set(true, forKey: "sidebarVisible")
        }
        sidebar.select(tab: .git)
    }

    // Reveal the Bookmarks tab (palette / ROADMAP Phase 22).
    func showBookmarks() {
        if sidebar.isHidden {
            sidebar.isHidden = false
            layoutSidebarSplit()
            UserDefaults.standard.set(true, forKey: "sidebarVisible")
        }
        sidebar.select(tab: .bookmarks)
    }

    // Opens `path` as a first-class tab (files are regular tabs — the Chrome
    // rule): a path that's already open gets its tab activated; otherwise the
    // file opens in a tab of its own. Files never replace one another —
    // opening three files leaves three tabs, deduped by path.
    func openFile(atPath path: String, line: Int?) {
        let standardized = (path as NSString).standardizingPath
        // Deduped by path across every preview kind (viewer/markdown/image/PDF):
        // a file opens at most one tab. A re-open re-loads it, honoring a line
        // jump where the kind supports it.
        if let tab = store.tabs.first(where: { ($0.content as? FileBackedPaneContent)?.filePath == standardized }) {
            (tab.content as? FileBackedPaneContent)?.load(path: standardized, line: line)
            activate(tab)
            return
        }

        let content = makePreviewContent(forPath: standardized)
        let tab = Tab(content: content)
        store.insert(tab)
        content.load(path: standardized, line: line)
        activate(tab)
    }

    // Routes a file to its preview pane by extension (ROADMAP Phase 19):
    // markdown/image/PDF get their own kind, everything else the text viewer.
    private func makePreviewContent(forPath path: String) -> FileBackedPaneContent {
        switch PreviewKind.forPath(path) {
        case .markdown:
            return MarkdownPaneContent()
        case .image:
            return ImagePaneContent()
        case .pdf:
            return PDFPaneContent()
        case .text:
            let viewer = FileViewerPaneContent()
            viewer.setWordWrap(appDelegate.wordWrapEnabled)
            return viewer
        }
    }

    // The window's reused diff tab's content, if one is open — the review
    // draft that "Send Review to Session…" acts on (ROADMAP Phase 16).
    var currentDiffContent: DiffPaneContent? {
        store.tabs.first { $0.content is DiffPaneContent }?.content as? DiffPaneContent
    }

    // Opens (or reuses, same policy as openFile) the window's diff tab showing
    // a project's uncommitted changes — the focused pane's project unless the
    // caller (the Git tab) names a root explicitly.
    func openGitDiff(root explicitRoot: String? = nil) {
        let root = explicitRoot ?? currentFileIndex().root
        guard FileIndex.gitRoot(of: root) != nil else {
            NSSound.beep()
            return
        }
        if let tab = store.tabs.first(where: { $0.content is DiffPaneContent }) {
            (tab.content as? DiffPaneContent)?.loadGitDiff(root: root)
            activate(tab)
            return
        }
        let content = DiffPaneContent()
        let tab = Tab(content: content)
        store.insert(tab)
        content.loadGitDiff(root: root)
        activate(tab)
    }

    // The Git tab's file-scoped variant: the same diff tab, showing only one
    // changed file (staged and unstaged both, like the full HEAD diff).
    func openGitDiff(root: String, file: String) {
        let producer = {
            runProcess("/usr/bin/git", ["-C", root, "diff", "HEAD", "--", file]) ?? ""
        }
        let title = "diff: \((file as NSString).lastPathComponent)"
        let load = { (content: DiffPaneContent) in
            content.loadDiffText(producer(), title: title, root: root, reload: producer)
        }
        if let tab = store.tabs.first(where: { $0.content is DiffPaneContent }) {
            if let content = tab.content as? DiffPaneContent {
                load(content)
            }
            activate(tab)
            return
        }
        let content = DiffPaneContent()
        let tab = Tab(content: content)
        store.insert(tab)
        load(content)
        activate(tab)
    }

    // Opens (or reuses, same policy) the diff tab showing one commit's changes
    // to a single file (ROADMAP Phase 17 — from a File History row or a clicked
    // blame sha). `git show --format=` prints just the per-file diff, no commit
    // header; it handles the root commit (whole-file addition) too.
    func openCommitDiff(root: String, file: String, sha: String) {
        let producer = {
            runProcess("/usr/bin/git", ["-C", root, "show", "--format=", sha, "--", file]) ?? ""
        }
        let title = "diff: \((file as NSString).lastPathComponent) @ \(sha.prefix(8))"
        let load = { (content: DiffPaneContent) in
            content.loadDiffText(producer(), title: title, root: root, reload: producer)
        }
        if let tab = store.tabs.first(where: { $0.content is DiffPaneContent }) {
            if let content = tab.content as? DiffPaneContent {
                load(content)
            }
            activate(tab)
            return
        }
        let content = DiffPaneContent()
        let tab = Tab(content: content)
        store.insert(tab)
        load(content)
        activate(tab)
    }

    // Opens (or reuses) the window's transcript tab showing a Claude session's
    // conversation (ROADMAP Phase 7).
    func openTranscript(for session: ClaudeSession) {
        if let tab = store.tabs.first(where: { $0.content is TranscriptPaneContent }) {
            (tab.content as? TranscriptPaneContent)?.load(session: session)
            activate(tab)
            return
        }
        let content = TranscriptPaneContent()
        let tab = Tab(content: content)
        store.insert(tab)
        content.load(session: session)
        activate(tab)
    }

    // Opens (or reuses) the window's checkpoint-timeline tab showing a Claude
    // session's change history (ROADMAP Phase 25), reused like the transcript.
    func openCheckpointTimeline(for session: ClaudeSession) {
        if let tab = store.tabs.first(where: { $0.content is CheckpointTimelinePaneContent }) {
            (tab.content as? CheckpointTimelinePaneContent)?.load(session: session)
            activate(tab)
            return
        }
        let content = CheckpointTimelinePaneContent()
        let tab = Tab(content: content)
        store.insert(tab)
        content.load(session: session)
        activate(tab)
    }

    // Opens (or reuses) the window's transcript tab for an explicit transcript
    // file — how cross-transcript search (Phase 20) jumps to a historical
    // session, anchoring the pane on the matching line.
    func openTranscript(path: String, cwd: String?, title: String, line: Int?) {
        let content: TranscriptPaneContent
        if let tab = store.tabs.first(where: { $0.content is TranscriptPaneContent }),
           let existing = tab.content as? TranscriptPaneContent {
            content = existing
            content.load(path: path, cwd: cwd, title: title)
            activate(tab)
        } else {
            content = TranscriptPaneContent()
            let tab = Tab(content: content)
            store.insert(tab)
            content.load(path: path, cwd: cwd, title: title)
            activate(tab)
        }
        // Defer the jump one turn so the pane has laid out (scrollRangeToVisible
        // needs a real frame after activate).
        if let line {
            DispatchQueue.main.async { content.jump(toSourceLine: line) }
        }
    }

    // MARK: - Claude task worktrees (ROADMAP Phase 5)

    // "New task": worktree + branch + a tab running claude in it, tagged with
    // the task name. The CLAUDE.md multi-agent discipline as one keystroke.
    func startClaudeTask(named name: String) {
        let root = currentFileIndex().root
        switch WorktreeTasks.createTask(projectRoot: root, name: name) {
        case .failure(let error):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "New Claude Task"
            alert.informativeText = error.message
            alert.runModal()
        case .success(let directory):
            let content = TerminalPaneContent()
            let tab = Tab(content: content)
            tab.customTitle = name
            store.insert(tab)
            content.start(in: directory)
            activate(tab)
            // The pty input queue holds this until zsh is ready to read it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak content] in
                content?.terminalView.send(txt: "claude\r")
            }
        }
    }

    // A task tab finished (worktree merged/discarded and removed): close it
    // without the usual running-process confirmation — the user just confirmed
    // the whole task's fate in the finish dialog.
    func paneFinishedTask(_ pane: Pane) {
        forceCloseTab(pane.tab)
    }

    // MARK: - Panes

    // Builds a viewport around a tab from the store — the one place pane
    // appearance setup happens.
    private func makePane(displaying tab: Tab) -> Pane {
        let pane = Pane(host: self, tab: tab)
        panes.append(pane)
        updateBorderVisibility()
        pane.setBackgroundAlpha(appDelegate.backgroundAlpha)
        pane.setFont(appDelegate.currentFont)
        pane.setTextColor(appDelegate.currentTextColor)
        (tab.content as? FileViewerPaneContent)?.setWordWrap(appDelegate.wordWrapEnabled)
        return pane
    }

    // The border is only meaningful once there's more than one pane to distinguish.
    private func updateBorderVisibility() {
        let showBorders = panes.count > 1
        for pane in panes {
            pane.setBorderVisible(showBorders)
        }
    }

    // Walks up from the first responder to the PaneContainerView that owns it,
    // so this works for any pane content, not just terminals.
    func focusedPane() -> Pane? {
        var view = window.firstResponder as? NSView
        while let current = view {
            if let container = current as? PaneContainerView {
                return container.pane
            }
            view = current.superview
        }
        return nil
    }

    func paneTitleChanged(_ pane: Pane) {
        if focusedPane() === pane {
            window.title = pane.displayTitle
            store.touchMRU(pane.tab)
        }
        reloadStrip()
    }

    // A terminal pane's Cmd-click on a file-path link (see PaneTerminalView.mouseUp).
    func paneRequestedOpenFile(path: String, line: Int?) {
        openFile(atPath: path, line: line)
    }

    // Blame sha click (ROADMAP Phase 17): open that commit's per-file diff.
    func paneRequestedOpenCommitDiff(forFile path: String, sha: String) {
        let directory = (path as NSString).deletingLastPathComponent
        guard let root = FileIndex.gitRoot(of: directory) else {
            NSSound.beep()
            return
        }
        let relative = relativePath(of: path, inRoot: root)
        openCommitDiff(root: root, file: relative, sha: sha)
    }

    // Viewer "Show File History" / palette: reveal the Git tab's File History
    // section for this file.
    func paneRequestedShowFileHistory(forPath path: String) {
        let directory = (path as NSString).deletingLastPathComponent
        guard FileIndex.gitRoot(of: directory) != nil else {
            NSSound.beep()
            return
        }
        showGit()
        sidebar.gitView.showFileHistory(absolutePath: (path as NSString).standardizingPath)
    }

    // A path relative to a git root, for the file-scoped git commands.
    private func relativePath(of path: String, inRoot root: String) -> String {
        let standardized = (path as NSString).standardizingPath
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return standardized.hasPrefix(prefix) ? String(standardized.dropFirst(prefix.count)) : standardized
    }

    // MARK: - Split Screen (tab-first, Phase 13)

    // Strip right-click ▸ Split Screen: show `tab` beside the active tab in a
    // new viewport — vertical when the screen is wide enough, else stacked.
    // The tab-first replacement for the old pane-first ⌘D splits.
    // `forcedOrientation` (⇧⌘D) pins the split axis; otherwise it's chosen by
    // the pane's shape (wide → side-by-side, tall → stacked).
    func splitScreen(with tab: Tab, forcedOrientation: SplitOrientation? = nil) {
        guard store.tab(withId: tab.id) != nil, tab.pane == nil,
              let target = displayTargetPane(),
              let orientation = splitOrientation(for: target, forced: forcedOrientation) else {
            NSSound.beep()
            return
        }
        let newPane = makePane(displaying: tab)
        insert(newPane.container, besides: target.container, orientation: orientation, before: false)
        equalizeSplits()
        focusPane(newPane)
        store.touchMRU(tab)
        reloadStrip()
    }

    // A forced orientation is honored only if the pane has room along that axis;
    // otherwise: wide enough → side-by-side, tall enough → stacked, neither → nil.
    private func splitOrientation(for target: Pane, forced: SplitOrientation? = nil) -> SplitOrientation? {
        if let forced {
            let room = forced == .vertical
                ? target.container.frame.width >= minPaneWidth * 2
                : target.container.frame.height >= minPaneHeight * 2
            return room ? forced : nil
        }
        if target.container.frame.width >= minPaneWidth * 2 { return .vertical }
        if target.container.frame.height >= minPaneHeight * 2 { return .horizontal }
        return nil
    }

    // ⌘D (auto orientation) / ⇧⌘D (forced horizontal, stacked): split the screen
    // with a brand-new shell tab starting in the focused pane's cwd — the
    // fresh-terminal twin of ⌘T, shown beside instead of over.
    func splitScreenWithNewTerminal(forcedOrientation: SplitOrientation? = nil) {
        // Check there's room before creating the tab, so a refused split
        // doesn't strand a freshly started shell in the strip's background.
        guard let target = displayTargetPane(),
              splitOrientation(for: target, forced: forcedOrientation) != nil else {
            NSSound.beep()
            return
        }
        let content = TerminalPaneContent()
        let tab = Tab(content: content)
        store.insert(tab)
        content.start(in: target.workingDirectory ?? NSHomeDirectory())
        splitScreen(with: tab, forcedOrientation: forcedOrientation)
    }

    // Palette "Split Screen (last used tab)": Split Screen with the most recently
    // used background tab — the same tab a vacated viewport would fall back to.
    func splitScreenWithMRUTab() {
        guard let tab = store.mruBackgroundTab() else {
            NSSound.beep()
            return
        }
        splitScreen(with: tab)
    }

    // The background tabs, for the palette's "Split Screen with Tab…" picker.
    func backgroundTabs() -> [Tab] {
        store.tabs.filter { $0.pane == nil }
    }

    // Strip right-click ▸ Unsplit: the tab's viewport dissolves and the tab
    // returns to the strip's background, its process untouched.
    func unsplit(_ tab: Tab) {
        guard let pane = tab.pane, panes.count > 1 else {
            NSSound.beep()
            return
        }
        tab.pane = nil
        tab.content.pane = nil
        dissolvePane(pane)
        equalizeSplits()
        reloadStrip()
    }

    // N screens share the space equally: every divider apportions its axis by
    // the number of panes on each side, so a run of same-orientation splits
    // comes out exactly 1/N (three tabs → thirds), and mixed grids get
    // area-proportional shares. Applied when Split Screen / Unsplit change
    // the screen count — drag-resized dividers stay put otherwise.
    private func equalizeSplits() {
        guard let root = paneTreeRoot else { return }
        equalizeNode(root)
    }

    private func paneCount(in view: NSView) -> Int {
        if view is PaneContainerView { return 1 }
        return view.subviews.reduce(0) { $0 + paneCount(in: $1) }
    }

    // Top-down: size a split's own divider first, then its children against
    // their settled frames.
    private func equalizeNode(_ view: NSView) {
        guard let split = view as? NSSplitView, split.arrangedSubviews.count == 2 else { return }
        split.layoutSubtreeIfNeeded()
        let first = split.arrangedSubviews[0]
        let second = split.arrangedSubviews[1]
        let firstShare = CGFloat(paneCount(in: first))
        let secondShare = CGFloat(paneCount(in: second))
        guard firstShare > 0, secondShare > 0 else { return }
        let total = (split.isVertical ? split.frame.width : split.frame.height) - split.dividerThickness
        split.setPosition(total * firstShare / (firstShare + secondShare), ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        equalizeNode(first)
        equalizeNode(second)
    }

    // ⌃⌘M / palette: collapse the split tree back to the single-viewport
    // default (the Chrome state — Phase 12). Every displaced tab stays open
    // in the strip as a background tab; only the viewports go away.
    func mergeAllPanes() {
        guard panes.count > 1, let keep = displayTargetPane() else {
            NSSound.beep()
            return
        }
        for pane in Array(panes) where pane !== keep {
            pane.tab.pane = nil
            pane.tab.content.pane = nil
            dissolvePane(pane)
        }
        focusPane(keep)
        reloadStrip(animated: true)
    }

    // Wraps `target`'s slot in the tree (its parent split's arranged position, or
    // the root) with a new NSSplitView holding `container` and `target` side by
    // side, divider at the midpoint. `before` puts `container` on the left/top.
    private func insert(_ container: NSView, besides target: NSView, orientation: SplitOrientation, before: Bool) {
        let splitView = NSSplitView(frame: target.frame)
        splitView.isVertical = orientation == .vertical
        splitView.dividerStyle = .thin
        splitView.delegate = self

        if target === paneTreeRoot {
            paneTreeHost.replaceSubview(target, with: splitView)
            paneTreeRoot = splitView
        } else if let parent = target.superview as? NSSplitView {
            let index = parent.arrangedSubviews.firstIndex(of: target) ?? 0
            parent.removeArrangedSubview(target)
            target.removeFromSuperview()
            parent.insertArrangedSubview(splitView, at: index)
        }

        splitView.addArrangedSubview(before ? container : target)
        splitView.addArrangedSubview(before ? target : container)
        splitView.layoutSubtreeIfNeeded()
        let dividerPosition = orientation == .vertical ? splitView.frame.width / 2 : splitView.frame.height / 2
        splitView.setPosition(dividerPosition, ofDividerAt: 0)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView === sidebarSplit { return SidebarView.minWidth }
        return proposedMinimumPosition + (splitView.isVertical ? minPaneWidth : minPaneHeight)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView === sidebarSplit { return SidebarView.maxWidth }
        return proposedMaximumPosition - (splitView.isVertical ? minPaneWidth : minPaneHeight)
    }

    // The pane-tree splits keep NSSplitView's default proportional resizing;
    // the sidebar split instead pins the sidebar's width so window resizes go
    // entirely to the pane tree.
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        if splitView === sidebarSplit {
            layoutSidebarSplit()
        } else {
            splitView.adjustSubviews()
        }
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Persist the width the user dragged the sidebar to.
        guard notification.object as? NSSplitView === sidebarSplit,
              !sidebar.isHidden, sidebar.frame.width >= SidebarView.minWidth else { return }
        UserDefaults.standard.set(Double(sidebar.frame.width), forKey: "sidebarWidth")
    }

    // MARK: - Window closing

    // The whole-window confirmation, shared by ⌘W on the window's last tab and
    // the close button (windowShouldClose). Unlike confirmTermination it also
    // fires with nothing running, since losing a whole window (or the app,
    // when it's the last window) deserves a warning even when every tab is an
    // idle shell.
    private func confirmCloseWindow(processNames: [String]) -> Bool {
        let quitsApp = appDelegate.isLastWindowController(self)
        let messageText = quitsApp ? "Quit Suit?" : "Close Window?"
        guard processNames.isEmpty else {
            return Self.confirmTermination(
                messageText: messageText,
                confirmTitle: quitsApp ? "Quit" : "Close",
                processNames: processNames
            )
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = messageText
        alert.informativeText = quitsApp
            ? "Closing this window will quit Suit."
            : "This will close this window and its \(store.tabs.count) tab\(store.tabs.count == 1 ? "" : "s")."
        alert.addButton(withTitle: quitsApp ? "Quit" : "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // Every tab in this window that currently has a foreground process (i.e. is
    // running something beyond its idle shell), by process name.
    func busyPaneProcessNames() -> [String] {
        store.tabs.compactMap { $0.runningProcessName }
    }

    // One confirmation shared by the tab-, window- and app-close paths,
    // naming what's still running since closing terminates it without further
    // warning. Static so AppDelegate can reuse it for Cmd-Q.
    static func confirmTermination(messageText: String, confirmTitle: String, processNames: [String]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = messageText
        let list = processNames.map { "“\($0)”" }.joined(separator: ", ")
        alert.informativeText = processNames.count == 1
            ? "This will terminate the running process \(list)."
            : "This will terminate \(processNames.count) running processes: \(list)."
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // The traffic-light close button comes through performClose, not ⌘W, so
    // closing a whole window gets the same always-on confirmation here,
    // naming any tabs still running something. window.close() — used by the
    // close paths once everything is torn down — skips this deliberately.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmCloseWindow(processNames: busyPaneProcessNames())
    }

    func windowWillClose(_ notification: Notification) {
        appDelegate.windowControllerDidClose(self)
    }

    // MARK: - Pane drag & drop rearrangement

    private func pane(withDragID id: String) -> Pane? {
        panes.first { $0.dragID == id }
    }

    // Only drags that resolve to a *different* pane of *this* window are movable;
    // a drag from another window just isn't found here and is rejected.
    func canMovePane(withDragID id: String, onto target: Pane) -> Bool {
        guard let source = pane(withDragID: id) else { return false }
        return source !== target
    }

    func movePane(withDragID id: String, onto target: Pane, zone: PaneDropZone) -> Bool {
        guard let source = pane(withDragID: id), source !== target else { return false }

        switch zone {
        case .swap:
            swapPanes(source, target)
        case .left, .right, .top, .bottom:
            let orientation: SplitOrientation = (zone == .left || zone == .right) ? .vertical : .horizontal
            // Same usability floor as split(): refuse drops that would produce
            // unusably small panes. (Conservative: if source and target are
            // currently siblings, detaching would actually free up more room.)
            let available = orientation == .vertical ? target.container.frame.width : target.container.frame.height
            guard available >= (orientation == .vertical ? minPaneWidth : minPaneHeight) * 2 else {
                NSSound.beep()
                return false
            }
            // source !== target means at least two panes exist, so source's
            // container always sits inside a split.
            guard let parentSplit = source.container.superview as? NSSplitView else { return false }
            _ = detachFromPaneTree(source.container, parentSplit: parentSplit)
            insert(source.container, besides: target.container, orientation: orientation, before: zone == .left || zone == .top)
        }

        window.makeFirstResponder(source.focusTarget)
        return true
    }

    // Removes `view` from its parent split and collapses that split, promoting the
    // sibling into the slot the split occupied (splits always hold exactly two
    // arranged subviews). Returns the promoted sibling, or nil if there wasn't one.
    // `view` itself (and its pane) is left intact, so callers can dissolve the
    // pane or re-insert it elsewhere (footer docking, drag rearrangement).
    private func detachFromPaneTree(_ view: NSView, parentSplit: NSSplitView) -> NSView? {
        guard let sibling = parentSplit.arrangedSubviews.first(where: { $0 !== view }) else {
            return nil
        }

        // sibling only ever held half of parentSplit's rect; now that it's taking over
        // the whole slot, it needs to be resized into the space parentSplit used to
        // occupy rather than keeping the smaller frame it had as one half of the split.
        let vacatedFrame = parentSplit.frame

        parentSplit.removeArrangedSubview(view)
        view.removeFromSuperview()
        parentSplit.removeArrangedSubview(sibling)
        sibling.removeFromSuperview()

        if parentSplit === paneTreeRoot {
            paneTreeHost.replaceSubview(parentSplit, with: sibling)
            paneTreeRoot = sibling
        } else if let grandparent = parentSplit.superview as? NSSplitView {
            let index = grandparent.arrangedSubviews.firstIndex(of: parentSplit) ?? 0
            grandparent.removeArrangedSubview(parentSplit)
            parentSplit.removeFromSuperview()
            grandparent.insertArrangedSubview(sibling, at: index)
        }
        sibling.frame = vacatedFrame
        return sibling
    }

    // Exchanges the two containers' positions in the split tree. Every pane
    // container sits inside an NSSplitView here — a swap needs two panes, so the
    // root can't be a bare container.
    private func swapPanes(_ a: Pane, _ b: Pane) {
        guard let parentA = a.container.superview as? NSSplitView,
              let parentB = b.container.superview as? NSSplitView,
              let indexA = parentA.arrangedSubviews.firstIndex(of: a.container),
              let indexB = parentB.arrangedSubviews.firstIndex(of: b.container) else { return }

        let frameA = a.container.frame
        let frameB = b.container.frame

        parentA.removeArrangedSubview(a.container)
        a.container.removeFromSuperview()
        parentB.removeArrangedSubview(b.container)
        b.container.removeFromSuperview()

        if parentA === parentB {
            // Same two-child split: re-add in flipped order.
            parentA.insertArrangedSubview(indexA < indexB ? b.container : a.container, at: 0)
            parentA.insertArrangedSubview(indexA < indexB ? a.container : b.container, at: 1)
        } else {
            parentA.insertArrangedSubview(b.container, at: indexA)
            parentB.insertArrangedSubview(a.container, at: indexB)
        }

        // Each container takes over the other's old rect so the surrounding
        // dividers stay exactly where they were.
        a.container.frame = frameB
        b.container.frame = frameA
    }

    // MARK: - Footer

    // The footer is simply the bottom half of a horizontal split at the very root
    // of the pane tree, so it always spans the window's full width no matter how
    // the panes above it are split.
    func paneIsFooter(_ pane: Pane) -> Bool {
        guard let rootSplit = paneTreeRoot as? NSSplitView, !rootSplit.isVertical else { return false }
        return rootSplit.arrangedSubviews.last === pane.container
    }

    // Pulls the pane out of wherever it sits in the split tree and re-roots the
    // tree as {everything else} stacked above {this pane}, full width.
    func paneRequestedFooter(_ pane: Pane) {
        guard !paneIsFooter(pane) else { return }
        let paneContainer = pane.container

        // Sole pane (it's the tree root) — already full width, nothing to dock below.
        // Also refuse when the window is too short to stack two usable rows.
        guard let parentSplit = paneContainer.superview as? NSSplitView,
              paneTreeHost.bounds.height >= minPaneHeight * 2 else {
            NSSound.beep()
            return
        }

        guard detachFromPaneTree(paneContainer, parentSplit: parentSplit) != nil else {
            NSSound.beep()
            return
        }

        let splitView = NSSplitView(frame: paneTreeHost.bounds)
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.delegate = self

        let upperTree = paneTreeRoot!
        paneTreeHost.replaceSubview(upperTree, with: splitView)
        splitView.addArrangedSubview(upperTree)
        splitView.addArrangedSubview(paneContainer)
        paneTreeRoot = splitView

        splitView.layoutSubtreeIfNeeded()
        let footerHeight = max(minPaneHeight, splitView.frame.height * 0.3)
        splitView.setPosition(splitView.frame.height - footerHeight, ofDividerAt: 0)

        window.makeFirstResponder(pane.focusTarget)
    }

    private func firstPane(in view: NSView) -> Pane? {
        if let container = view as? PaneContainerView {
            return container.pane
        }
        for subview in view.subviews {
            if let found = firstPane(in: subview) {
                return found
            }
        }
        return nil
    }

    // MARK: - Palette

    // Every open tab in this window, as palette commands — the fuzzy "jump to
    // any open tab" surface (Go to Tab…).
    func tabPaletteCommands() -> [PaletteCommand] {
        store.tabs.enumerated().map { index, tab in
            let location = tab.pane == nil ? "background" : "visible"
            return PaletteCommand(title: tab.title, shortcut: "tab \(index + 1) · \(location)") { [weak self, weak tab] in
                guard let self, let tab else { return }
                self.activate(tab)
            }
        }
    }

    // MARK: - Opacity, blur & appearance

    // window.backgroundColor only paints pixels no subview covers. Keep it
    // opaque so the title-bar row (traffic lights) never goes see-through;
    // panes handle their own translucency via setBackgroundAlpha regardless.
    func applyTransparency(alpha: CGFloat, blurEnabled: Bool) {
        let transparent = alpha < 1
        window.isOpaque = !transparent
        window.backgroundColor = Theme.bg
        effectView.isHidden = !blurEnabled
        for pane in panes {
            pane.setBackgroundAlpha(alpha)
        }
    }

    func applyFont(_ font: NSFont) {
        for pane in panes {
            pane.setFont(font)
        }
    }

    func applyTextColor(_ color: NSColor) {
        for pane in panes {
            pane.setTextColor(color)
        }
    }

    func applyWordWrap(_ wrap: Bool) {
        for tab in store.tabs {
            (tab.content as? FileViewerPaneContent)?.setWordWrap(wrap)
        }
    }

    // The settings window changed the default pane background. Repaint every
    // pane — same all-panes sweep as applyTextColor; per-pane menu overrides
    // are repainted too and can be re-picked.
    func applyDefaultBackground(_ color: NSColor) {
        for pane in panes {
            pane.setBackgroundColor(color)
        }
    }

    // Every terminal tab, background ones included — the pty and its Terminal
    // keep running while a tab is hidden from every pane.
    func applyCursorStyle(_ style: CursorStyle) {
        for tab in store.tabs {
            (tab.content as? TerminalPaneContent)?.applyCursorStyle(style)
        }
    }
}
