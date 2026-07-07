import Cocoa

// One icon in the sidebar's tab rail: a flat hover-square in the artifact
// language (hover #262A31, amber-tinted selection, accent icon when selected)
// — the native NSSegmentedControl read as aqua chrome, not the mockup's rail.
private final class RailIconView: NSView {
    static let size: CGFloat = 26

    let tab: SidebarView.Tab
    var onClick: ((SidebarView.Tab) -> Void)?

    var isSelected = false {
        didSet {
            iconView.contentTintColor = isSelected ? Theme.accent : Theme.textDim
            needsDisplay = true
        }
    }
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    private let iconView = NSImageView(frame: .zero)

    init(tab: SidebarView.Tab) {
        self.tab = tab
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        toolTip = tab.label
        iconView.image = tab.icon
        iconView.contentTintColor = Theme.textDim
        let iconSize: CGFloat = 16
        iconView.frame = NSRect(
            x: (Self.size - iconSize) / 2, y: (Self.size - iconSize) / 2,
            width: iconSize, height: iconSize
        )
        addSubview(iconView)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tab.label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected || isHovered else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        (isSelected ? Theme.selection : Theme.hover).setFill()
        path.fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?(tab)
        }
    }
}

// One clickable folder row in the sidebar's bottom project switcher: folder
// icon + name, hover fill, accent tint on the root the sidebar currently
// shows. Right-click offers removal from the list.
private final class RecentFolderRowView: NSView {
    static let height: CGFloat = 24

    let path: String
    var onClick: ((String) -> Void)?
    var onRemove: ((String) -> Void)?

    var isCurrent = false {
        didSet {
            iconView.contentTintColor = isCurrent ? Theme.accent : Theme.textDim
            nameLabel.textColor = isCurrent ? Theme.textPrimary : Theme.textDim
            needsDisplay = true
        }
    }
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    private let iconView = NSImageView(frame: .zero)
    private let nameLabel = NSTextField(labelWithString: "")

    init(path: String) {
        self.path = path
        super.init(frame: .zero)
        toolTip = (path as NSString).abbreviatingWithTildeInPath

        let image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        image?.isTemplate = true
        iconView.image = image
        iconView.contentTintColor = Theme.textDim
        addSubview(iconView)

        nameLabel.stringValue = (path as NSString).lastPathComponent
        nameLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        nameLabel.textColor = Theme.textDim
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        setAccessibilityRole(.button)
        setAccessibilityLabel(nameLabel.stringValue)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: 8, y: (bounds.height - 13) / 2, width: 14, height: 13)
        nameLabel.frame = NSRect(x: 27, y: (bounds.height - 15) / 2, width: max(0, bounds.width - 33), height: 15)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5)
        Theme.hover.setFill()
        path.fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?(path)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let remove = menu.addItem(withTitle: "Remove from Recent Folders", action: #selector(removeFromMenu), keyEquivalent: "")
        remove.target = self
        return menu
    }

    @objc private func removeFromMenu() {
        onRemove?(path)
    }
}

// The sidebar's bottom strip: the most recently shown project roots (pinned
// folders and followed pane projects, from FavoritesStore.recentFolders), one
// click away regardless of which sidebar tab is up — the project switcher.
final class RecentFoldersView: NSView {
    private static let maxRows = 5
    private static let headerHeight: CGFloat = 16
    private static let padding: CGFloat = 6

    // Receives an absolute directory path; the window controller pins the
    // Files tab to it.
    var onSelect: ((String) -> Void)?
    // The layout around this view depends on desiredHeight; poked when the
    // row count changes (SidebarView re-runs its manual layout).
    var onHeightChange: (() -> Void)?

    // The root the sidebar currently shows, highlighted in the list.
    var currentRoot: String? {
        didSet {
            for row in rowViews {
                row.isCurrent = row.path == currentRoot
            }
        }
    }

    private let headerLabel = NSTextField(labelWithString: "Recent Folders")
    private var rowViews: [RecentFolderRowView] = []

