import Cocoa

// The find-references pane: every use of a symbol across the
// project, grouped by file, each row a click into the viewer at that line.
// Reuses the search result view wholesale — SearchFileGroup /
// SearchMatchNode and their row views — fed by a ripgrep whole-word search of
// the identifier (`SymbolIndexCore.referenceRegex`), which naturally surfaces
// the definition among the uses. One references pane per window, reused like
// the diff / transcript panes.
//
// When ctags is unavailable, go-to-definition also lands here (there's no index
// to jump from), and the header says so — the sanctioned rg-word-search
// fallback.
// A flipped container that re-lays-out on resize — the pane viewport resizes
// its content view, and the header/list need to follow.
private final class ReferencesContainerView: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onLayout?()
    }
}

final class ReferencesPaneContent: NSObject, PaneContent, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var pane: Pane?
    weak var tab: Tab?

    private let container = ReferencesContainerView(frame: .zero)
    private let headerLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView(frame: .zero)
    private let outlineView = NSOutlineView(frame: .zero)

    private let searcher = RipgrepSearcher()

    private var symbol = ""
    private var searchRoot: String?
    private(set) var groups: [SearchFileGroup] = []
    private var groupsByPath: [String: SearchFileGroup] = [:]
    private var matchCount = 0
    private var isSearching = false
    private var fallbackNote: String?

    var view: NSView { container }
    var focusTarget: NSView { outlineView }
    var defaultTitle: String { "References" }
    var workingDirectory: String? { searchRoot }

    override init() {
        super.init()

        container.onLayout = { [weak self] in self?.layout() }

        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headerLabel.textColor = Theme.textPrimary
        headerLabel.lineBreakMode = .byTruncatingTail
        container.addSubview(headerLabel)

        noteLabel.font = .systemFont(ofSize: 10)
        noteLabel.textColor = Theme.textFaint
        noteLabel.lineBreakMode = .byTruncatingTail
        noteLabel.isHidden = true
        container.addSubview(noteLabel)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("reference"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 20
        outlineView.indentationPerLevel = 8
        outlineView.autoresizesOutlineColumn = false
        outlineView.backgroundColor = .clear
        outlineView.style = .sourceList
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        container.addSubview(scrollView)

        searcher.onMatches = { [weak self] matches in self?.appendMatches(matches) }
        searcher.onFinished = { [weak self] truncated, error in self?.searchFinished(truncated: truncated, errorMessage: error) }
    }

    // MARK: - Loading

    // `definitions` is the ctags answer (may be empty on the fallback path);
    // `fallbackNote`, when set, explains why the list is an rg word search rather
    // than an index lookup. The rg search runs regardless — it's the complete
    // "every use" list the phase asks for, definition included.
    func load(symbol: String, root: String, fallbackNote: String? = nil) {
        self.symbol = symbol
        self.searchRoot = root
        self.fallbackNote = fallbackNote
        tab?.contentTitleDidChange("References — \(symbol)")
        clearResults()
        updateHeader()

        isSearching = true
        searcher.start(RipgrepOptions(
            pattern: SymbolIndexCore.referenceRegex(for: symbol),
            isRegex: true,
            caseSensitive: true,
            globs: "",
            rootDirectory: root
        ))
    }

    private func clearResults() {
        groups = []
        groupsByPath = [:]
        matchCount = 0
        outlineView.reloadData()
    }

    private func appendMatches(_ matches: [SearchMatch]) {
        guard isSearching else { return }
        var newGroups: [SearchFileGroup] = []
        for match in matches {
            let group: SearchFileGroup
            if let existing = groupsByPath[match.relativePath] {
                group = existing
            } else {
                group = SearchFileGroup(relativePath: match.relativePath)
                groupsByPath[match.relativePath] = group
                groups.append(group)
                newGroups.append(group)
            }
            group.matches.append(SearchMatchNode(match: match))
        }
        matchCount += matches.count
        outlineView.reloadData()
        for group in newGroups { outlineView.expandItem(group) }
        updateHeader()
    }

    private func searchFinished(truncated: Bool, errorMessage: String?) {
        isSearching = false
        updateHeader(truncated: truncated, error: errorMessage)
    }

    private func updateHeader(truncated: Bool = false, error: String? = nil) {
        let files = groups.count == 1 ? "1 file" : "\(groups.count) files"
        if let error {
            headerLabel.stringValue = symbol
            noteLabel.stringValue = error
        } else if isSearching {
            headerLabel.stringValue = "\(symbol) — searching…"
            noteLabel.stringValue = fallbackNote ?? ""
        } else if matchCount == 0 {
            headerLabel.stringValue = "\(symbol) — no references"
            noteLabel.stringValue = fallbackNote ?? ""
        } else {
            let suffix = truncated ? " (first \(RipgrepSearcher.maxMatches))" : ""
            headerLabel.stringValue = "\(symbol) — \(matchCount) references in \(files)\(suffix)"
            noteLabel.stringValue = fallbackNote ?? ""
        }
        noteLabel.isHidden = noteLabel.stringValue.isEmpty
        layout()
    }

    // MARK: - Opening references

    @objc private func rowClicked() {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)
        if let group = item as? SearchFileGroup {
            if outlineView.isItemExpanded(group) {
                outlineView.collapseItem(group)
            } else {
                outlineView.expandItem(group)
            }
        } else if let node = item as? SearchMatchNode, let searchRoot {
            pane?.openFileLink(path: searchRoot + "/" + node.match.relativePath, line: node.match.lineNumber)
        }
    }

    // MARK: - Layout

    private func layout() {
        let padding: CGFloat = 10
        let width = max(0, container.bounds.width - padding * 2)
        var y: CGFloat = 8
        headerLabel.frame = NSRect(x: padding, y: y, width: width, height: 16)
        y += 18
        if !noteLabel.isHidden {
            noteLabel.frame = NSRect(x: padding, y: y, width: width, height: 14)
            y += 16
        }
        scrollView.frame = NSRect(x: 0, y: y, width: container.bounds.width, height: max(0, container.bounds.height - y))
    }

    // MARK: - NSOutlineViewDataSource / Delegate (mirrors SearchView)

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let group = item as? SearchFileGroup else { return groups.count }
        return group.matches.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let group = item as? SearchFileGroup else { return groups[index] }
        return group.matches[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SearchFileGroup
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? SearchFileGroup {
            let identifier = NSUserInterfaceItemIdentifier("searchFileRow")
            let view = outlineView.makeView(withIdentifier: identifier, owner: self) as? SearchFileRowView ?? {
                let created = SearchFileRowView(frame: .zero)
                created.identifier = identifier
                return created
            }()
            view.configure(with: group)
            return view
        }
        if let node = item as? SearchMatchNode {
            let identifier = NSUserInterfaceItemIdentifier("searchMatchRow")
            let view = outlineView.makeView(withIdentifier: identifier, owner: self) as? SearchMatchRowView ?? {
                let created = SearchMatchRowView(frame: .zero)
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

    // MARK: - Appearance

    var initialBackgroundColor: NSColor { Theme.bg }

    func applyBackground(_ color: NSColor) {
        container.wantsLayer = true
        container.layer?.backgroundColor = color.cgColor
    }

    func teardown() {
        searcher.cancel()
    }
}
