import Cocoa

// File:line bookmarks. Favorites pin *files*; a
// review or refactor lives at *specific lines*, so a bookmark points at a
// file:line with an optional name. Lightweight navigation for holding several
// threads of a change in your head at once.

// One saved location. `name` is optional — an empty name renders as the
// derived "file:line". `snippet` is the line's text, for the list row.
struct Bookmark: Codable, Equatable {
    let id: UUID
    var path: String        // absolute file path
    var line: Int           // 1-based
    var name: String        // optional label
    var snippet: String     // the bookmarked line's text
    var createdAt: TimeInterval

    var displayName: String {
        name.isEmpty ? location : name
    }
    var location: String {
        "\((path as NSString).lastPathComponent):\(line)"
    }
}

// The user's bookmarks, backed by ~/.suit/bookmarks.json — an ordered list
// (newest first) shared across windows via didUpdate. Mirrors NotesStore /
// FavoritesStore: $HOME-first path resolution (so harnesses can sandbox it),
// and dead paths (files deleted/moved since) pruned on load.
final class BookmarksStore {
    static let shared = BookmarksStore()
    static let didUpdate = Notification.Name("dev.kosych.suit.BookmarksStore.didUpdate")

    private(set) var bookmarks: [Bookmark]

    // $HOME rather than NSHomeDirectory(), same as NotesStore/ClaudeIntegration.
    private static var suitDirectory: String {
        (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) + "/.suit"
    }
    static var path: String { suitDirectory + "/bookmarks.json" }

    init() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.path)),
              let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) else {
            bookmarks = []
            return
        }
        // Prune bookmarks whose file is gone (moved/deleted) — a bookmark into
        // a dead path can never navigate anywhere.
        bookmarks = decoded.filter { FileManager.default.fileExists(atPath: $0.path) }
        if bookmarks.count != decoded.count {
            flush()
        }
    }

    func bookmark(path: String, line: Int) -> Bookmark? {
        bookmarks.first { $0.path == path && $0.line == line }
    }

    func isBookmarked(path: String, line: Int) -> Bool {
        bookmark(path: path, line: line) != nil
    }

    // The lines bookmarked in one file, for the viewer's gutter/minimap ticks.
    func lines(inFile path: String) -> [Int] {
        bookmarks.filter { $0.path == path }.map { $0.line }
    }

    // Removes an existing bookmark at file:line, else adds one. Returns the
    // resulting bookmark (nil when it was removed).
    @discardableResult
    func toggle(path: String, line: Int, snippet: String, from sender: AnyObject?) -> Bookmark? {
        if let existing = bookmark(path: path, line: line) {
            bookmarks.removeAll { $0.id == existing.id }
            save(from: sender)
            return nil
        }
        let bookmark = Bookmark(
            id: UUID(), path: path, line: line, name: "",
            snippet: snippet.trimmingCharacters(in: .whitespaces),
            createdAt: Date().timeIntervalSince1970
        )
        bookmarks.insert(bookmark, at: 0)
        save(from: sender)
        return bookmark
    }

    func remove(id: UUID, from sender: AnyObject?) {
        guard bookmarks.contains(where: { $0.id == id }) else { return }
        bookmarks.removeAll { $0.id == id }
        save(from: sender)
    }

    func rename(id: UUID, to name: String, from sender: AnyObject?) {
        guard let i = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        save(from: sender)
    }

    private func save(from sender: AnyObject?) {
        flush()
        NotificationCenter.default.post(name: Self.didUpdate, object: sender)
    }

    private func flush() {
        try? FileManager.default.createDirectory(atPath: Self.suitDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(bookmarks) {
            try? data.write(to: URL(fileURLWithPath: Self.path), options: .atomic)
        }
    }
}

// A bookmarks list row: name (or file:line) plus a dimmed "location · snippet".
private final class BookmarkRowView: NSTableCellView {
    static let height: CGFloat = 38

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = Theme.textFaint
        detailLabel.lineBreakMode = .byTruncatingTail
        addSubview(detailLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 8, y: bounds.height - 21, width: max(0, bounds.width - 16), height: 15)
        detailLabel.frame = NSRect(x: 8, y: bounds.height - 35, width: max(0, bounds.width - 16), height: 13)
    }

    func configure(bookmark: Bookmark) {
        titleLabel.stringValue = bookmark.displayName
        // If the row already shows the location as its title (no custom name),
        // the detail line leads with the snippet; otherwise location · snippet.
        let detail = bookmark.name.isEmpty
            ? bookmark.snippet
            : (bookmark.snippet.isEmpty ? bookmark.location : "\(bookmark.location) · \(bookmark.snippet)")
        detailLabel.stringValue = detail
        needsLayout = true
    }
}

