import Cocoa

// One row of the Files outline. NSObject equality/hash follow relativePath so
// NSOutlineView can preserve expansion state across the full-tree rebuilds the
// FSEvents-driven index updates cause.
final class FileNode: NSObject {
    let name: String
    let relativePath: String
    let isDirectory: Bool
    // Sub-project language badge ("go", "js", …) for directories that contain
    // a marker file (see FileIndex.subprojectMarkers).
    var badge: String?
    var children: [FileNode] = []
    // The containing directory node, nil for top-level rows. Used by drag-drop
    // to retarget a drop hovering a file onto its parent folder.
    weak var parent: FileNode?

    init(name: String, relativePath: String, isDirectory: Bool) {
        self.name = name
        self.relativePath = relativePath
        self.isDirectory = isDirectory
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? FileNode else { return false }
        return relativePath == other.relativePath && isDirectory == other.isDirectory
    }

    override var hash: Int {
        relativePath.hashValue &* 31 &+ (isDirectory ? 1 : 0)
    }

    // Builds the display tree from the index's flat sorted path list —
    // directories first, then files, both case-insensitively sorted. Working
    // off the index (rather than live FileManager listings) keeps the browser
    // gitignore-consistent with the fuzzy opener for free. `extraDirectories`
    // are folder paths that hold no indexed files (empty folders the user just
    // created); `git ls-files` never reports those, so the browser injects them
    // itself so a fresh New Folder shows up right away.
    static func buildTree(from index: FileIndex, extraDirectories: [String] = []) -> [FileNode] {
        let root = FileNode(name: "", relativePath: "", isDirectory: true)
        var directories: [String: FileNode] = ["": root]

        func directoryNode(for path: String) -> FileNode {
            if let existing = directories[path] {
                return existing
            }
            let parent = directoryNode(for: (path as NSString).deletingLastPathComponent)
            let node = FileNode(name: (path as NSString).lastPathComponent, relativePath: path, isDirectory: true)
            node.badge = index.subprojectBadges[path]
            node.parent = parent === root ? nil : parent
            directories[path] = node
            parent.children.append(node)
            return node
        }

        for path in index.files {
            let parent = directoryNode(for: (path as NSString).deletingLastPathComponent)
            let node = FileNode(name: (path as NSString).lastPathComponent, relativePath: path, isDirectory: false)
            node.parent = parent === root ? nil : parent
            parent.children.append(node)
        }
        // Materialize empty folders (and their ancestor chains) that no file
        // pulled in. Idempotent: a folder already created from a file is reused.
        for path in extraDirectories where !path.isEmpty {
            _ = directoryNode(for: path)
        }

        func sortChildren(_ node: FileNode) {
            node.children.sort {
                if $0.isDirectory != $1.isDirectory {
                    return $0.isDirectory
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            for child in node.children where child.isDirectory {
                sortChildren(child)
            }
        }
        sortChildren(root)
        return root.children
    }
}

// Small SF-Symbol icons for the Files tree: a folder for directories, a
// per-type tinted symbol for files (by extension, with a few well-known
// filenames special-cased). Images are cached per symbol name; the tint is
// applied by the row's image view, so one template image serves every color.
enum FileTreeIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(for node: FileNode) -> (image: NSImage?, tint: NSColor) {
        let (symbol, tint) = descriptor(for: node)
        if let cached = cache[symbol] {
            return (cached, tint)
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        if let image {
            cache[symbol] = image
        }
        return (image, tint)
    }

    private static func descriptor(for node: FileNode) -> (symbol: String, tint: NSColor) {
        if node.isDirectory {
            return ("folder.fill", .systemBlue)
        }
        let code = "chevron.left.forwardslash.chevron.right"
        switch node.name.lowercased() {
        case "makefile", "dockerfile":
            return ("terminal", .systemGreen)
        default:
            break
        }
        switch (node.name as NSString).pathExtension.lowercased() {
        case "swift":
            return ("swift", .systemOrange)
        case "go":
            return (code, .systemTeal)
        case "js", "jsx", "mjs", "cjs":
            return (code, .systemYellow)
        case "ts", "tsx":
            return (code, .systemBlue)
        case "py":
            return (code, .systemGreen)
        case "rb":
            return (code, .systemRed)
        case "c", "h", "m", "mm", "cpp", "hpp", "cc", "rs", "java", "kt":
            return (code, .systemIndigo)
        case "html", "htm":
            return (code, .systemOrange)
        case "css", "scss", "less":
            return (code, .systemBlue)
        case "sh", "bash", "zsh":
            return ("terminal", .systemGreen)
        case "json":
            return ("curlybraces", .systemYellow)
        case "yaml", "yml", "toml", "ini", "conf", "plist", "xml", "entitlements":
            return ("gearshape", .systemPurple)
        case "md", "markdown", "txt", "rst":
            return ("doc.text", Theme.textDim)
        case "pdf":
            return ("doc.richtext", .systemRed)
        case "csv", "tsv":
            return ("tablecells", .systemGreen)
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "icns", "ico", "bmp", "heic":
            return ("photo", .systemPink)
        case "mp4", "mov", "mkv", "avi":
            return ("film", .systemPink)
        case "mp3", "wav", "flac", "m4a", "aiff":
            return ("music.note", .systemPink)
        case "zip", "tar", "gz", "bz2", "xz", "7z", "jar":
            return ("archivebox", .systemBrown)
        default:
            // Dotfiles (.gitignore, .zshrc, …) read as configuration.
            if node.name.hasPrefix(".") {
                return ("gearshape", .systemPurple)
            }
            return ("doc", Theme.textDim)
        }
    }
}

// A file row: type icon, name label, and an optional right-aligned
// sub-project badge.
private final class FileRowView: NSTableCellView {
    let iconView = NSImageView(frame: .zero)
    let nameLabel = NSTextField(labelWithString: "")
    let badgeLabel = NSTextField(labelWithString: "")
    // Git status (ROADMAP Phase 5): M/A/D/R/? letter on files, a dot on
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
private final class HoverRowView: ThemedTableRowView {
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

// The strip under the Files tree: the checked-out branch on the left, branch
// and worktree counts on the right, fed by GitStatusMonitor. Hidden entirely
// outside git repos.
private final class GitFooterView: NSView {
    static let height: CGFloat = 24

    private let separator = NSBox(frame: .zero)
    private let iconView = NSImageView(frame: .zero)
    private let branchLabel = NSTextField(labelWithString: "")
    private let countsLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        separator.boxType = .separator
        addSubview(separator)

        iconView.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "git branch")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        iconView.contentTintColor = Theme.textDim
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        branchLabel.font = .systemFont(ofSize: 11, weight: .medium)
        branchLabel.lineBreakMode = .byTruncatingTail
        addSubview(branchLabel)

        countsLabel.font = .systemFont(ofSize: 10)
        countsLabel.textColor = Theme.textDim
        countsLabel.alignment = .right
        addSubview(countsLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    func update(branch: String?, branches: Int, worktrees: Int) {
        branchLabel.stringValue = branch ?? "detached HEAD"
        branchLabel.textColor = branch == nil ? Theme.textDim : Theme.textPrimary
        // Counts are zero only before the first refresh lands; show nothing
        // rather than "0 branches" for that beat.
        if branches == 0 && worktrees == 0 {
            countsLabel.stringValue = ""
        } else {
            let branchPart = "\(branches) \(branches == 1 ? "branch" : "branches")"
            let worktreePart = "\(worktrees) \(worktrees == 1 ? "worktree" : "worktrees")"
            countsLabel.stringValue = "\(branchPart) · \(worktreePart)"
        }
        toolTip = "\(branchLabel.stringValue) — \(countsLabel.stringValue)"
        needsLayout = true
    }

    override func layout() {
        super.layout()
        separator.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        let padding: CGFloat = 8
        iconView.frame = NSRect(x: padding, y: (bounds.height - 12) / 2 - 1, width: 12, height: 12)
        // The counts keep their natural width; the branch name truncates into
        // whatever is left, so a narrow sidebar drops the name, not the counts.
        // +2 over the measured width: NSTextField clips its last glyph when
        // the frame matches intrinsicContentSize exactly at this font size.
        let countsWidth = min(ceil(countsLabel.intrinsicContentSize.width) + 2, bounds.width - padding * 2)
        countsLabel.frame = NSRect(
            x: bounds.width - padding - countsWidth,
            y: (bounds.height - 14) / 2,
            width: countsWidth,
            height: 14
        )
        let branchX = iconView.frame.maxX + 4
        branchLabel.frame = NSRect(
            x: branchX,
            y: (bounds.height - 15) / 2,
            width: max(0, countsLabel.frame.minX - 6 - branchX),
            height: 15
        )
    }
}

// The strip above the Files tree (ROADMAP Phase 9): the browsed root's name
// on the left (pin icon when the root is pinned rather than following the
// focused pane), a folder-picker button on the right, and an unpin button
// while pinned.
private final class RootHeaderView: NSView {
    static let height: CGFloat = 26

    var onChooseFolder: (() -> Void)?
    var onUnpin: (() -> Void)?

    private let separator = NSBox(frame: .zero)
    private let iconView = NSImageView(frame: .zero)
    private let nameLabel = NSTextField(labelWithString: "")
    private let chooseButton = NSButton(frame: .zero)
    private let unpinButton = NSButton(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        separator.boxType = .separator
        addSubview(separator)

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = Theme.textDim
        addSubview(iconView)

        nameLabel.font = .systemFont(ofSize: 11, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(nameLabel)

        configure(button: chooseButton, symbol: "folder.badge.plus", tooltip: "Select Folder…", action: #selector(chooseFolder))
        configure(button: unpinButton, symbol: "pin.slash", tooltip: "Unpin — follow the focused pane again", action: #selector(unpin))
        unpinButton.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure(button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.contentTintColor = Theme.textDim
        addSubview(button)
    }

    func update(rootPath: String, pinned: Bool) {
        nameLabel.stringValue = (rootPath as NSString).lastPathComponent
        nameLabel.toolTip = (rootPath as NSString).abbreviatingWithTildeInPath
        iconView.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "folder", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .medium))
        iconView.contentTintColor = pinned ? Theme.accent : Theme.textDim
        unpinButton.isHidden = !pinned
        needsLayout = true
    }

    @objc private func chooseFolder() {
        onChooseFolder?()
    }

    @objc private func unpin() {
        onUnpin?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        separator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        let padding: CGFloat = 8
        let buttonSize: CGFloat = 18
        var right = bounds.width - padding
        chooseButton.frame = NSRect(x: right - buttonSize, y: (bounds.height - buttonSize) / 2, width: buttonSize, height: buttonSize)
        right = chooseButton.frame.minX - 4
        if !unpinButton.isHidden {
            unpinButton.frame = NSRect(x: right - buttonSize, y: (bounds.height - buttonSize) / 2, width: buttonSize, height: buttonSize)
            right = unpinButton.frame.minX - 4
        }
        iconView.frame = NSRect(x: padding, y: (bounds.height - 12) / 2, width: 12, height: 12)
        let nameX = iconView.frame.maxX + 4
        nameLabel.frame = NSRect(x: nameX, y: (bounds.height - 15) / 2, width: max(0, right - nameX - 2), height: 15)
    }
}

// NSOutlineView that hands right-clicks (anywhere, rows and empty space alike)
// back to the browser so it can build a context menu for the row under the
// cursor — or the root when clicked below the last row.
private final class FileOutlineView: NSOutlineView {
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
    private let outlineView = FileOutlineView(frame: .zero)
    // Empty folders the user created here that no indexed file backs; injected
    // into the tree so they show immediately (see FileNode.buildTree). Keyed
    // by path relative to the index root, pruned to still-existing dirs on
    // every rebuild, and reset when the browsed root changes.
    private var createdDirectories: Set<String> = []
    private let rootHeader = RootHeaderView(frame: .zero)
    private let gitFooter = GitFooterView(frame: .zero)
    private var rootNodes: [FileNode] = []
    private var index: FileIndex?
    // Whether the browsed root was explicitly picked (Select Folder…) rather
    // than derived from the focused pane; display-only — pinning itself lives
    // in the window controller.
    private var isPinned = false

    // Set by the window controller; receives the file's absolute path.
    var onOpenFile: ((String) -> Void)?
    // Header actions (ROADMAP Phase 9): open the folder picker / unpin.
    var onChooseFolder: (() -> Void)? {
        get { rootHeader.onChooseFolder }
        set { rootHeader.onChooseFolder = newValue }
    }
    var onUnpin: (() -> Void)? {
        get { rootHeader.onUnpin }
        set { rootHeader.onUnpin = newValue }
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

        addSubview(rootHeader)

        gitFooter.isHidden = true
        addSubview(gitFooter)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContents()
    }

    private func layoutContents() {
        let footerHeight = gitFooter.isHidden ? 0 : GitFooterView.height
        gitFooter.frame = NSRect(x: 0, y: 0, width: bounds.width, height: footerHeight)
        let headerHeight = RootHeaderView.height
        rootHeader.frame = NSRect(x: 0, y: bounds.height - headerHeight, width: bounds.width, height: headerHeight)
        scrollView.frame = NSRect(
            x: 0,
            y: footerHeight,
            width: bounds.width,
            height: max(0, bounds.height - footerHeight - headerHeight)
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
        rootHeader.update(rootPath: index.root, pinned: isPinned)
    }

    private var gitMonitor: GitStatusMonitor?
    // Prepended to node paths when looking up git status: the browsed root's
    // path relative to the repo root ("" when they coincide), since the
    // monitor's paths are repo-root-relative but nodes are index-root-relative.
    private var gitPathPrefix = ""

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
        // the index is pinned to a subdirectory (Phase 9), with the offset
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
            gitFooter.isHidden = false
            gitFooter.update(
                branch: gitMonitor.currentBranch,
                branches: gitMonitor.branchCount,
                worktrees: gitMonitor.worktreeCount
            )
        } else {
            gitFooter.isHidden = true
        }
        layoutContents()
    }

    @objc private func indexUpdated(_ note: Notification) {
        rebuild()
    }

    private func rebuild() {
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

    private var rootPath: String { index?.root ?? "" }

    // Absolute path for a root-relative node path ("" → the root itself).
    private func absolute(_ relativePath: String) -> String {
        relativePath.isEmpty ? rootPath : rootPath + "/" + relativePath
    }

    // Root-relative path for an absolute one under the browsed root, or nil.
    private func relative(_ absolutePath: String) -> String? {
        let prefix = rootPath + "/"
        guard absolutePath.hasPrefix(prefix) else { return nil }
        return String(absolutePath.dropFirst(prefix.count))
    }

    // The directory a New File/Folder anchored on `node` should land in: the
    // folder itself, a file's parent, or the root when nothing was clicked.
    private func newItemDirectory(for node: FileNode?) -> String {
        guard let node else { return rootPath }
        let rel = node.isDirectory ? node.relativePath : (node.relativePath as NSString).deletingLastPathComponent
        return absolute(rel)
    }

    // MARK: - Context menu

    private func contextMenu(for event: NSEvent) -> NSMenu? {
        guard index != nil else { return nil }
        let point = outlineView.convert(event.locationInWindow, from: nil)
        let row = outlineView.row(at: point)
        let node = row >= 0 ? outlineView.item(atRow: row) as? FileNode : nil

        let menu = NSMenu()
        addItem(to: menu, title: "New File…", action: #selector(menuNewFile(_:)), node: node)
        addItem(to: menu, title: "New Folder…", action: #selector(menuNewFolder(_:)), node: node)
        if let node {
            menu.addItem(.separator())
            addItem(to: menu, title: "Rename…", action: #selector(menuRename(_:)), node: node)
            addItem(to: menu, title: "Duplicate", action: #selector(menuDuplicate(_:)), node: node)
            addItem(to: menu, title: "Move to Trash", action: #selector(menuTrash(_:)), node: node)
        }
        menu.addItem(.separator())
        addItem(to: menu, title: "Reveal in Finder", action: #selector(menuReveal(_:)), node: node)
        return menu
    }

    @discardableResult
    private func addItem(to menu: NSMenu, title: String, action: Selector, node: FileNode?) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = node
        return item
    }

    // MARK: - Menu actions

    @objc private func menuNewFile(_ sender: NSMenuItem) {
        let directory = newItemDirectory(for: sender.representedObject as? FileNode)
        OverlayPromptController.shared.ask(caption: "New File", placeholder: "filename.swift", over: window) { [weak self] name in
            self?.createFile(named: name, in: directory)
        }
    }

    @objc private func menuNewFolder(_ sender: NSMenuItem) {
        let directory = newItemDirectory(for: sender.representedObject as? FileNode)
        OverlayPromptController.shared.ask(caption: "New Folder", placeholder: "folder", over: window) { [weak self] name in
            self?.createFolder(named: name, in: directory)
        }
    }

    @objc private func menuRename(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode else { return }
        let source = absolute(node.relativePath)
        OverlayPromptController.shared.ask(caption: "Rename", text: node.name, over: window) { [weak self] name in
            self?.rename(node: node, from: source, to: name)
        }
    }

    @objc private func menuDuplicate(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode else { return }
        let source = absolute(node.relativePath)
        let directory = (source as NSString).deletingLastPathComponent
        let base = (node.name as NSString).deletingPathExtension
        let ext = (node.name as NSString).pathExtension
        let fm = FileManager.default
        // …copy, …copy 2, … until a free name.
        var candidate = ""
        var attempt = 1
        repeat {
            let suffix = attempt == 1 ? " copy" : " copy \(attempt)"
            let name = ext.isEmpty ? base + suffix : base + suffix + "." + ext
            candidate = directory + "/" + name
            attempt += 1
        } while fm.fileExists(atPath: candidate)
        do {
            try fm.copyItem(atPath: source, toPath: candidate)
        } catch {
            NSSound.beep()
            return
        }
        index?.rescan()
    }

    @objc private func menuTrash(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode else { return }
        let url = URL(fileURLWithPath: absolute(node.relativePath))
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            NSSound.beep()
            return
        }
        if node.isDirectory {
            createdDirectories = createdDirectories.filter { $0 != node.relativePath && !$0.hasPrefix(node.relativePath + "/") }
        }
        index?.rescan()
        rebuild()
    }

    @objc private func menuReveal(_ sender: NSMenuItem) {
        let node = sender.representedObject as? FileNode
        let path = node.map { absolute($0.relativePath) } ?? rootPath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - File operations

    private func createFile(named rawName: String, in directory: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let destination = directory + "/" + name
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination) else { NSSound.beep(); return }
        // A name like "sub/file.txt" creates the intermediate folders too.
        let parent = (destination as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        guard fm.createFile(atPath: destination, contents: nil) else { NSSound.beep(); return }
        index?.rescan()
        onOpenFile?(destination)
    }

    private func createFolder(named rawName: String, in directory: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let destination = directory + "/" + name
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination) else { NSSound.beep(); return }
        do {
            try fm.createDirectory(atPath: destination, withIntermediateDirectories: true)
        } catch {
            NSSound.beep()
            return
        }
        // Empty folders aren't in the index, so track and inject it, then
        // rebuild for instant feedback (rescan alone wouldn't surface it).
        if let rel = relative(destination) {
            createdDirectories.insert(rel)
            rebuild()
            expandDirectory(rel)
        }
    }

    private func rename(node: FileNode, from source: String, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != node.name else { return }
        let destination = (source as NSString).deletingLastPathComponent + "/" + name
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination) else { NSSound.beep(); return }
        do {
            try fm.moveItem(atPath: source, toPath: destination)
        } catch {
            NSSound.beep()
            return
        }
        if node.isDirectory, let newRel = relative(destination) {
            remapCreatedDirectories(from: node.relativePath, to: newRel)
        }
        index?.rescan()
        rebuild()
    }

    // Keep injected empty folders visible after a folder they live under is
    // moved or renamed by rewriting their path prefix.
    private func remapCreatedDirectories(from oldRel: String, to newRel: String) {
        createdDirectories = Set(createdDirectories.map { rel in
            if rel == oldRel { return newRel }
            if rel.hasPrefix(oldRel + "/") { return newRel + String(rel.dropFirst(oldRel.count)) }
            return rel
        })
    }

    // Expand a folder and all its ancestors so a just-created child is visible.
    private func expandDirectory(_ relativePath: String) {
        func find(_ rel: String) -> FileNode? {
            var stack = rootNodes
            while let node = stack.popLast() {
                if node.relativePath == rel { return node }
                stack.append(contentsOf: node.children)
            }
            return nil
        }
        var path = ""
        for component in relativePath.split(separator: "/") {
            path = path.isEmpty ? String(component) : path + "/" + component
            if let node = find(path), node.isDirectory {
                outlineView.expandItem(node)
            }
        }
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else { return rootNodes.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode else { return rootNodes[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    // MARK: - Drag & drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? FileNode else { return nil }
        // The file URL doubles as the drag payload (identifying the row for an
        // internal move) and as what Finder reads for a drag-out copy.
        return URL(fileURLWithPath: absolute(node.relativePath)) as NSURL
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex childIndex: Int) -> NSDragOperation {
        guard let sources = draggedFileURLs(info) else { return [] }
        // Only folders (and the root) are drop targets; retarget a drop that
        // lands on a file to its parent, and always "drop on" — the tree is
        // sorted, not manually ordered, so there's no between-rows insert.
        let destinationNode: FileNode?
        if let node = item as? FileNode {
            destinationNode = node.isDirectory ? node : node.parent
        } else {
            destinationNode = nil
        }
        outlineView.setDropItem(destinationNode, dropChildIndex: NSOutlineViewDropOnItemIndex)

        let destination = absolute(destinationNode?.relativePath ?? "")
        var anyValid = false
        var anyExternal = false
        for source in sources.map(\.path) {
            guard isValidMove(source: source, intoDirectory: destination) else { continue }
            anyValid = true
            if !source.hasPrefix(rootPath + "/") { anyExternal = true }
        }
        guard anyValid else { return [] }
        // Files from inside the project move; files dragged in from elsewhere
        // are copied so nothing leaves its original home unexpectedly.
        return anyExternal ? .copy : .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex: Int) -> Bool {
        guard let sources = draggedFileURLs(info) else { return false }
        let destinationNode = item as? FileNode  // always a directory (retargeted) or root
        let destination = absolute(destinationNode?.relativePath ?? "")
        let fm = FileManager.default
        var moved = false
        for source in sources.map(\.path) {
            guard isValidMove(source: source, intoDirectory: destination) else { continue }
            let target = destination + "/" + (source as NSString).lastPathComponent
            do {
                if source.hasPrefix(rootPath + "/") {
                    try fm.moveItem(atPath: source, toPath: target)
                    if let oldRel = relative(source), let newRel = relative(target) {
                        remapCreatedDirectories(from: oldRel, to: newRel)
                    }
                } else {
                    try fm.copyItem(atPath: source, toPath: target)
                }
                moved = true
            } catch {
                NSSound.beep()
            }
        }
        guard moved else { return false }
        index?.rescan()
        rebuild()
        if let destinationNode {
            outlineView.expandItem(destinationNode)
        }
        return true
    }

    private func draggedFileURLs(_ info: NSDraggingInfo) -> [URL]? {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        guard let urls, !urls.isEmpty else { return nil }
        return urls
    }

    // A move/copy is valid when the source isn't already in the destination,
    // nothing there would be clobbered, and a folder isn't dropped into itself
    // or one of its own descendants.
    private func isValidMove(source: String, intoDirectory destination: String) -> Bool {
        let target = destination + "/" + (source as NSString).lastPathComponent
        if source == target { return false }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: source, isDirectory: &isDir)
        if isDir.boolValue, (destination + "/").hasPrefix(source + "/") { return false }
        if FileManager.default.fileExists(atPath: target) { return false }
        return true
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("hoverRow")
        if let view = outlineView.makeView(withIdentifier: identifier, owner: self) as? HoverRowView {
            return view
        }
        let created = HoverRowView(frame: .zero)
        created.identifier = identifier
        return created
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("fileRow")
        let view = outlineView.makeView(withIdentifier: identifier, owner: self) as? FileRowView ?? {
            let created = FileRowView(frame: .zero)
            created.identifier = identifier
            return created
        }()
        view.configure(with: node, gitStatus: gitStatus(for: node))
        return view
    }

    private func gitStatus(for node: FileNode) -> Character? {
        guard let gitMonitor else { return nil }
        let path = gitPathPrefix + node.relativePath
        if node.isDirectory {
            return gitMonitor.changedDirectories.contains(path) ? "•" : nil
        }
        return gitMonitor.statusByPath[path]
    }
}
