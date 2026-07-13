import Cocoa

extension TerminalWindowController {

    // MARK: - Strip wiring

    func wireStrip() {
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

    // The window-level strip is gone (its tabs now live on each pane's own tab
    // bar, and the sidebar's Sessions tab is the cross-pane overview). This name
    // survives as the single "the tab set changed, refresh its surfaces" call so
    // its many callers stay untouched.
    func reloadStrip(animated: Bool = false) {
        for pane in panes {
            pane.refreshTabBar()
        }
        refreshSessionsSidebar()
    }

    // Rebuilds the sidebar Sessions list: every open tab grouped by the pane
    // (screen) that owns it, plus a Background group for any tab no pane holds.
    func refreshSessionsSidebar() {
        var groups: [SessionsView.Group] = []
        let multiple = panes.count > 1
        for (index, pane) in panes.enumerated() {
            let owned = store.ownedTabs(of: pane)
            guard !owned.isEmpty else { continue }
            let title = multiple ? "Screen \(index + 1)" : "Open Tabs"
            groups.append(SessionsView.Group(title: title, tabs: owned))
        }
        let orphans = store.tabs.filter { $0.homePane == nil }
        if !orphans.isEmpty {
            groups.append(SessionsView.Group(title: "Background", tabs: orphans))
        }
        sidebar.sessionsView.update(groups: groups, activeId: activeTab?.id)
    }

    // MARK: - The tab model core

    // The single writer of pane focus visuals: repaints every pane against
    // the actual first responder (idempotent — exactly one border no matter
    // how focus moved), and keeps lastFocusedPane / window title / MRU / the
    // strip's raised tab in agreement with it.
    func firstResponderDidChange() {
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

    func lastFocusedPaneIfValid() -> Pane? {
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
    func displayTargetPane() -> Pane? {
        focusedPane() ?? lastFocusedPaneIfValid() ?? panes.first
    }

    // Strip click / ⌘1..9 / palette / switcher: a background tab appears in
    // the focused pane; a visible tab's pane gets focus instead — content
    // never jumps between panes on a click.
    func activate(_ tab: Tab) {
        guard store.tab(withId: tab.id) != nil else { return }
        if let pane = tab.pane {
            // Already on screen — focus its pane, content never jumps.
            focusPane(pane)
        } else if let home = tab.homePane, panes.contains(where: { $0 === home }) {
            // A background tab of a pane it belongs to: bring it forward there.
            home.display(tab)
            focusPane(home)
        } else if let pane = displayTargetPane() {
            // A brand-new or orphaned tab: adopt it into the focused pane.
            pane.display(tab)
            focusPane(pane)
        }
        store.touchMRU(tab)
        reloadStrip()
    }

    func focusPane(_ pane: Pane) {
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
        // The Claude API pane's env overrides prefix the typed command
        // (KEY='value' claude …) so they apply to this session only.
        let command = appDelegate.claudeAPI.launchCommand(
            base: args.isEmpty ? "claude" : "claude \(args)"
        )
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

    func flushPendingScrollRestores() {
        let scrolls = pendingScrollRestores
        pendingScrollRestores = []
        guard !scrolls.isEmpty else { return }
        DispatchQueue.main.async {
            for restore in scrolls { restore() }
        }
    }
}
