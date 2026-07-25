import Cocoa

// The window's left panel, toggled with Cmd-B: Files / Search / Sessions /
// SSH Hosts / Notes (in that order — see `railOrder`), picked from the
// ActivityBarView strip to its left. The icons used to be a horizontal rail
// inside this view's own top edge; they moved out to the activity bar so they
// survive a Cmd-B collapse, but the tab *model* stayed here — this view still
// owns the enum, the rail order and the persisted selection, and the bar is a
// dumb renderer of `selectedTab`. The Files tab is the FileBrowserView, whole;
// Search is the SearchView (project-wide find and replace), which used to be an
// overlay over that tree and is now its own tab directly below it. Sessions
// hosts the SessionsView (the open-tabs overview), SSH the SSHHostsView, and
// Notes the NotesView. Git and Bookmarks have no rail tab; their GitView and
// BookmarksView are reached on demand through the palette (see `railOrder`).
final class SidebarView: NSView {
    static let defaultWidth: CGFloat = 240
    static let minWidth: CGFloat = 180
    static let maxWidth: CGFloat = 420

    enum Tab: Int, CaseIterable {
        case files
        case notes
        // Appended (not declared in rail order) so persisted rawValues from
        // earlier builds keep meaning the same tab; railOrder places them.
        case git
        case ssh
        case bookmarks
        case sessions
        case search

        // The activity bar's top-to-bottom icon order, independent of rawValue.
        // Files leads (the primary surface) with Search directly under it — the
        // two halves of one job, and where the eye goes when the tree isn't
        // enough — then Sessions (the open-tabs list, the replacement for the
        // removed top tab strip), SSH, Notes.
        // Git is intentionally absent — its changes/worktrees no longer get a
        // dedicated icon; the branch/worktree switcher lives on the Files
        // footer, and the diff / file-history / feedback / PR-inbox surfaces
        // are reached on demand through the palette (which still shows the
        // GitView via showGit()). Bookmarks is absent for the same reason: the
        // marks themselves live in the viewer gutter where they are made, so
        // the list is a palette destination ("Show Bookmarks" / showBookmarks())
        // rather than a permanent icon.
        static let railOrder: [Tab] = [.files, .search, .sessions, .ssh, .notes]

        // Tooltip / accessibility label; the activity bar shows only the icon.
        var label: String {
            switch self {
            case .files: return "Files"
            case .search: return "Search"
            case .notes: return "Notes"
            case .git: return "Git"
            case .ssh: return "SSH Hosts"
            case .bookmarks: return "Bookmarks"
            case .sessions: return "Sessions"
            }
        }

        var symbolName: String {
            switch self {
            case .files: return "folder"
            case .search: return "magnifyingglass"
            case .notes: return "square.and.pencil"
            case .git: return "arrow.triangle.branch"
            case .ssh: return "server.rack"
            case .bookmarks: return "bookmark"
            case .sessions: return "rectangle.stack"
            }
        }

