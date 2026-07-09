import Cocoa

// One entry in the command palette: every app action by another door, so the
// menu bar never has to be memorized. Later phases register their commands
// here too (fuzzy file open shares this machinery in Phase 1 — see ROADMAP.md).
struct PaletteCommand {
    let title: String
    // Display-only shortcut hint, e.g. "⌘D"; the palette doesn't dispatch keys.
    let shortcut: String?
    let action: () -> Void
    // ⇧Enter alternate (ROADMAP Phase 43: the ⌃R history overlay's edit-before-run).
    // nil — the common case — means ⇧Enter behaves exactly like Enter.
    let altAction: (() -> Void)?

    // altAction precedes action so the trailing-closure call sites
    // (`PaletteCommand(title:shortcut:) { … }`) still bind their closure to
    // `action` and leave altAction at its default.
    init(title: String, shortcut: String?, altAction: (() -> Void)? = nil, action: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.altAction = altAction
        self.action = action
    }
}

// The fuzzy matcher (`fuzzyScore`) lives in FuzzyMatch.swift now — a
// Foundation-only file so the ⌃R command-history harness can rank against the
// same scorer this palette uses.

// A borderless panel refuses key status unless told otherwise, and the palette's
// search field needs it.
private final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// A palette row: title on the left, dimmed shortcut hint on the right. Manual
// layout like the rest of the app's chrome.
private final class PaletteRowView: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let shortcutLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        shortcutLabel.font = .systemFont(ofSize: 12)
        shortcutLabel.textColor = Theme.textFaint
        shortcutLabel.alignment = .right
        addSubview(shortcutLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let labelHeight: CGFloat = 17
        let y = (newSize.height - labelHeight) / 2
        let shortcutWidth: CGFloat = 72
        shortcutLabel.frame = NSRect(x: newSize.width - shortcutWidth - 12, y: y, width: shortcutWidth, height: labelHeight)
        titleLabel.frame = NSRect(x: 12, y: y, width: max(0, newSize.width - shortcutWidth - 32), height: labelHeight)
    }
}

