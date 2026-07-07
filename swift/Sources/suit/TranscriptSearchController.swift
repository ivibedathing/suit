import Cocoa

// MARK: - Panel controller

private final class TranscriptSearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// The "Search Transcripts…" surface: a floating panel (same overlay chrome as
// the command palette) with a query field over a results outline grouped by
// session. Clicking a match opens that session's transcript pane anchored to
// the matching line.
final class TranscriptSearchController: NSObject, NSWindowDelegate, NSTextFieldDelegate,
    NSOutlineViewDataSource, NSOutlineViewDelegate {

    // Set by AppDelegate; opens the picked result (path + cwd + title + line).
    var onOpen: ((TranscriptSearchResult) -> Void)?

    private let panel: TranscriptSearchPanel
    private let searchField = NSTextField(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView(frame: .zero)
    private let outlineView = NSOutlineView(frame: .zero)

    private let searcher = TranscriptSearcher()
    private var debounce: DispatchWorkItem?

    private var groups: [TranscriptGroupNode] = []
    private var groupsById: [String: TranscriptGroupNode] = [:]
    private var resultCount = 0
    private var isSearching = false

    private static let panelSize = NSSize(width: 640, height: 460)
    private static let fieldHeight: CGFloat = 46
    private static let statusHeight: CGFloat = 20

    override init() {
        panel = TranscriptSearchPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false

        super.init()
        panel.delegate = self

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
            x: 16, y: Self.panelSize.height - Self.fieldHeight + 8,
            width: Self.panelSize.width - 32, height: 30
        )
        searchField.font = .systemFont(ofSize: 18, weight: .light)
        searchField.placeholderString = "Search all Claude transcripts…"
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self
        effect.addSubview(searchField)

        let separator = NSBox(frame: NSRect(x: 0, y: Self.panelSize.height - Self.fieldHeight, width: Self.panelSize.width, height: 1))
        separator.boxType = .separator
        effect.addSubview(separator)

        statusLabel.frame = NSRect(x: 16, y: Self.panelSize.height - Self.fieldHeight - Self.statusHeight, width: Self.panelSize.width - 32, height: 16)
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = Theme.textFaint
        statusLabel.lineBreakMode = .byTruncatingTail
        effect.addSubview(statusLabel)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 22
        outlineView.indentationPerLevel = 10
        outlineView.autoresizesOutlineColumn = false
        outlineView.backgroundColor = .clear
        outlineView.style = .sourceList
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)

        let listTop = Self.panelSize.height - Self.fieldHeight - Self.statusHeight - 1
        scrollView.frame = NSRect(x: 0, y: 0, width: Self.panelSize.width, height: listTop)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        effect.addSubview(scrollView)

        searcher.onResults = { [weak self] results in self?.append(results) }
        searcher.onFinished = { [weak self] truncated, error in self?.finished(truncated: truncated, error: error) }
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: Showing / hiding

    func show(relativeTo window: NSWindow?) {
        searchField.stringValue = ""
        clearResults()
        statusLabel.stringValue = "Type to search prompts, replies, and tool calls across every session."

        if let window {
            let frame = window.frame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - Self.panelSize.width / 2,
                y: frame.maxY - Self.panelSize.height - frame.height * 0.14
            ))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    private func close() {
        searcher.cancel()
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    // MARK: Searching

    func controlTextDidChange(_ obj: Notification) {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runSearch() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func runSearch() {
        searcher.cancel()
        clearResults()
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            statusLabel.stringValue = ""
            return
        }
        isSearching = true
        statusLabel.stringValue = "Searching transcripts…"
        searcher.search(query: query)
    }

    private func clearResults() {
        groups = []
        groupsById = [:]
        resultCount = 0
        isSearching = false
        outlineView.reloadData()
    }

    private func append(_ results: [TranscriptSearchResult]) {
        guard isSearching else { return }
        var newGroups: [TranscriptGroupNode] = []
        for result in results {
            let id = result.session.sessionId
            let group: TranscriptGroupNode
            if let existing = groupsById[id] {
                group = existing
            } else {
                group = TranscriptGroupNode(info: result.session, transcriptPath: result.transcriptPath)
                groupsById[id] = group
                groups.append(group)
                newGroups.append(group)
            }
            group.results.append(TranscriptResultNode(result: result))
        }
        resultCount += results.count
        // Most recent sessions first — that's the "yesterday" recall the phase
        // is for. Stable re-sort keeps groups meaningful as batches stream in.
        groups.sort { $0.info.date > $1.info.date }
        outlineView.reloadData()
        for group in newGroups {
            outlineView.expandItem(group)
        }
        updateStatus(suffix: isSearching ? "…" : "")
    }

    private func finished(truncated: Bool, error: String?) {
        isSearching = false
        if let error {
            statusLabel.stringValue = error
            return
        }
        updateStatus(suffix: truncated ? " (first \(RipgrepSearcher.maxMatches))" : "")
    }

    private func updateStatus(suffix: String) {
        if resultCount == 0 {
            statusLabel.stringValue = isSearching ? "Searching transcripts…" : "No matching transcript entries"
            return
        }
        let sessions = groups.count == 1 ? "1 session" : "\(groups.count) sessions"
        statusLabel.stringValue = "\(resultCount) matches in \(sessions)\(suffix)"
    }

    // MARK: Opening

    @objc private func rowClicked() {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)
        if let group = item as? TranscriptGroupNode {
            if outlineView.isItemExpanded(group) {
                outlineView.collapseItem(group)
            } else {
                outlineView.expandItem(group)
            }
        } else if let node = item as? TranscriptResultNode {
            close()
            let result = node.result
            DispatchQueue.main.async { [weak self] in
                self?.onOpen?(result)
            }
        }
    }

    // MARK: Keyboard driving

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            openSelected()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        let count = outlineView.numberOfRows
        guard count > 0 else { return }
        let current = outlineView.selectedRow
        let next = min(max(current + delta, 0), count - 1)
        outlineView.selectRowIndexes([next], byExtendingSelection: false)
        outlineView.scrollRowToVisible(next)
    }

    private func openSelected() {
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? TranscriptResultNode else { return }
        close()
        let result = node.result
        DispatchQueue.main.async { [weak self] in
            self?.onOpen?(result)
        }
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let group = item as? TranscriptGroupNode else { return groups.count }
        return group.results.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let group = item as? TranscriptGroupNode else { return groups[index] }
        return group.results[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is TranscriptGroupNode
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? TranscriptGroupNode {
            let identifier = NSUserInterfaceItemIdentifier("transcriptGroupRow")
            let view = outlineView.makeView(withIdentifier: identifier, owner: self) as? TranscriptGroupRowView ?? {
                let created = TranscriptGroupRowView(frame: .zero)
                created.identifier = identifier
                return created
            }()
            view.configure(with: group)
            return view
        }
        if let node = item as? TranscriptResultNode {
            let identifier = NSUserInterfaceItemIdentifier("transcriptResultRow")
            let view = outlineView.makeView(withIdentifier: identifier, owner: self) as? TranscriptResultRowView ?? {
                let created = TranscriptResultRowView(frame: .zero)
                created.identifier = identifier
                return created
            }()
            view.configure(with: node)
            return view
        }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        ThemedTableRowView()
    }
}