    var desiredHeight: CGFloat {
        rowViews.isEmpty
            ? 0
            : Self.padding + Self.headerHeight + CGFloat(rowViews.count) * RecentFolderRowView.height + Self.padding
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        headerLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        headerLabel.textColor = Theme.textFaint
        addSubview(headerLabel)

        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: FavoritesStore.didUpdate, object: nil
        )
        storeChanged()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func storeChanged() {
        let folders = Array(FavoritesStore.shared.recentFolders.prefix(Self.maxRows))
        // Hidden even when the row set hasn't changed: an empty view has zero
        // height, but its header would still draw below its frame (views
        // don't clip) — onto whatever sits underneath.
        isHidden = folders.isEmpty
        guard folders != rowViews.map(\.path) else { return }
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = folders.map { path in
            let row = RecentFolderRowView(path: path)
            row.isCurrent = path == currentRoot
            row.onClick = { [weak self] path in self?.onSelect?(path) }
            row.onRemove = { path in FavoritesStore.shared.removeRecentFolder(path) }
            addSubview(row)
            return row
        }
        isHidden = rowViews.isEmpty
        needsLayout = true
        needsDisplay = true
        onHeightChange?()
    }

    override func layout() {
        super.layout()
        headerLabel.frame = NSRect(
            x: 10, y: bounds.height - Self.padding - Self.headerHeight + 2,
            width: max(0, bounds.width - 20), height: 13
        )
        var y = bounds.height - Self.padding - Self.headerHeight - RecentFolderRowView.height
        for row in rowViews {
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: RecentFolderRowView.height)
            y -= RecentFolderRowView.height
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    // Hairline along the top, separating the strip from the tab content.
    override func draw(_ dirtyRect: NSRect) {
        Theme.hairline.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

// One line of the usage footer: limit name, a thin fill bar, and the used %.
private final class UsageRowView: NSView {
    static let height: CGFloat = 18

    private let nameLabel = NSTextField(labelWithString: "")
    private let pctLabel = NSTextField(labelWithString: "")
    private var pct: Double?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        nameLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        nameLabel.textColor = Theme.textDim
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        pctLabel.font = Theme.usageFont
        pctLabel.alignment = .right
        addSubview(pctLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(name: String, pct: Double?) {
        nameLabel.stringValue = name
        self.pct = pct
        if let pct {
            pctLabel.stringValue = "\(Int(pct.rounded()))%"
            pctLabel.textColor = Theme.usageLevelColor(pct)
        } else {
            pctLabel.stringValue = "—"
            pctLabel.textColor = Theme.textFaint
        }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        nameLabel.frame = NSRect(x: 10, y: (bounds.height - 13) / 2, width: 74, height: 13)
        pctLabel.frame = NSRect(x: bounds.width - 44, y: (bounds.height - 13) / 2, width: 34, height: 13)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    // The fill bar between the name and the percentage.
    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(
            x: 88, y: (bounds.height - 3) / 2,
            width: max(0, bounds.width - 88 - 48), height: 3
        )
        guard track.width > 12 else { return }
        Theme.hover.setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
        guard let pct else { return }
        let fill = NSRect(
            x: track.minX, y: track.minY,
            width: track.width * CGFloat(min(max(pct, 0), 100)) / 100, height: track.height
        )
        Theme.usageLevelColor(pct).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

// Autopilot's one-line status in the sidebar footer (ROADMAP Phase 32,
// §2.11): a session-state dot plus the engine's composed status string
// ("Autopilot · next run ~03:40" / "⚙ Phase 23 · gate: build" / …), tooltip =
// the full reason. Hidden while Autopilot is disabled; clicking focuses the
// run tab while a run is active and opens the log otherwise (the footer
// owns that dispatch — see renderAutopilot()).
final class AutopilotRowView: NSView {
    static let height: CGFloat = 18

    var onClick: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private var dotColor: NSColor = Theme.textFaint

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        label.textColor = Theme.textDim
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, tooltip: String, dotColor: NSColor) {
        label.stringValue = text
        toolTip = tooltip.isEmpty ? nil : tooltip
        self.dotColor = dotColor
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(
            x: 22, y: (bounds.height - 13) / 2,
            width: max(0, bounds.width - 22 - 10), height: 13
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    // The state dot, aligned with the usage rows' name column.
    override func draw(_ dirtyRect: NSRect) {
        let dot = NSRect(x: 10, y: (bounds.height - 6) / 2, width: 6, height: 6)
        dotColor.setFill()
        NSBezierPath(ovalIn: dot).fill()
    }
}

// The sidebar's bottom-most strip: Claude Code's global rate-limit usage
// (5h window, all-models week, and any model-scoped weeklies the statusline
// reports, e.g. Fable) plus a gear that opens the Claude Code integration
// settings. Rows show "—" until a fresh claude-status.json exists (the
// statusline script only writes while Claude Code runs). The Autopilot status
// row (Phase 32) sits above the usage rows when Autopilot is enabled.
final class ClaudeUsageFooterView: NSView {
    private static let headerHeight: CGFloat = 16
    private static let padding: CGFloat = 6

    // Opens "Install Claude Code Integration…" (the window controller routes
    // to AppDelegate).
    var onOpenSettings: (() -> Void)?
    // Autopilot row clicks (Phase 32): focus the run tab while running, open
    // the log otherwise (both route to AppDelegate via the window controller).
    var onAutopilotFocusRunTab: (() -> Void)?
    var onAutopilotOpenLog: (() -> Void)?
    // Same contract as RecentFoldersView: poke the sidebar's manual layout
    // when the row count changes.
    var onHeightChange: (() -> Void)?

    private let headerLabel = NSTextField(labelWithString: "Claude Code")
    private let settingsButton = NSButton(frame: .zero)
    private let autopilotRow = AutopilotRowView(frame: .zero)
    private var rowViews: [UsageRowView] = []
    // (name, pct) per visible row; nil pct renders as "—".
    private var rows: [(String, Double?)] = [("5h", nil), ("Week", nil)]

    var desiredHeight: CGFloat {
        let autopilotHeight = autopilotRow.isHidden ? 0 : AutopilotRowView.height
        return Self.padding + Self.headerHeight + autopilotHeight
            + CGFloat(rows.count) * UsageRowView.height + Self.padding
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        headerLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        headerLabel.textColor = Theme.textFaint
        addSubview(headerLabel)

        settingsButton.isBordered = false
        settingsButton.bezelStyle = .regularSquare
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Claude Code Settings")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        settingsButton.contentTintColor = Theme.textDim
        settingsButton.toolTip = "Install / update the Claude Code integration"
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        addSubview(settingsButton)

        // The Autopilot status row (Phase 32), above the usage rows; hidden
        // (and excluded from desiredHeight) while Autopilot is disabled.
        autopilotRow.isHidden = true
        autopilotRow.onClick = { [weak self] in
            if case .running = AutopilotEngine.shared.state {
                self?.onAutopilotFocusRunTab?()
            } else {
                self?.onAutopilotOpenLog?()
            }
        }
        addSubview(autopilotRow)

        NotificationCenter.default.addObserver(
            self, selector: #selector(monitorChanged),
            name: ClaudeSessionMonitor.didUpdate, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(autopilotChanged),
            name: AutopilotEngine.didUpdate, object: nil
        )
        render(usage: nil)
        renderAutopilot()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func monitorChanged() {
        render(usage: ClaudeSessionMonitor.shared.usage)
    }

    @objc private func autopilotChanged() {
        renderAutopilot()
    }

    // Mirrors the engine's footer status (§2.11) into the row: visibility,
    // the composed status string, the full reason as tooltip, and a
    // Theme.session* dot color per state kind.
    private func renderAutopilot() {
        let engine = AutopilotEngine.shared
        let wasHidden = autopilotRow.isHidden
        autopilotRow.isHidden = !engine.isActive
        if engine.isActive {
            let status = engine.footerStatus()
            let color: NSColor
            switch status.kind {
            case .idle: color = Theme.textFaint
            case .running: color = Theme.sessionBusy
            case .blocked: color = Theme.failed
            case .paused: color = Theme.sessionNeedsInput
            case .done: color = Theme.sessionDone
            }
            autopilotRow.configure(text: status.text, tooltip: status.tooltip, dotColor: color)
        }
        needsLayout = true
        if wasHidden != autopilotRow.isHidden {
            onHeightChange?()
        }
    }

    // Split from monitorChanged so an offscreen harness can feed a snapshot
    // without writing the user's real ~/.suit/claude-status.json.
    func render(usage: ClaudeUsage?) {
        var next: [(String, Double?)] = [("5h", usage?.fiveHourPct), ("Week", usage?.sevenDayPct)]
        for weekly in usage?.modelWeeklies ?? [] {
            next.append(("Week · \(weekly.name)", weekly.pct))
        }
        let countChanged = next.count != rowViews.count
        rows = next

        if countChanged {
            rowViews.forEach { $0.removeFromSuperview() }
            rowViews = rows.map { _ in
                let row = UsageRowView(frame: .zero)
                addSubview(row)
                return row
            }
        }
        for (row, view) in zip(rows, rowViews) {
            view.configure(name: row.0, pct: row.1)
        }
        needsLayout = true
        if countChanged {
            onHeightChange?()
        }
    }

    override func layout() {
        super.layout()
        headerLabel.frame = NSRect(
            x: 10, y: bounds.height - Self.padding - Self.headerHeight + 2,
            width: max(0, bounds.width - 40), height: 13
        )
        settingsButton.frame = NSRect(
            x: bounds.width - 26, y: bounds.height - Self.padding - Self.headerHeight + 1,
            width: 16, height: 15
        )
        var y = bounds.height - Self.padding - Self.headerHeight
        if !autopilotRow.isHidden {
            y -= AutopilotRowView.height
            autopilotRow.frame = NSRect(x: 0, y: y, width: bounds.width, height: AutopilotRowView.height)
        }
        for row in rowViews {
            y -= UsageRowView.height
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: UsageRowView.height)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    // Hairline along the top, like the Recent Folders strip above it.
    override func draw(_ dirtyRect: NSRect) {
        Theme.hairline.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

// The window's left rail, toggled with Cmd-B: Files / Git / Notes, picked
// via an icon rail (ROADMAP Phase 9 — text segments don't scale in a
// 180–420pt sidebar; restyled to the mockup's flat hover-square icons in the
// Phase 15 fidelity work). The Files tab is the SearchView (Phase 2) with its
// search input on top and the FileBrowserView (Phase 1) filling the area below
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

        // The rail's left-to-right icon order, independent of rawValue.
        static let railOrder: [Tab] = [.files, .git, .bookmarks, .ssh, .notes]

        // Tooltip / accessibility label; the rail shows only the icon.
        var label: String {
            switch self {
            case .files: return "Files"
            case .notes: return "Notes"
            case .git: return "Git"
            case .ssh: return "SSH Hosts"
            case .bookmarks: return "Bookmarks"
            }
        }

        var symbolName: String {
            switch self {
            case .files: return "folder"
            case .notes: return "note.text"
            case .git: return "arrow.triangle.branch"
            case .ssh: return "network"
            case .bookmarks: return "bookmark"
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
    let recentFolders = RecentFoldersView(frame: .zero)
    let usageFooter = ClaudeUsageFooterView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // Flat bar chrome (Phase 11), replacing the .sidebar vibrancy — the
        // left rail is part of the same dark world as the strip and headers.
        wantsLayer = true
        layer?.backgroundColor = Theme.barChrome.cgColor

        for tab in Tab.railOrder {
            let icon = RailIconView(tab: tab)
            icon.onClick = { [weak self] tab in self?.select(tab: tab) }
            railIcons.append(icon)
            addSubview(icon)
        }
        // A stale persisted value (e.g. from a build with more tabs) falls
        // back to Files instead of selecting out of range.
        let saved = UserDefaults.standard.integer(forKey: "sidebarTab")
        selectedTab = Tab(rawValue: saved) ?? .files

        // The browser lives inside the search view, which shows it while the
        // search pattern is empty and swaps in results while searching.
        searchView.idleView = fileBrowser
        addSubview(searchView)
        addSubview(notesView)
        addSubview(gitView)
        addSubview(sshHostsView)
        addSubview(bookmarksView)

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
        // Notes is a text surface: selecting it should put the caret there.
        if selectedTab == .notes {
            window?.makeFirstResponder(notesView.focusTarget)
        } else if selectedTab == .bookmarks {
            window?.makeFirstResponder(bookmarksView.focusTarget)
        }
    }
}
