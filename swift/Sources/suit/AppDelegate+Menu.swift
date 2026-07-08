import Cocoa

extension AppDelegate {
    // MARK: - Menu

    func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        let aboutItem = appMenu.addItem(withTitle: "About Suit", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        aboutItem.target = NSApp
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        let integrationItem = appMenu.addItem(withTitle: "Install Claude Code Integration…", action: #selector(installClaudeIntegration(_:)), keyEquivalent: "")
        integrationItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Suit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        let openQuicklyItem = fileMenu.addItem(withTitle: "Open Quickly…", action: #selector(openQuickly(_:)), keyEquivalent: "p")
        openQuicklyItem.target = self
        // ⌘S — responder-chain routed to the focused editable viewer (Phase 37);
        // auto-disabled (and the write no-ops) when no editable file is focused.
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Save", action: #selector(ViewerTextView.saveFile(_:)), keyEquivalent: "s")
        fileMenuItem.submenu = fileMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(PaneTerminalView.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(PaneTerminalView.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())

        // These route through the responder chain to whichever pane is focused, the same
        // way Copy/Paste above do. TerminalView already implements the find bar (overlay,
        // case/regex/whole-word options, next/prev) behind performFindPanelAction(_:) —
        // see SwiftTerm's MacTerminalView.swift — these are just the standard macOS Find
        // menu items/shortcuts/tags (NSFindPanelAction) that trigger it.
        let findItem = editMenu.addItem(withTitle: "Find…", action: #selector(TerminalView.performFindPanelAction(_:)), keyEquivalent: "f")
        findItem.tag = Int(NSFindPanelAction.showFindPanel.rawValue)

        let findNextItem = editMenu.addItem(withTitle: "Find Next", action: #selector(TerminalView.performFindPanelAction(_:)), keyEquivalent: "g")
        findNextItem.tag = Int(NSFindPanelAction.next.rawValue)

        let findPreviousItem = editMenu.addItem(withTitle: "Find Previous", action: #selector(TerminalView.performFindPanelAction(_:)), keyEquivalent: "g")
        findPreviousItem.keyEquivalentModifierMask = [.command, .shift]
        findPreviousItem.tag = Int(NSFindPanelAction.previous.rawValue)

        let useSelectionItem = editMenu.addItem(withTitle: "Use Selection for Find", action: #selector(TerminalView.performFindPanelAction(_:)), keyEquivalent: "e")
        useSelectionItem.tag = Int(NSFindPanelAction.setFindString.rawValue)

        let projectSearchItem = editMenu.addItem(withTitle: "Search in Project…", action: #selector(searchInProject(_:)), keyEquivalent: "f")
        projectSearchItem.keyEquivalentModifierMask = [.command, .shift]
        projectSearchItem.target = self

        editMenu.addItem(.separator())

        // Responder-chain routed: only enabled while a file viewer is focused.
        // Cmd-L rather than the roadmap's Cmd-G, which macOS convention (and
        // the Find items above) already reserve for Find Next.
        editMenu.addItem(withTitle: "Go to Line…", action: #selector(ViewerTextView.goToLine(_:)), keyEquivalent: "l")

        // ⇧⌘L: bookmark the caret's line (ROADMAP Phase 22), routed to the
        // focused viewer through the responder chain.
        let toggleBookmarkItem = editMenu.addItem(withTitle: "Toggle Bookmark", action: #selector(toggleBookmark(_:)), keyEquivalent: "l")
        toggleBookmarkItem.keyEquivalentModifierMask = [.command, .shift]

        editMenuItem.submenu = editMenu

        // The Tabs menu (browser-tab model): one strip per window owns every
        // tab; these commands operate on it.
        let tabMenuItem = NSMenuItem()
        mainMenu.addItem(tabMenuItem)
        let tabMenu = NSMenu(title: "Tabs")

        let newTabItem = tabMenu.addItem(withTitle: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "t")
        newTabItem.target = self

        let reopenTabItem = tabMenu.addItem(withTitle: "Reopen Closed Tab", action: #selector(reopenClosedTab(_:)), keyEquivalent: "t")
        reopenTabItem.keyEquivalentModifierMask = [.command, .shift]
        reopenTabItem.target = self

        tabMenu.addItem(.separator())

        // ⌘W closes the active tab; the window's last tab closes the window.
        let closeTabItem = tabMenu.addItem(withTitle: "Close Tab", action: #selector(closeTab(_:)), keyEquivalent: "w")
        closeTabItem.target = self

        let closePaneItem = tabMenu.addItem(withTitle: "Unsplit (Keep Tab)", action: #selector(closePane(_:)), keyEquivalent: "w")
        closePaneItem.keyEquivalentModifierMask = [.command, .option]
        closePaneItem.target = self

        let renameTabItem = tabMenu.addItem(withTitle: "Rename Tab…", action: #selector(renameTab(_:)), keyEquivalent: "")
        renameTabItem.target = self

        tabMenu.addItem(.separator())

        let nextTabItem = tabMenu.addItem(withTitle: "Next Tab", action: #selector(nextTab(_:)), keyEquivalent: "]")
        nextTabItem.keyEquivalentModifierMask = [.command, .shift]
        nextTabItem.target = self

        let previousTabItem = tabMenu.addItem(withTitle: "Previous Tab", action: #selector(previousTab(_:)), keyEquivalent: "[")
        previousTabItem.keyEquivalentModifierMask = [.command, .shift]
        previousTabItem.target = self

        // ⌃Tab cycles most-recently-used with the switcher overlay (hold ⌃ to
        // pick from the list, tap to toggle between the last two).
        let cycleItem = tabMenu.addItem(withTitle: "Cycle Recent Tabs", action: #selector(cycleRecentTabs(_:)), keyEquivalent: "\t")
        cycleItem.keyEquivalentModifierMask = [.control]
        cycleItem.target = self

        let cycleBackItem = tabMenu.addItem(withTitle: "Cycle Recent Tabs (Back)", action: #selector(cycleRecentTabsBack(_:)), keyEquivalent: "\t")
        cycleBackItem.keyEquivalentModifierMask = [.control, .shift]
        cycleBackItem.target = self

        // ⌘1..9 addresses strip tabs directly; ⌘9 is the last tab (browser rule).
        let goToTabItem = tabMenu.addItem(withTitle: "Go to Tab", action: nil, keyEquivalent: "")
        let goToTabMenu = NSMenu(title: "Go to Tab")
        for i in 1...8 {
            let item = goToTabMenu.addItem(withTitle: "Tab \(i)", action: #selector(goToTab(_:)), keyEquivalent: "\(i)")
            item.target = self
            item.tag = i
        }
        let lastTabItem = goToTabMenu.addItem(withTitle: "Last Tab", action: #selector(goToTab(_:)), keyEquivalent: "9")
        lastTabItem.target = self
        lastTabItem.tag = 9
        goToTabItem.submenu = goToTabMenu

        tabMenuItem.submenu = tabMenu

        // The Screen menu (Phase 13): the main screen shows one tab; splitting
        // it is a tab operation (strip right-click ▸ Split Screen, or drag a
        // tab to an edge), so only unsplit and focus movement live here.
        let paneMenuItem = NSMenuItem()
        mainMenu.addItem(paneMenuItem)
        let paneMenu = NSMenu(title: "Screen")

        // ⌘D: split with a fresh shell; the strip's right-click ▸ Split Screen
        // and the menu's last-used-tab entry cover splitting with existing tabs.
        let splitScreenItem = paneMenu.addItem(withTitle: "Split Screen with New Terminal", action: #selector(splitScreen(_:)), keyEquivalent: "d")
        splitScreenItem.target = self

        let splitScreenHorizontalItem = paneMenu.addItem(withTitle: "Split Screen Horizontally", action: #selector(splitScreenHorizontally(_:)), keyEquivalent: "d")
        splitScreenHorizontalItem.keyEquivalentModifierMask = [.command, .shift]
        splitScreenHorizontalItem.target = self

        let splitScreenMRUItem = paneMenu.addItem(withTitle: "Split Screen with Last Used Tab", action: #selector(splitScreenWithLastUsedTab(_:)), keyEquivalent: "")
        splitScreenMRUItem.target = self

        let mergeItem = paneMenu.addItem(withTitle: "Unsplit All", action: #selector(mergeAllPanes(_:)), keyEquivalent: "m")
        mergeItem.keyEquivalentModifierMask = [.command, .control]
        mergeItem.target = self

        paneMenu.addItem(.separator())

        // ⌥⌘ arrows: directional split focus (tags index PaneDirection).
        let arrows: [(String, String)] = [
            ("Focus Split Left", String(UnicodeScalar(NSLeftArrowFunctionKey)!)),
            ("Focus Split Right", String(UnicodeScalar(NSRightArrowFunctionKey)!)),
            ("Focus Split Above", String(UnicodeScalar(NSUpArrowFunctionKey)!)),
            ("Focus Split Below", String(UnicodeScalar(NSDownArrowFunctionKey)!)),
        ]
        for (tag, (title, key)) in arrows.enumerated() {
            let item = paneMenu.addItem(withTitle: title, action: #selector(focusPaneDirection(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = [.command, .option]
            item.target = self
            item.tag = tag
        }

        paneMenuItem.submenu = paneMenu

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")

        let commandPaletteItem = viewMenu.addItem(withTitle: "Command Palette…", action: #selector(showCommandPalette(_:)), keyEquivalent: "k")
        commandPaletteItem.target = self

        let toggleSidebarItem = viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar(_:)), keyEquivalent: "b")
        toggleSidebarItem.target = self

        // Ctrl-Cmd-D: Cmd-D/Cmd-Shift-D are the split commands.
        let gitDiffItem = viewMenu.addItem(withTitle: "Show Git Diff", action: #selector(showGitDiff(_:)), keyEquivalent: "d")
        gitDiffItem.keyEquivalentModifierMask = [.command, .control]
        gitDiffItem.target = self

        let commitGraphItem = viewMenu.addItem(withTitle: "Show Commit Graph", action: #selector(showCommitGraph(_:)), keyEquivalent: "")
        commitGraphItem.target = self

        let showFleetItem = viewMenu.addItem(withTitle: "Show Fleet", action: #selector(showFleet(_:)), keyEquivalent: "o")
        showFleetItem.keyEquivalentModifierMask = [.command, .shift]
        showFleetItem.target = self

        // Fleet activity feed / daily digest (ROADMAP Phase 38).
        let activityItem = viewMenu.addItem(withTitle: "Show Activity Feed", action: #selector(showActivityFeed(_:)), keyEquivalent: "")
        activityItem.target = self

        // Broadcast one instruction across every live session (ROADMAP Phase 35).
        let broadcastItem = viewMenu.addItem(withTitle: "Broadcast to All Sessions…", action: #selector(broadcastToAllSessions(_:)), keyEquivalent: "")
        broadcastItem.target = self

        let newSessionItem = viewMenu.addItem(withTitle: "New Claude Session", action: #selector(newClaudeSession(_:)), keyEquivalent: "c")
        newSessionItem.keyEquivalentModifierMask = [.command, .control]
        newSessionItem.target = self

        let newTaskItem = viewMenu.addItem(withTitle: "New Claude Task…", action: #selector(newClaudeTask(_:)), keyEquivalent: "t")
        newTaskItem.keyEquivalentModifierMask = [.command, .control]
        newTaskItem.target = self

        let searchTranscriptsItem = viewMenu.addItem(withTitle: "Search Transcripts…", action: #selector(searchTranscripts(_:)), keyEquivalent: "f")
        searchTranscriptsItem.keyEquivalentModifierMask = [.command, .control]
        searchTranscriptsItem.target = self

        // Live slash-command menu + context-bar /compact (ROADMAP Phase 27).
        let slashMenuItem = viewMenu.addItem(withTitle: "Slash Command Menu…", action: #selector(showSlashCommandMenu(_:)), keyEquivalent: "/")
        slashMenuItem.keyEquivalentModifierMask = [.command, .control]
        slashMenuItem.target = self

        let compactFocusedItem = viewMenu.addItem(withTitle: "Compact Focused Session (/compact)", action: #selector(compactFocusedSession(_:)), keyEquivalent: "k")
        compactFocusedItem.keyEquivalentModifierMask = [.command, .control]
        compactFocusedItem.target = self

        viewMenu.addItem(.separator())

        // "=" rather than "+" so plain Cmd-= works without holding Shift; the
        // all-panes variants use the shifted characters ("+", "_") — AppKit's
        // way of spelling Cmd-Shift-= / Cmd-Shift-- as key equivalents.
        let increaseFontItem = viewMenu.addItem(withTitle: "Increase Font Size", action: #selector(increaseFontSize(_:)), keyEquivalent: "=")
        increaseFontItem.target = self

        let decreaseFontItem = viewMenu.addItem(withTitle: "Decrease Font Size", action: #selector(decreaseFontSize(_:)), keyEquivalent: "-")
        decreaseFontItem.target = self

        let increaseAllFontItem = viewMenu.addItem(withTitle: "Increase Font Size (All Panes)", action: #selector(increaseAllFontSizes(_:)), keyEquivalent: "+")
        increaseAllFontItem.target = self

        let decreaseAllFontItem = viewMenu.addItem(withTitle: "Decrease Font Size (All Panes)", action: #selector(decreaseAllFontSizes(_:)), keyEquivalent: "_")
        decreaseAllFontItem.target = self

        let wordWrapItem = viewMenu.addItem(withTitle: "Word Wrap", action: #selector(toggleWordWrap(_:)), keyEquivalent: "")
        wordWrapItem.target = self

        // Blame gutter + file history (ROADMAP Phase 17) — responder-routed to
        // the focused viewer, so both auto-disable when no viewer is focused.
        let toggleBlameItem = viewMenu.addItem(withTitle: "Toggle Blame", action: #selector(ViewerTextView.toggleBlame(_:)), keyEquivalent: "b")
        toggleBlameItem.keyEquivalentModifierMask = [.command, .control]

        viewMenu.addItem(withTitle: "Show File History", action: #selector(ViewerTextView.showFileHistory(_:)), keyEquivalent: "")

        // Time-travel scrubber (ROADMAP Phase 40) — responder-routed to the
        // focused viewer; the check reflects whether it's currently scrubbing.
        let timeTravelItem = viewMenu.addItem(withTitle: "Time Travel", action: #selector(ViewerTextView.toggleTimeTravel(_:)), keyEquivalent: "h")
        timeTravelItem.keyEquivalentModifierMask = [.command, .control]

        // Go to definition / find references (ROADMAP Phase 33) — responder-
        // routed to the focused viewer like blame above.
        let goToDefinitionItem = viewMenu.addItem(withTitle: "Go to Definition", action: #selector(ViewerTextView.goToDefinition(_:)), keyEquivalent: "j")
        goToDefinitionItem.keyEquivalentModifierMask = [.command, .control]

        let findReferencesItem = viewMenu.addItem(withTitle: "Find References", action: #selector(ViewerTextView.findReferences(_:)), keyEquivalent: "r")
        findReferencesItem.keyEquivalentModifierMask = [.command, .control]

        viewMenu.addItem(.separator())

        let increaseOpacityItem = viewMenu.addItem(withTitle: "Increase Opacity", action: #selector(increaseOpacity(_:)), keyEquivalent: "]")
        increaseOpacityItem.target = self

        let decreaseOpacityItem = viewMenu.addItem(withTitle: "Decrease Opacity", action: #selector(decreaseOpacity(_:)), keyEquivalent: "[")
        decreaseOpacityItem.target = self

        let toggleBlurItem = viewMenu.addItem(withTitle: "Toggle Background Blur", action: #selector(toggleBlur(_:)), keyEquivalent: "b")
        toggleBlurItem.keyEquivalentModifierMask = [.command, .shift]
        toggleBlurItem.target = self

        viewMenuItem.submenu = viewMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")

        let newWindowItem = windowMenu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        newWindowItem.target = self

        windowMenuItem.submenu = windowMenu
        // AppKit appends the open-window list to this menu on its own once it's
        // registered as the app's Window menu. (Native window-tab commands
        // don't appear — window.tabbingMode is .disallowed; the strip is the
        // one tab system.)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
