import Cocoa

// A file row: type icon, name label, and an optional right-aligned
// sub-project badge.
final class FileRowView: NSTableCellView {
    let iconView = NSImageView(frame: .zero)
    let nameLabel = NSTextField(labelWithString: "")
    let badgeLabel = NSTextField(labelWithString: "")
    // Git status: M/A/D/R/? letter on files, a dot on
    // directories containing changes.
    let gitLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = Theme.textPrimary
        nameLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(nameLabel)

        badgeLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        badgeLabel.textColor = Theme.textDim
        badgeLabel.alignment = .center
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.backgroundColor = Theme.hover.cgColor
        badgeLabel.layer?.cornerRadius = 3
        addSubview(badgeLabel)

        gitLabel.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        gitLabel.alignment = .center
        addSubview(gitLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        var right = bounds.width - 4
        if !gitLabel.isHidden {
            let gitWidth: CGFloat = 14
            gitLabel.frame = NSRect(x: right - gitWidth, y: (bounds.height - 14) / 2, width: gitWidth, height: 14)
            right -= gitWidth + 2
        }
        if !badgeLabel.isHidden {
            let badgeWidth = badgeLabel.intrinsicContentSize.width + 10
            badgeLabel.frame = NSRect(x: right - badgeWidth, y: (bounds.height - 14) / 2, width: badgeWidth, height: 14)
            right -= badgeWidth + 2
        }
        let iconWidth: CGFloat = 14
        iconView.frame = NSRect(x: 2, y: (bounds.height - 14) / 2, width: iconWidth, height: 14)
        let nameX = 2 + iconWidth + 4
        nameLabel.frame = NSRect(x: nameX, y: (bounds.height - 16) / 2, width: max(0, right - nameX - 4), height: 16)
    }

    func configure(with node: FileNode, gitStatus: Character?) {
        nameLabel.stringValue = node.name
        let icon = FileTreeIcon.image(for: node)
        iconView.image = icon.image
        iconView.contentTintColor = icon.tint
        badgeLabel.isHidden = node.badge == nil
        badgeLabel.stringValue = node.badge.map { " \($0) " } ?? ""
        if let gitStatus {
            gitLabel.isHidden = false
            gitLabel.stringValue = node.isDirectory ? "•" : String(gitStatus)
            gitLabel.textColor = node.isDirectory ? Theme.sessionBusy : GitStatusMonitor.badgeColor(for: gitStatus)
        } else {
            gitLabel.isHidden = true
        }
        needsLayout = true
    }
}

// Row chrome for the Files outline: draws a subtle rounded highlight while the
// mouse is over the row (matching the source-list selection inset), so the row
// under the cursor reads as the click target. Selection is the shared
// amber-tinted ThemedTableRowView fill.
final class HoverRowView: ThemedTableRowView {
    private var hovered = false {
        didSet {
            if hovered != oldValue { needsDisplay = true }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil
        ))
        // Rows scroll and get reused under a stationary cursor without any
        // enter/exit event firing; re-derive the state from the pointer.
        if let window {
            hovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        } else {
            hovered = false
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hovered = false
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hovered = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hovered = false
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard hovered, !isSelected else { return }
        Theme.hover.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

// NSOutlineView that hands right-clicks (anywhere, rows and empty space alike)
// back to the browser so it can build a context menu for the row under the
// cursor — or the root when clicked below the last row.
final class FileOutlineView: NSOutlineView {
    var menuForEvent: ((NSEvent) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        menuForEvent?(event)
    }
}

// The Files tab of the sidebar: the project tree from a FileIndex, refreshed
// on index updates, single click opens a file. Purely a view over the index —
// it owns no scanning or watching of its own.
final class FileBrowserView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let scrollView = NSScrollView(frame: .zero)
    let outlineView = FileOutlineView(frame: .zero)
    // Empty folders the user created here that no indexed file backs; injected
    // into the tree so they show immediately (see FileNode.buildTree). Keyed
    // by path relative to the index root, pruned to still-existing dirs on
    // every rebuild, and reset when the browsed root changes.
    var createdDirectories: Set<String> = []
    private let header = ProjectHeaderView(frame: .zero)
    var rootNodes: [FileNode] = []
    var index: FileIndex?
    // Whether the browsed root was explicitly picked (Select Folder…) rather
    // than derived from the focused pane; display-only — pinning itself lives
    // in the window controller.
    private var isPinned = false

    // Set by the window controller; receives the file's absolute path.
    var onOpenFile: ((String) -> Void)?
    // Header search affordance (⌘⇧F equivalent): reveal the search field over
    // the tree. Wired by the sidebar to its SearchView.
    var onSearch: (() -> Void)? {
        get { header.onSearch }
        set { header.onSearch = newValue }
    }
    // Header actions: open the folder picker / unpin.
    var onChooseFolder: (() -> Void)? {
        get { header.onChooseFolder }
        set { header.onChooseFolder = newValue }
    }
    var onUnpin: (() -> Void)? {
        get { header.onUnpin }
        set { header.onUnpin = newValue }
    }
    // Branch switcher (moved into the header from the removed bottom footer):
    // repoint the sidebar at another worktree, or check out a local branch.
    var onSwitchWorktree: ((String) -> Void)? {
        get { header.onSwitchWorktree }
        set { header.onSwitchWorktree = newValue }
    }
    var onCheckoutBranch: ((_ root: String, _ branch: String) -> Void)? {
        get { header.onCheckoutBranch }
        set { header.onCheckoutBranch = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 20
        outlineView.indentationPerLevel = 12
        outlineView.autoresizesOutlineColumn = false
        outlineView.backgroundColor = .clear
        outlineView.style = .sourceList
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)
        outlineView.doubleAction = #selector(rowDoubleClicked)
        outlineView.menuForEvent = { [weak self] event in self?.contextMenu(for: event) }

        // Drag files between folders (move on disk), in from Finder (copy), and
        // out to Finder (copy) — all keyed off the file URL on the pasteboard.
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask([.copy], forLocal: false)
        outlineView.setDraggingSourceOperationMask([.move, .copy], forLocal: true)

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        addSubview(scrollView)

        addSubview(header)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContents()
    }

    private func layoutContents() {
        let headerHeight = header.preferredHeight
        header.frame = NSRect(x: 0, y: bounds.height - headerHeight, width: bounds.width, height: headerHeight)
        scrollView.frame = NSRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: max(0, bounds.height - headerHeight)
        )
    }

