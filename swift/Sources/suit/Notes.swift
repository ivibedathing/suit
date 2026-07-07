import Cocoa

// One user note. The title is derived (first non-empty line, Apple Notes
// style) rather than stored, so the list row always matches the text.
struct Note: Codable, Equatable {
    let id: UUID
    var text: String
    var createdAt: TimeInterval
    var updatedAt: TimeInterval

    var title: String {
        firstContentLines(1).first ?? "New Note"
    }

    // The line after the title, for the list row's detail text.
    var snippet: String {
        let lines = firstContentLines(2)
        return lines.count > 1 ? lines[1] : ""
    }

    private func firstContentLines(_ count: Int) -> [String] {
        var lines: [String] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            lines.append(line)
            if lines.count == count { break }
        }
        return lines
    }
}

// The user's notes, backed by ~/.suit/notes.json — an ordered list (newest
// first), not a single blob. One store owns the list: the sidebar's Notes tab
// edits the selected note, and the terminal right-click "Create Note from
// Selection" adds a new note. Saves are debounced (and flushed at quit);
// didUpdate keeps every window's Notes tab in sync (the sender skips its own
// editor refresh so the caret survives).
final class NotesStore {
    static let shared = NotesStore()
    static let didUpdate = Notification.Name("dev.kosych.suit.NotesStore.didUpdate")

    private(set) var notes: [Note]

    private var saveTimer: Timer?
    // $HOME rather than NSHomeDirectory(), same as ClaudeIntegration: an
    // overridden $HOME sandboxes the file for harness runs.
    private static var suitDirectory: String {
        (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) + "/.suit"
    }
    static var path: String { suitDirectory + "/notes.json" }
    // The pre-list free-text file; imported once as the first note.
    static var legacyPath: String { suitDirectory + "/notes.txt" }

    init() {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: Self.path)),
           let decoded = try? JSONDecoder().decode([Note].self, from: data) {
            notes = decoded
        } else if let legacy = try? String(contentsOfFile: Self.legacyPath, encoding: .utf8),
                  !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let now = Date().timeIntervalSince1970
            notes = [Note(id: UUID(), text: legacy, createdAt: now, updatedAt: now)]
            // Persist the migration immediately so notes.txt is imported only
            // once (the .txt itself is left in place, untouched).
            flush()
        } else {
            notes = []
        }
    }

    func note(withId id: UUID) -> Note? {
        notes.first { $0.id == id }
    }

    @discardableResult
    func addNote(text: String = "", from sender: AnyObject?) -> Note {
        let now = Date().timeIntervalSince1970
        let note = Note(id: UUID(), text: text, createdAt: now, updatedAt: now)
        notes.insert(note, at: 0)
        scheduleSave()
        post(from: sender)
        return note
    }

    // The Notes tab pushes every edit of the selected note here; other
    // windows' tabs follow via didUpdate (the sender skips itself).
    func setText(id: UUID, _ newText: String, from sender: AnyObject?) {
        guard let index = notes.firstIndex(where: { $0.id == id }),
              notes[index].text != newText else { return }
        notes[index].text = newText
        notes[index].updatedAt = Date().timeIntervalSince1970
        scheduleSave()
        post(from: sender)
    }

    func deleteNote(id: UUID, from sender: AnyObject?) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes.remove(at: index)
        scheduleSave()
        post(from: sender)
    }

    // Right-click "Create Note from Selection" in a terminal: each capture
    // becomes its own note at the top of the list.
    func addNoteFromSelection(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        addNote(text: trimmed, from: nil)
    }

    // Debounced so keystrokes don't each hit the disk; flush() forces the
    // write (applicationWillTerminate — a pending timer dies with the app).
    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            self?.flush()
        }
    }

    func flush() {
        saveTimer?.invalidate()
        saveTimer = nil
        try? FileManager.default.createDirectory(
            atPath: Self.suitDirectory,
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(notes) {
            try? data.write(to: URL(fileURLWithPath: Self.path), options: .atomic)
        }
    }

    private func post(from sender: AnyObject?) {
        NotificationCenter.default.post(name: Self.didUpdate, object: sender)
    }
}

// A note list row: derived title plus a dimmed date · snippet line.
private final class NoteRowView: NSTableCellView {
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

    func configure(note: Note) {
        titleLabel.stringValue = note.title
        let date = Date(timeIntervalSince1970: note.updatedAt)
        let dateText = Calendar.current.isDateInToday(date)
            ? Self.timeFormatter.string(from: date)
            : Self.dayFormatter.string(from: date)
        detailLabel.stringValue = note.snippet.isEmpty ? dateText : dateText + " · " + note.snippet
        needsLayout = true
    }
}

