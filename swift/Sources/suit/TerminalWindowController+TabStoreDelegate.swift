import Cocoa

// The TabStoreDelegate conformance split out of TerminalWindowController.swift:
// the window's policy for tab changes, process exits, and attention flashes.
extension TerminalWindowController: TabStoreDelegate {
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
}
