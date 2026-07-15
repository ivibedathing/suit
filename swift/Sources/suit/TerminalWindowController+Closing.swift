import Cocoa

// Closing semantics: ⌘W closes the active tab and falls back to a tab the
// same pane owns (collapsing the pane when none is left), plus the window-level
// close path and its running-process confirmations.
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
    // An editable viewer autosaves on a 1 s debounce; flush any edit still in
    // that window before the tab (and its timer) go away.
    func flushDirtyViewer(_ tab: Tab) {
        (tab.content as? FileViewerPaneContent)?.flushIfDirty()
    }

    func forceCloseTab(_ tab: Tab, alreadyTerminated: Bool = false) {
        guard store.tab(withId: tab.id) != nil else { return }
        flushDirtyViewer(tab)
        if store.tabs.count == 1 {
            teardownAndClose(alreadyTerminated: alreadyTerminated)
            return
        }
        store.rememberClosed(savedTab(for: tab))
        if let pane = tab.pane {
            let wasFocused = focusedPane() === pane
            if let fallback = store.mruBackgroundTab(inHome: pane, excluding: tab) {
                pane.display(fallback)
                store.touchMRU(fallback)
                if wasFocused { focusPane(pane) }
            } else {
                // This pane owned only the closing tab, so its viewport has
                // nothing left to show: it dissolves and its space returns to
                // its neighbors.
                tab.pane = nil
                tab.content.pane = nil
                tab.homePane = nil
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

    func teardownAndClose(alreadyTerminated: Bool = false) {
        for tab in store.tabs {
            flushDirtyViewer(tab)
        }
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

    // Removes a viewport from the split tree. Any tabs the pane still owns move
    // to a surviving pane (dissolving a viewport never closes tabs) — unless the
    // caller already unlinked them (a closed tab clears its own homePane first).
    // `absorbInto` names the destination explicitly (merge keeps one pane).
    func dissolvePane(_ pane: Pane, absorbInto explicitDest: Pane? = nil) {
        if let dest = explicitDest ?? absorbTarget(excluding: pane) {
            absorbOwnedTabs(from: pane, into: dest)
        }
        pane.teardown()
        if let parentSplit = pane.container.superview as? NSSplitView {
            if let sibling = detachFromPaneTree(pane.container, parentSplit: parentSplit),
               let nextFocus = firstPane(in: sibling) {
                window.makeFirstResponder(nextFocus.focusTarget)
            }
        }
        panes.removeAll { $0 === pane }
        updateBorderVisibility()
        reloadStrip()
    }

    // MARK: - Window closing

    // The whole-window confirmation, shared by ⌘W on the window's last tab and
    // the close button (windowShouldClose). Unlike confirmTermination it also
    // fires with nothing running, since losing a whole window (or the app,
    // when it's the last window) deserves a warning even when every tab is an
    // idle shell.
    func confirmCloseWindow(processNames: [String]) -> Bool {
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
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
            self.themeObserver = nil
        }
        appDelegate.windowControllerDidClose(self)
    }
}