// The list's table: Return opens the selected bookmark (keyboard-complete).
private final class BookmarkTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // 36 = Return, 76 = keypad Enter.
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }
}

// The sidebar's Bookmarks tab: a keyboard-navigable list of
// saved file:line locations. Enter / double-click opens the file at that line;
// right-click renames or removes. Backed by the shared BookmarksStore, so every
// window's tab stays in sync.
final class BookmarksView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private static let headerHeight: CGFloat = 26

    private let headerLabel = NSTextField(labelWithString: "")
    private let listScrollView = NSScrollView(frame: .zero)
    private let tableView = BookmarkTableView(frame: .zero)
    private let emptyLabel = NSTextField(labelWithString: "")

    // Receives (absolute path, line) — the window controller opens the file.
    var onOpen: ((String, Int) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        headerLabel.attributedStringValue = NSAttributedString(
            string: "BOOKMARKS",
            attributes: [
                .font: Theme.captionFont,
                .foregroundColor: Theme.textFaint,
                .kern: Theme.captionKern,
            ]
        )
        addSubview(headerLabel)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bookmark"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .sourceList
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelected)
        tableView.onReturn = { [weak self] in self?.openSelected() }

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        listScrollView.documentView = tableView
        listScrollView.hasVerticalScroller = true
        listScrollView.drawsBackground = false
        addSubview(listScrollView)

        emptyLabel.stringValue = "No bookmarks yet.\nPress ⇧⌘L on a line in a file\nviewer to add one."
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = Theme.textFaint
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 3
        addSubview(emptyLabel)

        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: BookmarksStore.didUpdate, object: nil
        )
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        headerLabel.sizeToFit()
        headerLabel.frame.origin = NSPoint(x: 10, y: (Self.headerHeight - headerLabel.frame.height) / 2)
        let listFrame = NSRect(x: 0, y: Self.headerHeight, width: width, height: max(0, bounds.height - Self.headerHeight))
        listScrollView.frame = listFrame
        emptyLabel.frame = NSRect(x: 12, y: Self.headerHeight + 24, width: max(0, width - 24), height: 52)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    var focusTarget: NSView { tableView }

    @objc private func storeChanged() {
        reload()
    }

    private func reload() {
        let empty = BookmarksStore.shared.bookmarks.isEmpty
        listScrollView.isHidden = empty
        emptyLabel.isHidden = !empty
        tableView.reloadData()
    }

    @objc private func openSelected() {
        let row = tableView.selectedRow
        let bookmarks = BookmarksStore.shared.bookmarks
        guard row >= 0, row < bookmarks.count else { return }
        onOpen?(bookmarks[row].path, bookmarks[row].line)
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        let bookmarks = BookmarksStore.shared.bookmarks
        guard row >= 0, row < bookmarks.count else { return }
        let id = bookmarks[row].id
        for (title, action) in [("Open", #selector(openFromMenu(_:))), ("Rename…", #selector(renameFromMenu(_:))), ("Remove", #selector(removeFromMenu(_:)))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = id
        }
    }

    @objc private func openFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let bookmark = BookmarksStore.shared.bookmarks.first(where: { $0.id == id }) else { return }
        onOpen?(bookmark.path, bookmark.line)
    }

    @objc private func removeFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        BookmarksStore.shared.remove(id: id, from: nil)
    }

    @objc private func renameFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let bookmark = BookmarksStore.shared.bookmarks.first(where: { $0.id == id }) else { return }
        OverlayPromptController.shared.ask(
            caption: "Rename bookmark · \(bookmark.location)",
            text: bookmark.name,
            placeholder: "Bookmark name…",
            over: window
        ) { value in
            BookmarksStore.shared.rename(id: id, to: value, from: nil)
        }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        BookmarksStore.shared.bookmarks.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        BookmarkRowView.height
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let bookmarks = BookmarksStore.shared.bookmarks
        guard row < bookmarks.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("bookmarkRow")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? BookmarkRowView ?? {
            let created = BookmarkRowView(frame: .zero)
            created.identifier = identifier
            return created
        }()
        view.configure(bookmark: bookmarks[row])
        return view
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ThemedTableRowView()
    }
}
