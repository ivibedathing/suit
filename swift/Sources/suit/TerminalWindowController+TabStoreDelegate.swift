import Cocoa

// Conforms TerminalWindowController to TabStoreDelegate: it reacts to tab
// changes, process exits (closing clean exits, keeping failed ones red, and
// deferring Autopilot worker tabs to AutopilotEngine), and attention requests
// by refreshing the tab bars and pane chrome.
extension TerminalWindowController: TabStoreDelegate {

    func tabDidChange(_ tab: Tab) {
        refreshTabSurfaces()
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
        refreshTabSurfaces()
        tab.pane?.refreshChrome()
        // Autopilot's worker tab: the engine owns what a
        // death means (§2.7 one --continue respawn, then blocked) and the
        // scrollback must survive for debugging — skip the clean-exit close.
        if let engine = AutopilotManager.shared.engineOwningTab(withId: tab.id) {
            engine.workerTabExited(tab)
            return
        }
        guard tab.exitStatus?.isClean == true else { return }
        DispatchQueue.main.async { [weak self, weak tab] in
            guard let self, let tab, self.store.tab(withId: tab.id) != nil else { return }
            self.forceCloseTab(tab, alreadyTerminated: true)
        }
    }

    // A visible tab's bell flashes its pane (Pane.flashForBell); for a
    // background tab, repainting the tab surfaces keeps its state dot current.
    func tabWantsAttention(_ tab: Tab) {
        refreshTabSurfaces()
    }
}
