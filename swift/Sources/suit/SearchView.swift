import Cocoa

// The search half of the sidebar's Files tab (restyled in the
// "Minimal" sidebar redesign): search is no longer a permanent field stacked
// over the tree — the file browser (`idleView`) owns the whole tab until search
// is activated (⌘⇧F, or the header's magnifier). Activating drops a compact
// search bar — pattern field, a close button, and the regex/case/glob/scope
// controls collapsed behind an options toggle — over the tree and swaps in
// live results grouped by file. Clicking a match opens it in the window's
// viewer pane at that line. Escape or the close button dismisses search and
// returns to the file tree.
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
        }
    }

    private let searchField = NSSearchField(frame: .zero)
    private let closeButton = NSButton(title: "", target: nil, action: nil)
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
    // Whether the search bar is shown at all. False by default (the tab shows
    // only the file tree); flipped on by focusSearchField() and off by Escape
    // or the close button.
    private var searchActive = false
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

        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.toolTip = "Close search (Esc)"
        closeButton.contentTintColor = Theme.textDim
        if let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close search") {
            closeButton.image = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        } else {
            closeButton.title = "✕"
        }
        closeButton.target = self
        closeButton.action = #selector(closeSearch)
        addSubview(closeButton)

        optionsToggle.setButtonType(.pushOnPushOff)
        optionsToggle.isBordered = false
        optionsToggle.imagePosition = .imageOnly
        optionsToggle.contentTintColor = Theme.textDim
        optionsToggle.toolTip = "Search options"
        if let image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Search options") {
            optionsToggle.image = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
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
            toggle.isBordered = false
            toggle.controlSize = .small
            toggle.toolTip = tip
            toggle.target = self
            toggle.action = #selector(optionsChanged)
            addSubview(toggle)
        }
        styleModeToggles()

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
        updateOptionsToggleTint()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Reveal the search bar over the tree and put the cursor in the field.
    func focusSearchField() {
        if !searchActive {
            searchActive = true
            layoutContents()
            if searchField.stringValue.isEmpty { statusLabel.stringValue = "Type to search this project" }
        }
        window?.makeFirstResponder(searchField)
    }

    // Dismiss search: cancel any running rg, clear the field and results, hide
    // the bar, and hand the tab back to the file tree.
    @objc private func closeSearch() {
        searcher.cancel()
        searchField.stringValue = ""
        clearResults()
        statusLabel.stringValue = ""
        searchActive = false
        layoutContents()
        // Move focus off the (now hidden) field so keystrokes don't vanish.
        if let idleView, window?.firstResponder === searchField
            || (window?.firstResponder as? NSView)?.isDescendant(of: self) == true {
            window?.makeFirstResponder(idleView)
        }
    }

    // MARK: - Layout (manual, like the rest of the sidebar)

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContents()
    }

    private func layoutContents() {
        // The search controls exist only while search is active; otherwise the
        // file tree (idleView) owns the entire tab.
        let barControls: [NSView] = [searchField, closeButton, optionsToggle, statusLabel]
        for control in barControls { control.isHidden = !searchActive }
        let showOptions = searchActive && optionsExpanded
        regexToggle.isHidden = !showOptions
        caseToggle.isHidden = !showOptions
        scopePicker.isHidden = !showOptions
        globField.isHidden = !showOptions

        guard searchActive else {
            scrollView.isHidden = true
            idleView?.isHidden = false
            idleView?.frame = bounds
            return
        }
        idleView?.isHidden = true
        scrollView.isHidden = false

        let padding: CGFloat = 10
        let width = max(0, bounds.width - padding * 2)
        let button: CGFloat = 24
        let gap: CGFloat = 4
        var y = bounds.height

        // Search bar row: field on the left, then the options toggle and the
        // close button right-aligned.
        y -= 26
        closeButton.frame = NSRect(x: padding + width - button, y: y, width: button, height: 24)
        optionsToggle.frame = NSRect(x: closeButton.frame.minX - gap - button, y: y + 2, width: button, height: 20)
        searchField.frame = NSRect(x: padding, y: y, width: max(0, optionsToggle.frame.minX - gap - padding), height: 24)

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
    }

    // MARK: - Running searches

    // Live search while typing, debounced so rg isn't launched per keystroke.
    func controlTextDidChange(_ notification: Notification) {
        // Emptying the field clears results at once rather than waiting out the
        // debounce; search stays open (Escape/close returns to the tree).
        if searchField.stringValue.isEmpty {
            debounce?.cancel()
            searcher.cancel()
            clearResults()
            statusLabel.stringValue = "Type to search this project"
            return
        }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runSearch() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // Enter searches immediately (also how a glob edit is applied); Escape
    // dismisses search and returns to the file tree.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            debounce?.cancel()
            runSearch()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            closeSearch()
            return true
        default:
            return false
        }
    }

    @objc private func optionsChanged(_ sender: Any?) {
        styleModeToggles()
        updateOptionsToggleTint()
        runSearch()
    }

    // The .* / Aa toggles read as flat labels that glow amber while active,
    // matching the rest of the flat chrome rather than the old aqua bezels.
    private func styleModeToggles() {
        for (toggle, title) in [(regexToggle, ".*"), (caseToggle, "Aa")] {
            toggle.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: toggle.state == .on ? Theme.accent : Theme.textDim,
            ])
        }
    }

    @objc private func toggleOptions() {
        optionsExpanded = optionsToggle.state == .on
        UserDefaults.standard.set(optionsExpanded, forKey: "searchOptionsExpanded")
        layoutContents()
        updateOptionsToggleTint()
    }

    // The toggle glows amber while the options are open, and — with the
    // controls collapsed — also when a regex/case/scope/glob setting is
    // silently shaping results, so that stays discoverable. Otherwise dim.
    private func updateOptionsToggleTint() {
        let nonDefault = regexToggle.state == .on || caseToggle.state == .on
            || scopePicker.indexOfSelectedItem != SearchScope.project.rawValue
            || !globField.stringValue.isEmpty
        optionsToggle.contentTintColor = (optionsExpanded || nonDefault) ? Theme.accent : Theme.textDim
    }

    private func runSearch() {
        searcher.cancel()
        clearResults()

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
