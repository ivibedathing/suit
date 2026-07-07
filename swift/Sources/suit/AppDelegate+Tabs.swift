import Cocoa

extension AppDelegate {
    // MARK: - Cross-window tab plumbing (browser-tab model)

    // Resolves a dragged tab id to its window and tab, across every window.
    func controllerAndTab(withId id: String) -> (TerminalWindowController, Tab)? {
        for controller in windowControllers {
            if let tab = controller.store.tab(withId: id) {
                return (controller, tab)
            }
        }
        return nil
    }

    // A tab dragged out of every Suit window (or "Move Tab to New Window"):
    // it becomes its own window at the drop point, process and state intact.
    func tearOffTab(withId id: String, at screenPoint: NSPoint) {
        guard let (source, tab) = controllerAndTab(withId: id) else { return }
        // A window's only tab torn off would just recreate the same window.
        guard source.store.tabs.count > 1 else { return }
        // The new window's project (sidebar, Cmd-P) should be the tab's own.
        let startDirectory = tab.content.workingDirectory ?? savedWorkingDirectory()
        source.release(tab)
        let controller = TerminalWindowController(
            appDelegate: self,
            startDirectory: startDirectory,
            adopting: tab
        )
        windowControllers.append(controller)
        controller.window.setFrameTopLeftPoint(screenPoint)
        controller.window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Tab & pane actions (dispatched to whichever window is key)

    @objc func renameTab(_ sender: Any?) {
        activeWindowController()?.renameActiveTab()
    }

    // ⌘D: Split Screen with a fresh terminal tab (in the focused pane's cwd).
    // Splitting with an *existing* tab stays available via the strip's context
    // menu and the palette's last-used-tab / picker entries.
    @objc func splitScreen(_ sender: Any?) {
        activeWindowController()?.splitScreenWithNewTerminal()
    }

    // ⇧⌘D: like ⌘D but always stacks the fresh terminal below (horizontal split),
    // regardless of the pane's shape.
    @objc func splitScreenHorizontally(_ sender: Any?) {
        activeWindowController()?.splitScreenWithNewTerminal(forcedOrientation: .horizontal)
    }

    @objc func splitScreenWithLastUsedTab(_ sender: Any?) {
        activeWindowController()?.splitScreenWithMRUTab()
    }

    // Palette: pick which background tab to split the screen with.
    func splitScreenWithPicker() {
        guard let controller = activeWindowController() else {
            NSSound.beep()
            return
        }
        let tabs = controller.backgroundTabs()
        guard !tabs.isEmpty else {
            NSSound.beep()
            return
        }
        let commands = tabs.map { tab in
            PaletteCommand(title: tab.title, shortcut: "split screen") { [weak controller, weak tab] in
                guard let controller, let tab else { return }
                controller.splitScreen(with: tab)
            }
        }
        commandPalette.show(relativeTo: controller.window, commands: commands, placeholder: "Split screen with…")
    }

    // ⌃⌘M ("Unsplit All"): back to one viewport; displaced tabs stay open in
    // the strip.
    @objc func mergeAllPanes(_ sender: Any?) {
        activeWindowController()?.mergeAllPanes()
    }

    // ⌘W: close the active tab; the window's last tab closes the window.
    @objc func closeTab(_ sender: Any?) {
        activeWindowController()?.closeActiveTab()
    }

    // ⌥⌘W ("Unsplit"): dissolve the focused viewport; its tab stays in the strip.
    @objc func closePane(_ sender: Any?) {
        activeWindowController()?.closeFocusedPaneKeepTab()
    }

    // ⌘⇧] / ⌘⇧[: strip-order tab cycling.
    @objc func nextTab(_ sender: Any?) {
        activeWindowController()?.activateAdjacentTab(1)
    }

    @objc func previousTab(_ sender: Any?) {
        activeWindowController()?.activateAdjacentTab(-1)
    }

    // ⌃Tab / ⌃⇧Tab: the MRU switcher overlay.
    @objc func cycleRecentTabs(_ sender: Any?) {
        activeWindowController()?.cycleMRUTab(forward: true)
    }

    @objc func cycleRecentTabsBack(_ sender: Any?) {
        activeWindowController()?.cycleMRUTab(forward: false)
    }

    // ⌘1..9 (menu tag = tab number, ⌘9 = last tab, browser rule).
    @objc func goToTab(_ sender: NSMenuItem) {
        activeWindowController()?.activateTab(number: sender.tag)
    }

    // ⌥⌘ arrows (menu tag encodes the direction).
    @objc func focusPaneDirection(_ sender: NSMenuItem) {
        let directions: [PaneDirection] = [.left, .right, .up, .down]
        guard directions.indices.contains(sender.tag) else { return }
        activeWindowController()?.focusPane(direction: directions[sender.tag])
    }

    // Palette: keep the preview tab's file open / pin the active tab.
    @objc func keepPreviewTab(_ sender: Any?) {
        activeWindowController()?.keepActiveTab()
    }

    @objc func togglePinTab(_ sender: Any?) {
        activeWindowController()?.togglePinActiveTab()
    }

    // The palette shown with every open tab in the key window — fuzzy-jump to
    // anything open, visible or backgrounded.
    @objc func showTabPalette(_ sender: Any?) {
        guard let controller = activeWindowController() else {
            NSSound.beep()
            return
        }
        commandPalette.show(relativeTo: controller.window, commands: controller.tabPaletteCommands(), placeholder: "Go to tab…")
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleWordWrap(_:)) {
            menuItem.state = wordWrapEnabled ? .on : .off
            return true
        }
        guard menuItem.action == #selector(goToTab(_:)) else { return true }
        let count = activeWindowController()?.store.tabs.count ?? 0
        // ⌘9 = last tab, enabled whenever anything is open at all.
        return menuItem.tag >= 9 ? count > 0 : menuItem.tag <= count
    }
}
