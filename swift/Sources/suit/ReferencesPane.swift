import Cocoa

// The find-references pane (ROADMAP Phase 33): every use of a symbol, grouped by
// file, one row per line — reusing the RipgrepSearch grouped-by-file result
// stack (SearchFileGroup / SearchMatchNode / SearchFileRowView /
// SearchMatchRowView) and RipgrepSearcher, exactly as the sidebar's search does.
// Read-only: a row click opens the viewer at that line.
//
// References are gathered by a whole-word ripgrep search of the identifier
// (word-boundary so `foo` doesn't match `foobar`). When ctags backed the
// lookup the header names the symbol; when it didn't (no universal-ctags on the
// machine) the header says so — the roadmap's "degrades to an rg-word-search
// fallback with a header note". One references pane per window, reused like the
// diff / transcript panes.
final class ReferencesPaneContent: NSObject, PaneContent, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var pane: Pane?
    weak var tab: Tab?

    // Set by the window controller; receives the file's absolute path and line.
    var onOpenMatch: ((String, Int) -> Void)?

    private let containerView = NSView(frame: .zero)
    private let headerLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView(frame: .zero)
    private let outlineView = NSOutlineView(frame: .zero)

    private let searcher = RipgrepSearcher()

    private var groups: [SearchFileGroup] = []
    private var groupsByPath: [String: SearchFileGroup] = [:]
    private var matchCount = 0
    private var isSearching = false
    private var searchRoot: String?
    private var symbolName = ""

    var view: NSView { containerView }
    var focusTarget: NSView { outlineView }
    var defaultTitle: String { "References" }

    override init() {
        super.init()

        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headerLabel.textColor = Theme.textPrimary
        headerLabel.lineBreakMode = .byTruncatingTail
        containerView.addSubview(headerLabel)

        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = Theme.textFaint
        statusLabel.lineBreakMode = .byTruncatingTail
        containerView.addSubview(statusLabel)

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
        containerView.addSubview(scrollView)

        searcher.onMatches = { [weak self] matches in self?.appendMatches(matches) }
        searcher.onFinished = { [weak self] truncated, error in self?.searchFinished(truncated: truncated, error: error) }

        containerView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(layoutContents),
                                               name: NSView.frameDidChangeNotification, object: containerView)
    }

    // MARK: - Loading

    // ctagsAvailable only shapes the header note — references are always the rg
    // whole-word search (that word search IS the reference set the roadmap asks
    // for; ctags backs go-to-definition, which routes the single/multi cases).
    func load(symbol: String, root: String, ctagsAvailable: Bool) {
        symbolName = symbol
        searchRoot = root
        headerLabel.stringValue = SymbolNavigation.headerNote(symbol: symbol, ctagsAvailable: ctagsAvailable)
        tab?.contentTitleDidChange("References: \(symbol)")

        searcher.cancel()
        groups = []
        groupsByPath = [:]
        matchCount = 0
        outlineView.reloadData()

        guard !symbol.isEmpty else {
            statusLabel.stringValue = "No symbol"
            return
        }
        isSearching = true
        statusLabel.stringValue = "Searching…"
        searcher.start(RipgrepOptions(
            pattern: SymbolNavigation.wordSearchPattern(for: symbol),
            isRegex: true,
            caseSensitive: true,
            globs: "",
            rootDirectory: root
        ))
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
        updateStatus(suffix: "…")
    }

    private func searchFinished(truncated: Bool, error: String?) {
        isSearching = false
        if let error {
            statusLabel.stringValue = error
            return
        }
        updateStatus(suffix: truncated ? " (first \(RipgrepSearcher.maxMatches))" : "")
    }

    private func updateStatus(suffix: String) {
        if matchCount == 0 {
            statusLabel.stringValue = isSearching ? "Searching…" : "No references found"
            return
        }
        let files = groups.count == 1 ? "1 file" : "\(groups.count) files"
        statusLabel.stringValue = "\(matchCount) in \(files)\(suffix)"
    }

    // MARK: - Opening

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
            onOpenMatch?(searchRoot + "/" + node.match.relativePath, node.match.lineNumber)
        }
    }

    // MARK: - Layout

    @objc private func layoutContents() {
        let padding: CGFloat = 10
        let width = max(0, containerView.bounds.width - padding * 2)
        var y = containerView.bounds.height

        y -= 24
        headerLabel.frame = NSRect(x: padding, y: y, width: width, height: 18)
        y -= 16
        statusLabel.frame = NSRect(x: padding, y: y, width: width, height: 14)
        scrollView.frame = NSRect(x: 0, y: 0, width: containerView.bounds.width, height: max(0, y - 4))
    }

    // MARK: - NSOutlineViewDataSource

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

    // MARK: - NSOutlineViewDelegate (reuses the search row cells)

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? SearchFileGroup {
            let identifier = NSUserInterfaceItemIdentifier("searchFileRow")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SearchFileRowView ?? {
                let created = SearchFileRowView(frame: .zero)
                created.identifier = identifier
                return created
            }()
            cell.configure(with: group)
            return cell
        }
        if let node = item as? SearchMatchNode {
            let identifier = NSUserInterfaceItemIdentifier("searchMatchRow")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SearchMatchRowView ?? {
                let created = SearchMatchRowView(frame: .zero)
                created.identifier = identifier
                return created
            }()
            cell.configure(with: node)
            return cell
        }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        ThemedTableRowView()
    }

    // MARK: - Appearance / teardown

    var initialBackgroundColor: NSColor { Theme.bg }

    func applyBackground(_ color: NSColor) {
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = color.cgColor
    }

    func teardown() {
        NotificationCenter.default.removeObserver(self)
        searcher.cancel()
    }
}
