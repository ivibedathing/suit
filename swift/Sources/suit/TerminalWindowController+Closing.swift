import Cocoa

// Tab/window closing split out of TerminalWindowController.swift: the browser
// close rules (last tab closes the window), forced teardown, and viewport
// dissolution.
extension TerminalWindowController {
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
    func forceCloseTab(_ tab: Tab, alreadyTerminated: Bool = false) {
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
    func dissolvePane(_ pane: Pane) {
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
}
