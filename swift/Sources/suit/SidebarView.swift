import Cocoa

// The window's left panel, toggled with Cmd-B: Files / Sessions / SSH Hosts /
// Notes / Bookmarks (in that order — see `railOrder`), picked from the
// ActivityBarView strip to its left. The icons used to be a horizontal rail
// inside this view's own top edge; they moved out to the activity bar so they
// survive a Cmd-B collapse, but the tab *model* stayed here — this view still
// owns the enum, the rail order and the persisted selection, and the bar is a
// dumb renderer of `selectedTab`. The Files tab is the
// SearchView with its search input on top and the FileBrowserView filling the
// area below until a pattern is typed — then results take that space. Sessions
// hosts the SessionsView (the open-tabs overview), SSH the SSHHostsView,
// Notes the NotesView, and Bookmarks the BookmarksView. Git has no rail tab;
// its GitView is reached on demand through the palette (see `railOrder`).
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

        // The activity bar's top-to-bottom icon order, independent of rawValue.
        // Files leads (the primary surface), then Sessions (the open-tabs list,
        // the replacement for the removed top tab strip), SSH, Notes, Bookmarks.
        // Git is intentionally absent — its changes/worktrees no longer get a
        // dedicated icon; the branch/worktree switcher lives on the Files
        // footer, and the diff / file-history / feedback / PR-inbox surfaces
        // are reached on demand through the palette (which still shows the
        // GitView via showGit()).
        static let railOrder: [Tab] = [.files, .sessions, .ssh, .notes, .bookmarks]

        // Tooltip / accessibility label; the activity bar shows only the icon.
        var label: String {
            switch self {
            case .files: return "Files"
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

        // The browser lives inside the search view, which owns the whole tab
        // until search is activated, then drops its bar over the tree and swaps
        // in results. The browser header's magnifier activates search too.
        searchView.idleView = fileBrowser
        fileBrowser.onSearch = { [weak self] in self?.searchView.focusSearchField() }
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

    // Switches to the Files tab and focuses the search field on top of it
    // (Cmd-Shift-F); the caller unhides the sidebar first if needed.
    func showSearch() {
        select(tab: .files)
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
    // applyTheme() calls it alongside this.
    func reapplyTheme() {
        layer?.backgroundColor = Theme.barChrome.cgColor
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
        searchView.frame = contentFrame
        notesView.frame = contentFrame
        gitView.frame = contentFrame
        sshHostsView.frame = contentFrame
        bookmarksView.frame = contentFrame
        sessionsView.frame = contentFrame
    }

    private func updateTabContent() {
        searchView.isHidden = selectedTab != .files
        notesView.isHidden = selectedTab != .notes
        gitView.isHidden = selectedTab != .git
        sshHostsView.isHidden = selectedTab != .ssh
        bookmarksView.isHidden = selectedTab != .bookmarks
        sessionsView.isHidden = selectedTab != .sessions
        // Notes is a text surface: selecting it should put the caret there.
        if selectedTab == .notes {
            window?.makeFirstResponder(notesView.focusTarget)
        } else if selectedTab == .bookmarks {
            window?.makeFirstResponder(bookmarksView.focusTarget)
        }
    }
}