// The sidebar's Notes tab: the note list on top, an editor for the selected
// note below — still the one deliberately editable text surface in the app
// (notes are the user's words, not code; the viewer-first rule is about
// source files). Typing with no note selected creates one on the fly.
final class NotesView: NSView, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private static let headerHeight: CGFloat = 26

    private let headerLabel = NSTextField(labelWithString: "")
    private let addButton = NSButton(frame: .zero)
    private let listScrollView = NSScrollView(frame: .zero)
    private let tableView = NSTableView(frame: .zero)
    private let separator = NSView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let textView = NSTextView(frame: .zero)

    private var selectedNoteID: UUID?
    // Distinguishes programmatic table selection from a user click.
    private var suppressSelectionCallback = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        headerLabel.attributedStringValue = NSAttributedString(
            string: "NOTES",
            attributes: [
                .font: Theme.captionFont,
                .foregroundColor: Theme.textFaint,
                .kern: Theme.captionKern,
            ]
        )
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
        tableView.backgroundColor = .clear
        tableView.style = .sourceList
        tableView.dataSource = self
        tableView.delegate = self

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        listScrollView.documentView = tableView
        listScrollView.hasVerticalScroller = true
        listScrollView.drawsBackground = false
        addSubview(listScrollView)

        separator.wantsLayer = true
        separator.layer?.backgroundColor = Theme.hairline.cgColor
        addSubview(separator)

        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = Theme.textPrimary
        textView.insertionPointColor = Theme.accent
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        addSubview(scrollView)

        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged(_:)),
            name: NotesStore.didUpdate, object: nil
        )

        reloadList()
        select(NotesStore.shared.notes.first?.id)
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
        addButton.frame = NSRect(x: width - 26, y: (Self.headerHeight - 18) / 2, width: 18, height: 18)

        // The list only takes what its rows need (+ the sourceList style's
        // built-in insets), capped so the editor always keeps the majority of
        // the tab.
        let count = NotesStore.shared.notes.count
        let listHeight = count == 0
            ? 0
            : min(CGFloat(count) * NoteRowView.height + 14, floor(bounds.height * 0.35))
        listScrollView.frame = NSRect(x: 0, y: Self.headerHeight, width: width, height: listHeight)
        listScrollView.isHidden = count == 0
        separator.frame = NSRect(x: 0, y: Self.headerHeight + listHeight, width: width, height: 1)
        separator.isHidden = count == 0

        let editorTop = Self.headerHeight + listHeight + (count == 0 ? 0 : 1)
        scrollView.frame = NSRect(x: 0, y: editorTop, width: width, height: max(0, bounds.height - editorTop))
        textView.frame.size.width = width
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    // What the sidebar focuses when this tab is selected.
    var focusTarget: NSView { textView }

    // MARK: - Selection / editor sync

    // Points the editor at another note: table row, text, fresh undo stack.
    private func select(_ id: UUID?) {
        selectedNoteID = id
        suppressSelectionCallback = true
        if let id, let row = NotesStore.shared.notes.firstIndex(where: { $0.id == id }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else {
            tableView.deselectAll(nil)
        }
        suppressSelectionCallback = false
        textView.string = id.flatMap { NotesStore.shared.note(withId: $0)?.text } ?? ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.undoManager?.removeAllActions()
    }

    // Rebuilds the table (titles/dates/order) without disturbing the editor.
    private func reloadList() {
        suppressSelectionCallback = true
        tableView.reloadData()
        if let id = selectedNoteID,
           let row = NotesStore.shared.notes.firstIndex(where: { $0.id == id }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        suppressSelectionCallback = false
        needsLayout = true
    }

    @objc private func addNoteClicked() {
        let note = NotesStore.shared.addNote(from: self)
        select(note.id)
        window?.makeFirstResponder(textView)
    }

    func textDidChange(_ notification: Notification) {
        if let id = selectedNoteID {
            NotesStore.shared.setText(id: id, textView.string, from: self)
        } else {
            // No note yet (empty store) — the first keystroke creates one.
            let note = NotesStore.shared.addNote(text: textView.string, from: self)
            selectedNoteID = note.id
        }
        // The store posts with us as sender, so our storeChanged skipped the
        // editor — but the row title/date still need to follow the keystroke.
        reloadList()
    }

    // Another window's tab, a terminal selection-capture, or our own store
    // call changed the list.
    @objc private func storeChanged(_ notification: Notification) {
        let store = NotesStore.shared
        reloadList()
        if let id = selectedNoteID, store.note(withId: id) == nil {
            // The selected note was deleted — fall back to the top of the list.
            select(store.notes.first?.id)
            return
        }
        if selectedNoteID == nil, let first = store.notes.first, textView.string.isEmpty {
            // Empty tab and a note appeared (e.g. terminal capture) — show it.
            select(first.id)
            return
        }
        guard notification.object as? NotesView !== self else { return }
        if let id = selectedNoteID, let note = store.note(withId: id), textView.string != note.text {
            let selection = textView.selectedRange()
            textView.string = note.text
            let length = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0, row < NotesStore.shared.notes.count else { return }
        let item = menu.addItem(withTitle: "Delete Note", action: #selector(deleteNoteFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = NotesStore.shared.notes[row].id
    }

    @objc private func deleteNoteFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        NotesStore.shared.deleteNote(id: id, from: nil)
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

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback else { return }
        let row = tableView.selectedRow
        let notes = NotesStore.shared.notes
        guard row >= 0, row < notes.count, notes[row].id != selectedNoteID else { return }
        select(notes[row].id)
    }
}