        var icon: NSImage {
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 20, weight: .medium))
            image?.isTemplate = true
            return image ?? NSImage()
        }
    }

    // Read by the controller to seed the activity bar's initial highlight: the
    // restore below sets this directly rather than through select(tab:), so
    // onTabChange never fires for it and the bar can't learn it any other way.
    private(set) var selectedTab: Tab = .files

    // Fired on every select(tab:) so the activity bar can follow. Not fired for
    // the init-time restore — see selectedTab.
    var onTabChange: ((Tab) -> Void)?
    // Fired when a tab switch would have stranded the caret inside the tab that
    // just went away; the controller hands focus back to a pane. See
    // moveFocusOutOfHiddenTabs().
    var onFocusEscaped: (() -> Void)?
    let fileBrowser = FileBrowserView(frame: .zero)
    let searchView = SearchView(frame: .zero)
    let notesView = NotesView(frame: .zero)
    let gitView = GitView(frame: .zero)
    let sshHostsView = SSHHostsView(frame: .zero)
    let bookmarksView = BookmarksView(frame: .zero)
    let sessionsView = SessionsView(frame: .zero)
    let recentFolders = RecentFoldersView(frame: .zero)
    let usageFooter = ClaudeUsageFooterView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // Flat bar chrome, replacing the .sidebar vibrancy — the
        // left rail is part of the same dark world as the strip and headers.
        wantsLayer = true
        layer?.backgroundColor = Theme.barChrome.cgColor

        // A stale persisted value (e.g. from a build with more tabs, or the
        // icon-less Git tab) falls back to Files rather than landing on a
        // tab with no icon in the activity bar to switch back from.
        let saved = UserDefaults.standard.integer(forKey: "sidebarTab")
        let restored = Tab(rawValue: saved) ?? .files
        selectedTab = Tab.railOrder.contains(restored) ? restored : .files

        // The tree and search are siblings now, one tab each. The browser
        // header's magnifier is a second way onto the Search tab (⌘⇧F is the
        // other), and Escape on an empty search field walks back to the tree.
        fileBrowser.onSearch = { [weak self] in self?.showSearch() }
        searchView.onDismiss = { [weak self] in self?.select(tab: .files) }
        addSubview(fileBrowser)
        addSubview(searchView)
        addSubview(notesView)
        addSubview(gitView)
        addSubview(sshHostsView)
        addSubview(bookmarksView)
        addSubview(sessionsView)

        // The project switcher sits below the tab content, on every tab, and
        // the Claude Code usage footer sits at the very bottom below it.
        addSubview(recentFolders)
        recentFolders.onHeightChange = { [weak self] in self?.layoutContents() }
        addSubview(usageFooter)
        usageFooter.onHeightChange = { [weak self] in self?.layoutContents() }

        updateTabContent()
    }

    // Switches to the Search tab and focuses its pattern field (Cmd-Shift-F, the
    // Files header's magnifier); the caller unhides the sidebar first if needed.
    func showSearch() {
        select(tab: .search)
        searchView.focusSearchField()
    }

    func select(tab: Tab) {
        selectedTab = tab
        UserDefaults.standard.set(tab.rawValue, forKey: "sidebarTab")
        updateTabContent()
        onTabChange?(tab)
    }

    // Live theme switch: re-set the flat ground baked in at init; the rest of
    // the sidebar's draw-based chrome is repainted by the controller's
    // recursive needsDisplay sweep. The activity bar re-tints its own icons —
    // applyTheme() calls it alongside this. The Search tab's controls carry
    // tints set at init for the same reason, so they are re-read here too.
    func reapplyTheme() {
        layer?.backgroundColor = Theme.barChrome.cgColor
        searchView.reapplyTheme()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContents()
    }

    // Manual layout, consistent with the pane tree around it (Auto Layout and
    // NSSplitView's frame management don't mix well — see SettingsWindowController).
    private func layoutContents() {
        let usageHeight = usageFooter.desiredHeight
        usageFooter.frame = NSRect(x: 0, y: 0, width: bounds.width, height: usageHeight)
        let foldersHeight = recentFolders.isHidden ? 0 : recentFolders.desiredHeight
        recentFolders.frame = NSRect(x: 0, y: usageHeight, width: bounds.width, height: foldersHeight)
        let footerHeight = usageHeight + foldersHeight
        // Tab content now runs to the top edge: the icons that used to reserve
        // a band up there live in the activity bar beside this view.
        let contentFrame = NSRect(
            x: 0,
            y: footerHeight,
            width: bounds.width,
            height: max(0, bounds.height - footerHeight)
        )
        fileBrowser.frame = contentFrame
        searchView.frame = contentFrame
        notesView.frame = contentFrame
        gitView.frame = contentFrame
        sshHostsView.frame = contentFrame
        bookmarksView.frame = contentFrame
        sessionsView.frame = contentFrame
    }

    private func updateTabContent() {
        fileBrowser.isHidden = selectedTab != .files
        searchView.isHidden = selectedTab != .search
        notesView.isHidden = selectedTab != .notes
        gitView.isHidden = selectedTab != .git
        sshHostsView.isHidden = selectedTab != .ssh
        bookmarksView.isHidden = selectedTab != .bookmarks
        sessionsView.isHidden = selectedTab != .sessions
        // Notes and Bookmarks are keyboard-navigable lists: selecting the tab
        // should land on the list so ↑↓/Return work without a click. (Notes no
        // longer holds an editor — a note opens as its own file tab.)
        if selectedTab == .notes {
            window?.makeFirstResponder(notesView.focusTarget)
        } else if selectedTab == .bookmarks {
            window?.makeFirstResponder(bookmarksView.focusTarget)
        } else if selectedTab == .search {
            // Landing on Search with the caret anywhere else would mean clicking
            // the icon and then having to click the field as well.
            searchView.focusSearchField()
        }
        moveFocusOutOfHiddenTabs()
    }

    // A hidden view keeps first responder, so a tab switch that leaves the caret
    // in the tab that just disappeared swallows every keystroke after it — which
    // is why the old search overlay moved focus as it closed, and matters more now
    // that the Search tab's fields are permanent rather than summoned. Notes and
    // Bookmarks have already claimed the caret by here, so this only fires for the
    // tabs that don't want it, and it asks the controller (which owns focus) where
    // it should go rather than deciding for itself.
    private func moveFocusOutOfHiddenTabs() {
        guard let window else { return }
        guard let responder = window.firstResponder as? NSView else {
            // Hiding a field mid-edit ends the edit and drops first responder to
            // the *window*: nothing swallows the keystrokes, but nothing receives
            // them either — the terminal stays dead until you click it.
            onFocusEscaped?()
            return
        }
        guard responder.isDescendant(of: self), responder.isHiddenOrHasHiddenAncestor else { return }
        onFocusEscaped?()
    }
}
