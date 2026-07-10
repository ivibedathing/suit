import Cocoa

// The window's left rail, toggled with Cmd-B: Files / Git / Notes, picked
// via an icon rail (text segments don't scale in a
// 180–420pt sidebar; restyled to the mockup's flat hover-square icons in the
// fidelity work). The Files tab is the SearchView with its
// search input on top and the FileBrowserView filling the area below
// until a pattern is typed — then results take that space. Git hosts the
// GitView (changes + worktree/branch switcher); Notes hosts the NotesView.
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

        // The rail's left-to-right icon order, independent of rawValue.
        // Sessions leads: it's the replacement for the removed top tab strip.
        // Git is intentionally absent — its changes/worktrees no longer get a
        // dedicated rail tab; the branch/worktree switcher lives on the Files
        // footer, and the diff / file-history / feedback / PR-inbox surfaces
        // are reached on demand through the palette (which still shows the
        // GitView via showGit()).
        static let railOrder: [Tab] = [.sessions, .files, .bookmarks, .ssh, .notes]

        // Tooltip / accessibility label; the rail shows only the icon.
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
            case .notes: return "note.text"
            case .git: return "arrow.triangle.branch"
            case .ssh: return "network"
            case .bookmarks: return "bookmark"
            case .sessions: return "rectangle.stack"
            }
        }

        var icon: NSImage {
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
            image?.isTemplate = true
            return image ?? NSImage()
        }
    }

    private var railIcons: [RailIconView] = []
    private var selectedTab: Tab = .files
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

        for tab in Tab.railOrder {
            let icon = RailIconView(tab: tab)
            icon.onClick = { [weak self] tab in self?.select(tab: tab) }
            railIcons.append(icon)
            addSubview(icon)
        }
        // A stale persisted value (e.g. from a build with more tabs, or the
        // now-railless Git tab) falls back to Files rather than landing on a
        // tab with no icon in the rail to switch back from.
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
        let padding: CGFloat = 10
        let railSize = RailIconView.size
        let gap: CGFloat = 4
        var x = padding
        for icon in railIcons {
            icon.frame = NSRect(x: x, y: bounds.height - railSize - padding, width: railSize, height: railSize)
            x += railSize + gap
        }
        let usageHeight = usageFooter.desiredHeight
        usageFooter.frame = NSRect(x: 0, y: 0, width: bounds.width, height: usageHeight)
        let foldersHeight = recentFolders.isHidden ? 0 : recentFolders.desiredHeight
        recentFolders.frame = NSRect(x: 0, y: usageHeight, width: bounds.width, height: foldersHeight)
        let footerHeight = usageHeight + foldersHeight
        let contentFrame = NSRect(
            x: 0,
            y: footerHeight,
            width: bounds.width,
            height: max(0, bounds.height - railSize - padding * 2 - footerHeight)
        )
        searchView.frame = contentFrame
        notesView.frame = contentFrame
        gitView.frame = contentFrame
        sshHostsView.frame = contentFrame
        bookmarksView.frame = contentFrame
        sessionsView.frame = contentFrame
    }

    private func updateTabContent() {
        for icon in railIcons {
            icon.isSelected = icon.tab == selectedTab
        }
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