// The Cmd-K command palette: a floating type-to-filter list over the key
// window. Commands are re-fetched from the provider every time it opens, so
// entries can reflect current state without any invalidation bookkeeping.
final class CommandPaletteController: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: PalettePanel
    private let searchField = NSTextField(frame: .zero)
    private let tableView = NSTableView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let commandsProvider: () -> [PaletteCommand]
    private var commands: [PaletteCommand] = []
    private var filtered: [PaletteCommand] = []

    private static let panelSize = NSSize(width: 560, height: 354)
    private static let fieldHeight: CGFloat = 46

    init(commandsProvider: @escaping () -> [PaletteCommand]) {
        self.commandsProvider = commandsProvider

        panel = PalettePanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false

        super.init()

        panel.delegate = self

        // Flat overlay surface (Phase 11), replacing the .menu vibrancy.
        let effect = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
        effect.wantsLayer = true
        effect.layer?.backgroundColor = Theme.overlay.cgColor
        effect.layer?.cornerRadius = Theme.Metrics.overlayRadius
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = Theme.hairline.cgColor
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        panel.contentView = effect

        searchField.frame = NSRect(
            x: 16,
            y: Self.panelSize.height - Self.fieldHeight + 8,
            width: Self.panelSize.width - 32,
            height: 30
        )
        searchField.font = .systemFont(ofSize: 18, weight: .light)
        searchField.placeholderString = "Type a command…"
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self
        effect.addSubview(searchField)

        let separator = NSBox(frame: NSRect(x: 0, y: Self.panelSize.height - Self.fieldHeight, width: Self.panelSize.width, height: 1))
        separator.boxType = .separator
        effect.addSubview(separator)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        // Grow the single column to fill the table's width — without this it keeps
        // the tiny default width, collapsing each row's title label to zero width
        // (max(0, columnWidth - shortcut - padding)) so command/shortcut text never
        // shows. The .autoresizingMask keeps it filling on resize, but this panel is
        // a fixed size and never resizes, so the autoresize never fires — set an
        // explicit starting width too, or the column stays at its tiny default.
        column.width = Self.panelSize.width
        column.minWidth = 200
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.style = .plain

        scrollView.frame = NSRect(x: 0, y: 0, width: Self.panelSize.width, height: Self.panelSize.height - Self.fieldHeight - 1)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        effect.addSubview(scrollView)
    }

    // Large item sets (the fuzzy file opener feeds every file in a large repo)
    // stay snappy by only materializing the best matches in the table.
    private static let maxVisibleResults = 250

    var isVisible: Bool { panel.isVisible }

    // MARK: - Showing & hiding

    // Command mode: items come from the provider (every app action).
    func show(relativeTo window: NSWindow?) {
        show(relativeTo: window, commands: commandsProvider(), placeholder: "Type a command…")
    }

    // Explicit-items mode (the Cmd-P file opener): same panel, same filtering,
    // different corpus and placeholder.
    func show(relativeTo window: NSWindow?, commands newCommands: [PaletteCommand], placeholder: String) {
        commands = newCommands
        searchField.placeholderString = placeholder
        searchField.stringValue = ""
        applyFilter()

        if let window {
            // Spotlight-style: centered horizontally, in the window's upper third.
            let frame = window.frame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - Self.panelSize.width / 2,
                y: frame.maxY - Self.panelSize.height - frame.height * 0.18
            ))
        } else {
            panel.center()
        }

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    // Swaps the corpus under an open palette, keeping the query — how the file
    // opener updates in place when the index's first async scan lands.
    func refreshCommands(_ newCommands: [PaletteCommand]) {
        guard isVisible else { return }
        commands = newCommands
        applyFilter()
    }

    private func close() {
        panel.orderOut(nil)
    }

    // Clicking anywhere else dismisses the palette, like a menu.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    // MARK: - Filtering

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        // The index tie-break keeps equal scores in corpus order (Swift's sort
        // isn't stable) — with an empty query that's the provider's own order:
        // alphabetical for files, curated for commands.
        var scored: [(command: PaletteCommand, score: Int, order: Int)] = []
        for (order, command) in commands.enumerated() {
            if let score = fuzzyScore(query: query, candidate: command.title) {
                scored.append((command, score, order))
            }
        }
        scored.sort { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }
        filtered = scored.prefix(Self.maxVisibleResults).map { $0.command }
        tableView.reloadData()
        if !filtered.isEmpty {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    // MARK: - Keyboard driving (arrows/enter/escape while typing in the field)

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // ⇧Enter takes the alternate (edit-before-run) when the selected
            // command has one; plain Enter runs. Some field editors route
            // Shift-Return to insertLineBreak/insertNewlineIgnoringFieldEditor
            // instead — those cases below force the alternate.
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            runSelected(useAlt: shift)
            return true
        case #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            runSelected(useAlt: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let current = tableView.selectedRow
        let next = min(max(current + delta, 0), filtered.count - 1)
        tableView.selectRowIndexes([next], byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func runSelected(useAlt: Bool = false) {
        let row = tableView.selectedRow
        guard filtered.indices.contains(row) else { return }
        let command = filtered[row]
        close()
        // Deferred one runloop turn so key-window status has moved back to the
        // user's window first — actions that walk the responder chain (Go to
        // Line) or ask "which window is active" need that settled.
        DispatchQueue.main.async {
            if useAlt, let alt = command.altAction {
                alt()
            } else {
                command.action()
            }
        }
    }

    @objc private func rowClicked(_ sender: Any?) {
        guard tableView.clickedRow >= 0 else { return }
        tableView.selectRowIndexes([tableView.clickedRow], byExtendingSelection: false)
        runSelected()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("paletteRow")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? PaletteRowView ?? {
            let created = PaletteRowView(frame: .zero)
            created.identifier = identifier
            return created
        }()
        let command = filtered[row]
        view.titleLabel.stringValue = command.title
        view.shortcutLabel.stringValue = command.shortcut ?? ""
        return view
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ThemedTableRowView()
    }
}
