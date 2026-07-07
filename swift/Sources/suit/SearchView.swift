import Cocoa

// The search half of the sidebar's Files tab (ROADMAP Phase 2): pattern field
// with the regex/case toggles, glob filter, and scope picker collapsed behind
// its options button (only the input shows by default), and live-updating
// results grouped by file. Clicking a match opens it in the window's viewer pane at
// that line. While the pattern is empty, the results area shows `idleView`
// (the file browser) instead, so the tab reads as "search input over the
// files".
final class SearchView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSTextFieldDelegate {
    // Set by the window controller; receives the file's absolute path and line.
    var onOpenMatch: ((String, Int) -> Void)?
    // Resolves the picked scope to a directory to run rg in, plus a short
    // label for the status line. nil falls back to doing nothing (no project).
    var scopeResolver: ((SearchScope) -> (root: String, label: String)?)?
    // Shown in the results area while no pattern is typed (the sidebar hands
    // in its FileBrowserView). Swapped for the results list as soon as a
    // search pattern exists, and back when the field is cleared.
    var idleView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let idleView {
                addSubview(idleView)
            }
            layoutContents()
            updateIdleVisibility()
        }
    }

    private let searchField = NSSearchField(frame: .zero)
    private let optionsToggle = NSButton(title: "", target: nil, action: nil)
    private let regexToggle = NSButton(title: ".*", target: nil, action: nil)
    private let caseToggle = NSButton(title: "Aa", target: nil, action: nil)
    private let scopePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let globField = NSTextField(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView(frame: .zero)
    private let outlineView = NSOutlineView(frame: .zero)

    private let searcher = RipgrepSearcher()
    private var debounce: DispatchWorkItem?

    var groups: [SearchFileGroup] = []
    private var groupsByPath: [String: SearchFileGroup] = [:]
    private var matchCount = 0
    private var searchRoot: String?
    private var scopeLabel = ""
    private var isSearching = false
    // The regex/case/scope/glob controls stay hidden behind the toggle next to
    // the search field until asked for; only the input itself is always shown.
    private var optionsExpanded = UserDefaults.standard.bool(forKey: "searchOptionsExpanded")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        searchField.placeholderString = "Search project…"
        searchField.font = .systemFont(ofSize: 12)
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false
        addSubview(searchField)

        optionsToggle.setButtonType(.pushOnPushOff)
        optionsToggle.bezelStyle = .texturedRounded
        optionsToggle.controlSize = .small
        optionsToggle.toolTip = "Search options"
        if let image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Search options") {
            optionsToggle.image = image
        } else {
            optionsToggle.title = "⋯"
            optionsToggle.font = .systemFont(ofSize: 10, weight: .semibold)
        }
        optionsToggle.state = optionsExpanded ? .on : .off
        optionsToggle.target = self
        optionsToggle.action = #selector(toggleOptions)
        addSubview(optionsToggle)

        for (toggle, tip) in [(regexToggle, "Regular expression"), (caseToggle, "Match case")] {
            toggle.setButtonType(.pushOnPushOff)
            toggle.bezelStyle = .texturedRounded
            toggle.controlSize = .small
            toggle.font = .systemFont(ofSize: 10, weight: .semibold)
            toggle.toolTip = tip
            toggle.target = self
            toggle.action = #selector(optionsChanged)
            addSubview(toggle)
        }

        scopePicker.controlSize = .small
        scopePicker.font = .systemFont(ofSize: 10)
        for scope in SearchScope.allCases {
            scopePicker.addItem(withTitle: scope.label)
        }
        scopePicker.target = self
        scopePicker.action = #selector(optionsChanged)
        addSubview(scopePicker)

        globField.placeholderString = "Files: *.swift, go/**"
        globField.font = .systemFont(ofSize: 11)
        globField.delegate = self
        globField.bezelStyle = .roundedBezel
        globField.controlSize = .small
        addSubview(globField)

        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = Theme.textFaint
        statusLabel.lineBreakMode = .byTruncatingTail
        addSubview(statusLabel)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("match"))
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
        addSubview(scrollView)

        searcher.onMatches = { [weak self] matches in
            self?.appendMatches(matches)
        }
        searcher.onFinished = { [weak self] truncated, errorMessage in
            self?.searchFinished(truncated: truncated, errorMessage: errorMessage)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func focusSearchField() {
        window?.makeFirstResponder(searchField)
    }

    // MARK: - Layout (manual, like the rest of the sidebar)

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContents()
    }

    private func layoutContents() {
        let padding: CGFloat = 10
        let width = max(0, bounds.width - padding * 2)
        var y = bounds.height

        y -= 26
        let optionsButtonWidth: CGFloat = 30
        searchField.frame = NSRect(x: padding, y: y, width: max(0, width - optionsButtonWidth - 4), height: 24)
        optionsToggle.frame = NSRect(x: padding + width - optionsButtonWidth, y: y + 2, width: optionsButtonWidth, height: 20)

        regexToggle.isHidden = !optionsExpanded
        caseToggle.isHidden = !optionsExpanded
        scopePicker.isHidden = !optionsExpanded
        globField.isHidden = !optionsExpanded
        if optionsExpanded {
            y -= 26
            let toggleWidth: CGFloat = 34
            regexToggle.frame = NSRect(x: padding, y: y, width: toggleWidth, height: 20)
            caseToggle.frame = NSRect(x: padding + toggleWidth + 4, y: y, width: toggleWidth, height: 20)
            let scopeX = padding + (toggleWidth + 4) * 2
            scopePicker.frame = NSRect(x: scopeX, y: y, width: max(0, bounds.width - scopeX - padding), height: 20)

            y -= 24
            globField.frame = NSRect(x: padding, y: y, width: width, height: 20)
        }

        y -= 18
        statusLabel.frame = NSRect(x: padding, y: y, width: width, height: 14)

        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, y - 4))
        idleView?.frame = scrollView.frame
    }

    // The file browser owns the results area until there's something to
    // search for.
    private func updateIdleVisibility() {
        let idle = searchField.stringValue.isEmpty
        scrollView.isHidden = idle && idleView != nil
        idleView?.isHidden = !idle
    }

    // MARK: - Running searches

    // Live search while typing, debounced so rg isn't launched per keystroke.
    func controlTextDidChange(_ notification: Notification) {
        // Swap browser/results immediately — clearing the field shouldn't
        // wait out the debounce to bring the file tree back.
        updateIdleVisibility()
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runSearch() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // Enter searches immediately (also how a glob edit is applied).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        debounce?.cancel()
        runSearch()
        return true
    }

    @objc private func optionsChanged(_ sender: Any?) {
        updateOptionsToggleTint()
        runSearch()
    }

    @objc private func toggleOptions() {
        optionsExpanded = optionsToggle.state == .on
        UserDefaults.standard.set(optionsExpanded, forKey: "searchOptionsExpanded")
        layoutContents()
        updateOptionsToggleTint()
    }

    // With the controls collapsed, an active regex/case/scope/glob setting
    // would silently shape results — tint the toggle so it's discoverable.
    private func updateOptionsToggleTint() {
        let nonDefault = regexToggle.state == .on || caseToggle.state == .on
            || scopePicker.indexOfSelectedItem != SearchScope.project.rawValue
            || !globField.stringValue.isEmpty
        optionsToggle.contentTintColor = (!optionsExpanded && nonDefault) ? Theme.accent : nil
    }

    private func runSearch() {
        searcher.cancel()
        clearResults()
        updateIdleVisibility()

        let pattern = searchField.stringValue
        guard !pattern.isEmpty else {
            statusLabel.stringValue = ""
            return
        }
        let scope = SearchScope(rawValue: scopePicker.indexOfSelectedItem) ?? .project
        guard let resolved = scopeResolver?(scope) else {
            statusLabel.stringValue = "No directory to search"
            return
        }
        searchRoot = resolved.root
        scopeLabel = resolved.label
        isSearching = true
        statusLabel.stringValue = "Searching \(scopeLabel)…"
        searcher.start(RipgrepOptions(
            pattern: pattern,
            isRegex: regexToggle.state == .on,
            caseSensitive: caseToggle.state == .on,
            globs: globField.stringValue,
            rootDirectory: resolved.root
        ))
    }

    private func clearResults() {
        groups = []
        groupsByPath = [:]
        matchCount = 0
        isSearching = false
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
        // Groups compare by path, so reload keeps the user's collapses while
        // counts on existing groups tick up.
        outlineView.reloadData()
        for group in newGroups {
            outlineView.expandItem(group)
        }
        updateStatus(suffix: "…")
    }

    private func searchFinished(truncated: Bool, errorMessage: String?) {
        isSearching = false
        if let errorMessage {
            statusLabel.stringValue = errorMessage
            return
        }
        updateStatus(suffix: truncated ? " (first \(RipgrepSearcher.maxMatches))" : "")
    }

    private func updateStatus(suffix: String) {
        if matchCount == 0 {
            statusLabel.stringValue = isSearching ? "Searching \(scopeLabel)…" : "No matches in \(scopeLabel)"
            return
        }
        let files = groups.count == 1 ? "1 file" : "\(groups.count) files"
        statusLabel.stringValue = "\(matchCount) in \(files) — \(scopeLabel)\(suffix)"
    }

    // MARK: - Opening matches

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
}
