import Cocoa

// The sidebar's Notes tab: a list of the `.txt` files in ~/.suit/notes/, and
// nothing else. Clicking one opens it as an ordinary file tab — the same
// openFile path the Files tree uses, so a note dedupes by path, splits, drags
// and restores exactly like a project file, and the editing lives in the file
// viewer rather than in a second text surface here (see Notes.swift for why).
//
// The list is a mirror of the directory, so it holds no note state of its own:
// every mutation goes through NotesStore and comes back as didUpdate, which is
// also how a note created in another window (or in Finder) shows up here.

// A note list row: filename-as-title plus a dimmed "date · first line".
private final class NoteRowView: NSTableCellView {
    static let height: CGFloat = 38

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        detailLabel.font = .systemFont(ofSize: 10)
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

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    func configure(note: NoteFile) {
        // Colors are read here rather than cached at init so a theme switch
        // (which reloads the table) repaints the row.
        titleLabel.textColor = Theme.textPrimary
        detailLabel.textColor = Theme.textFaint
        titleLabel.stringValue = note.title
        let dateText = Calendar.current.isDateInToday(note.modifiedAt)
            ? Self.timeFormatter.string(from: note.modifiedAt)
            : Self.dayFormatter.string(from: note.modifiedAt)
        detailLabel.stringValue = note.snippet.isEmpty ? dateText : dateText + " · " + note.snippet
        needsLayout = true
    }
}

// The list's table: Return opens the selected note, matching BookmarksView.
private final class NoteTableView: NSTableView {
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

final class NotesView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    // The tab's title band, shared with every other sidebar tab.
    private static let headerHeight = SidebarTitle.height

    private let headerLabel = SidebarTitle.label("NOTES")
    private let addButton = NSButton(frame: .zero)
    private let listScrollView = NSScrollView(frame: .zero)
    private let tableView = NoteTableView(frame: .zero)
    private let emptyLabel = NSTextField(labelWithString: "")

    // Receives an absolute path — the window controller opens it as a file tab.
    var onOpen: ((String) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        addSubview(headerLabel)

        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Note")
        addButton.isBordered = false
        addButton.bezelStyle = .regularSquare
        addButton.contentTintColor = Theme.textDim
        addButton.toolTip = "New Note"
        addButton.target = self
        addButton.action = #selector(addNoteClicked)
        addSubview(addButton)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        // .inset, not .sourceList: the source-list style blends AppKit's sidebar
        // material with the desktop behind the window, which ignores the palette.
        // The style resets backgroundColor, so clear it after.
        tableView.style = .inset
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        // Single click opens: a note list is a list of destinations, and the
        // list holds no editor of its own to select *into* first.
        tableView.action = #selector(openSelected)
        tableView.onReturn = { [weak self] in self?.openSelected() }

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        listScrollView.documentView = tableView
        listScrollView.hasVerticalScroller = true
        listScrollView.drawsBackground = false
        addSubview(listScrollView)

        emptyLabel.stringValue = "No notes yet.\nClick + to write one — notes are\n.txt files in ~/.suit/notes."
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = Theme.textFaint
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 3
        addSubview(emptyLabel)

        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: NotesStore.didUpdate, object: nil
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
        headerLabel.frame.origin = NSPoint(
            x: SidebarTitle.leftInset,
            y: (Self.headerHeight - headerLabel.frame.height) / 2
        )
        addButton.frame = NSRect(x: width - 26, y: (Self.headerHeight - 18) / 2, width: 18, height: 18)
        listScrollView.frame = NSRect(
            x: 0, y: Self.headerHeight,
            width: width, height: max(0, bounds.height - Self.headerHeight)
        )
        emptyLabel.frame = NSRect(x: 12, y: Self.headerHeight + 24, width: max(0, width - 24), height: 52)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    // What the sidebar focuses when this tab is selected. The list, not a text
    // view — the notes themselves are focused in their own panes now.
    var focusTarget: NSView { tableView }

    @objc private func storeChanged() {
        reload()
    }

    private func reload() {
        let empty = NotesStore.shared.notes.isEmpty
        listScrollView.isHidden = empty
        emptyLabel.isHidden = !empty
        emptyLabel.textColor = Theme.textFaint
        tableView.reloadData()
    }

    // MARK: - Actions

    @objc private func addNoteClicked() {
        OverlayPromptController.shared.ask(
            caption: "New Note",
            placeholder: "Note title…",
            over: window
        ) { [weak self] title in
            guard let path = NotesStore.shared.createNote(title: title) else {
                NSSound.beep()
                return
            }
            // Straight into the pane, with the caret in it — the note was
            // created to be written in.
            self?.onOpen?(path)
        }
    }

    @objc private func openSelected() {
        let row = tableView.selectedRow
        let notes = NotesStore.shared.notes
        guard row >= 0, row < notes.count else { return }
        onOpen?(notes[row].path)
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        let notes = NotesStore.shared.notes
        guard row >= 0, row < notes.count else { return }
        let path = notes[row].path
        let items: [(String, Selector)] = [
            ("Open", #selector(openFromMenu(_:))),
            ("Rename…", #selector(renameFromMenu(_:))),
            ("Reveal in Finder", #selector(revealFromMenu(_:))),
            ("Move to Trash", #selector(trashFromMenu(_:))),
        ]
        for (title, action) in items {
            if title == "Reveal in Finder" { menu.addItem(.separator()) }
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = path
        }
    }

    @objc private func openFromMenu(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onOpen?(path)
    }

    @objc private func renameFromMenu(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let note = NotesStore.shared.note(atPath: path) else { return }
        OverlayPromptController.shared.ask(
            caption: "Rename Note",
            text: note.title,
            placeholder: "Note title…",
            over: window
        ) { title in
            guard NotesStore.shared.renameNote(atPath: path, toTitle: title) != nil else {
                NSSound.beep()
                return
            }
        }
    }

    @objc private func revealFromMenu(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func trashFromMenu(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        if !NotesStore.shared.deleteNote(atPath: path) { NSSound.beep() }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        NotesStore.shared.notes.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        NoteRowView.height
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let notes = NotesStore.shared.notes
        guard row < notes.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("noteRow")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? NoteRowView ?? {
            let created = NoteRowView(frame: .zero)
            created.identifier = identifier
            return created
        }()
        view.configure(note: notes[row])
        return view
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ThemedTableRowView()
    }
}