    // Display-only pin state for the header; the window controller owns the
    // actual pinned root and calls configure(index:) with it.
    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        updateHeader()
    }

    private func updateHeader() {
        guard let index else { return }
        header.updateRoot(path: index.root, pinned: isPinned)
    }

    var gitMonitor: GitStatusMonitor?
    // Prepended to node paths when looking up git status: the browsed root's
    // path relative to the repo root ("" when they coincide), since the
    // monitor's paths are repo-root-relative but nodes are index-root-relative.
    var gitPathPrefix = ""

    func configure(index: FileIndex) {
        if let previous = self.index {
            NotificationCenter.default.removeObserver(self, name: FileIndex.didUpdate, object: previous)
        }
        if let previousStatus = gitMonitor {
            NotificationCenter.default.removeObserver(self, name: GitStatusMonitor.didUpdate, object: previousStatus)
        }
        // The injected empty folders belong to one root; drop them when the
        // browser repoints somewhere else.
        if self.index?.root != index.root {
            createdDirectories.removeAll()
        }
        self.index = index
        NotificationCenter.default.addObserver(
            self, selector: #selector(indexUpdated),
            name: FileIndex.didUpdate, object: index
        )
        // Git badges only make sense inside a repo; a plain directory index
        // simply shows none. The monitor is keyed to the repo root even when
        // the index is pinned to a subdirectory, with the offset
        // between the two bridged by gitPathPrefix at lookup time.
        if let gitRoot = FileIndex.gitRoot(of: index.root) {
            let status = GitStatusMonitor.shared(forRoot: gitRoot)
            gitMonitor = status
            gitPathPrefix = index.root == gitRoot ? "" : String(index.root.dropFirst(gitRoot.count + 1)) + "/"
            NotificationCenter.default.addObserver(
                self, selector: #selector(gitStatusUpdated),
                name: GitStatusMonitor.didUpdate, object: status
            )
        } else {
            gitMonitor = nil
            gitPathPrefix = ""
        }
        updateGitFooter()
        updateHeader()
        rebuild()
    }

    @objc private func gitStatusUpdated(_ note: Notification) {
        updateGitFooter()
        outlineView.reloadData()
    }

    private func updateGitFooter() {
        if let gitMonitor {
            header.updateBranch(
                root: gitMonitor.root,
                branch: gitMonitor.currentBranch,
                branches: gitMonitor.branchCount,
                worktrees: gitMonitor.worktreeCount
            )
        } else {
            header.updateBranch(root: nil, branch: nil, branches: 0, worktrees: 0)
        }
        layoutContents()
    }

    @objc private func indexUpdated(_ note: Notification) {
        rebuild()
    }

    func rebuild() {
        guard let index else { return }
        // Drop injected folders the user has since deleted/renamed away, so the
        // set never resurrects a stale row.
        let root = index.root
        createdDirectories = createdDirectories.filter { rel in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: root + "/" + rel, isDirectory: &isDir) && isDir.boolValue
        }
        rootNodes = FileNode.buildTree(from: index, extraDirectories: Array(createdDirectories))
        // Nodes compare by path (see FileNode), so reloadData keeps whatever
        // the user had expanded, even though every node object is new.
        outlineView.reloadData()
    }

    @objc private func rowClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }
        if node.isDirectory {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        } else if let index {
            onOpenFile?(index.root + "/" + node.relativePath)
        }
    }

    // Swallows the double-click's second click: the first already opened the
    // file (files are regular tabs — nothing to promote) or toggled the
    // directory, which must not toggle straight back.
    @objc private func rowDoubleClicked() {}

    // MARK: - Path helpers

    var rootPath: String { index?.root ?? "" }

    // Absolute path for a root-relative node path ("" → the root itself).
    func absolute(_ relativePath: String) -> String {
        relativePath.isEmpty ? rootPath : rootPath + "/" + relativePath
    }

    // Root-relative path for an absolute one under the browsed root, or nil.
    func relative(_ absolutePath: String) -> String? {
        let prefix = rootPath + "/"
        guard absolutePath.hasPrefix(prefix) else { return nil }
        return String(absolutePath.dropFirst(prefix.count))
    }

    // The directory a New File/Folder anchored on `node` should land in: the
    // folder itself, a file's parent, or the root when nothing was clicked.
    func newItemDirectory(for node: FileNode?) -> String {
        guard let node else { return rootPath }
        let rel = node.isDirectory ? node.relativePath : (node.relativePath as NSString).deletingLastPathComponent
        return absolute(rel)
    }
}
