import Cocoa

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
