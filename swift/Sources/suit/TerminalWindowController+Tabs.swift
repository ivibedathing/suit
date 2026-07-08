import Cocoa

extension TerminalWindowController {

    // MARK: - Tab drag & drop

    // Strip drop: same-window reorder (crossing the pin boundary pins), or
    // adopting a tab dragged over from another window's strip.
    func handleStripDrop(tabId: String, insertionIndex: Int) -> Bool {
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
    func prepareForDisplay(_ tab: Tab, from source: TerminalWindowController) {
        if source === self {
            if let pane = tab.pane {
                tab.pane = nil
                tab.content.pane = nil
                tab.homePane = nil
                if let fallback = store.mruBackgroundTab(inHome: pane, excluding: tab) {
                    pane.display(fallback)
                } else {
                    dissolvePane(pane)
                }
            } else {
                // A background tab of some other pane: it just leaves that
                // pane's group (no viewport change).
                tab.homePane = nil
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
            tab.homePane = nil
            if let fallback = store.mruBackgroundTab(inHome: pane, excluding: tab) {
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

    func tabContextMenu(for tab: Tab) -> NSMenu {
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
}
