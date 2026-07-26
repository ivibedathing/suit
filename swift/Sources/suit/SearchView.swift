import Cocoa

// The sidebar's Search tab: project-wide find *and* replace, on its own
// activity-bar icon directly below Files.
//
// It used to be half of the Files tab — a bar that dropped over the file tree on
// ⌘⇧F and handed the tab back on Escape. Sharing one tab meant search could never
// be more than a temporary overlay: no room for a replace row, and every search
// cost you sight of the tree. Now the tree owns Files outright and this owns its
// own tab, so the pattern, the replacement, the options and the results all stay
// put — switch to Files and back and your matches are still there.
//
// The chrome follows VS Code's search panel, which is the layout everyone
// already has in their fingers:
//
//   SEARCH                         ↻  ⌫  ☰  ⌄       ← header + toolbar
//   ⌄ ┌──────────────────── Aa ab .*┐               ← pattern, toggles inside
//     └──────────────────── AB ┘  ⇄                 ← replacement, Replace All
//                                  ⋯                ← scope / globs live here
//   8 results in 1 file — suit
//   ▾ 🖹 build.sh  scripts/          3   ⇄ ✕        ← file row, actions on hover
//     │ APP="$BUILD_DIR/Suit.app"              12
//
// Two ideas carry the layout. The mode toggles sit *inside* the field they
// modify (SearchFieldBox) instead of on a row of their own, so ".*" reads as
// "this pattern is a regex" rather than as a mode the tab is in. And the two
// rows collapse independently: the chevron in the left gutter hides the
// replacement (a search-only trip is the common one), while "⋯" hides the scope
// and glob controls, which are the ones you set once and forget.
//
// Clicking a match opens it in the window's viewer pane at that line. Replace
// All confirms first and then rewrites the listed files on disk — see
// SearchReplace, which owns every decision about that pass, including the
// preserve-case transform behind the AB toggle.
final class SearchView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    // Set by the window controller; receives the file's absolute path and line.
    var onOpenMatch: ((String, Int) -> Void)?
    // Resolves the picked scope to a directory to run rg in, plus a short
    // label for the status line. nil falls back to doing nothing (no project).
    var scopeResolver: ((SearchScope) -> (root: String, label: String)?)?
    // Escape on an already-empty field asks to leave the tab (the sidebar sends
    // it back to Files). The tab has no ✕ of its own: the activity bar is how a
    // tab is left, and a second close affordance would just disagree with it.
    var onDismiss: (() -> Void)?
    // Fired after a replace rewrote files, so the window can refresh what it
    // derives from them (git status letters, file badges).
    var onFilesChanged: ((_ root: String, _ relativePaths: [String]) -> Void)?
    // The live pattern as a FindQuery, for the open viewers to highlight their
    // own occurrences of — nil once the field is empty. Fired on every state the
    // results themselves change on (typing settles, Enter, a toggle, a clear), so
    // the wash in the panes can never outlive the list that explains it.
    var onHighlightQueryChange: ((FindQuery?) -> Void)?

    // The tab's title band, shared with every other sidebar tab.
    private static let headerHeight = SidebarTitle.height
    // The left gutter the replace chevron lives in. Both field boxes start here,
    // so the chevron reads as owning the pair rather than as decoration on the
    // first row.
    private static let gutterWidth: CGFloat = 20

    private let headerLabel = SidebarTitle.label("SEARCH")
    private let refreshButton = NSButton(frame: .zero)
    private let clearButton = NSButton(frame: .zero)
    private let viewModeButton = NSButton(frame: .zero)
    private let collapseButton = NSButton(frame: .zero)

    private let replaceToggle = NSButton(frame: .zero)
    private let searchBox = SearchFieldBox(placeholder: "Search")
    private let replaceBox = SearchFieldBox(placeholder: "Replace")
    private let replaceAllButton = NSButton(frame: .zero)

    private let caseToggle: NSButton
    private let wordToggle: NSButton
    private let regexToggle: NSButton
    private let preserveCaseToggle: NSButton

    private let detailsToggle = NSButton(frame: .zero)
    private let scopePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let globBox = SearchFieldBox(placeholder: "Files to include: *.swift, go/**")

    private let statusLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView(frame: .zero)
    private let outlineView = NSOutlineView(frame: .zero)

    private let searcher = RipgrepSearcher()
    private var debounce: DispatchWorkItem?

    var groups: [SearchFileGroup] = []
    // The same matches, flattened, for list mode. Kept alongside `groups` rather
    // than derived per data-source call: an outline asks for its children far
    // more often than results change, and rg streams in thousands of them.
    var flatMatches: [SearchMatchNode] = []
    // Results as a file tree (the default) or as one flat row per match. Only
    // the shape of the outline changes; the same nodes back both.
    var isFlatList = UserDefaults.standard.bool(forKey: "searchResultsFlat")

    private var groupsByPath: [String: SearchFileGroup] = [:]
    private var matchCount = 0
    private var searchRoot: String?
    private var scopeLabel = ""
    private var isSearching = false
    // Whether rg stopped at its match cap. Read by the replace gate: a capped
    // list is a partial view of the matches, and replacing a partial view is a
    // silent under-replace.
    private var resultsTruncated = false
    // The replacement row and the scope/glob controls each collapse on their
    // own, and each remembers its state — a session that never replaces should
    // not pay a row of chrome for it on every launch.
    private var replaceExpanded = UserDefaults.standard.bool(forKey: "searchReplaceExpanded")
    private var detailsExpanded = UserDefaults.standard.bool(forKey: "searchDetailsExpanded")
    // What the collapse-all button does next. Tracked rather than derived,
    // because "is anything expanded" is only answerable by walking every row.
    private var resultsCollapsed = false

    override init(frame frameRect: NSRect) {
        // makeToggle wants a target at construction and `self` isn't available
        // until after super.init; the class object stands in and is rebound below.
        caseToggle = SearchFieldBox.makeToggle(title: "Aa", tooltip: "Match Case",
                                               target: SearchView.self, action: #selector(optionsChanged))
        wordToggle = SearchFieldBox.makeToggle(title: "ab", underlined: true, tooltip: "Match Whole Word",
                                               target: SearchView.self, action: #selector(optionsChanged))
        regexToggle = SearchFieldBox.makeToggle(title: ".*", tooltip: "Use Regular Expression",
                                                target: SearchView.self, action: #selector(optionsChanged))
        preserveCaseToggle = SearchFieldBox.makeToggle(title: "AB", tooltip: "Preserve Case",
                                                       target: SearchView.self, action: #selector(preserveCaseChanged))
        super.init(frame: frameRect)

        for toggle in [caseToggle, wordToggle, regexToggle, preserveCaseToggle] {
            toggle.target = self
        }

        addSubview(headerLabel)

        configure(toolbarButton: refreshButton, symbol: "arrow.clockwise",
                  tooltip: "Refresh", action: #selector(refreshClicked))
        configure(toolbarButton: clearButton, symbol: "xmark.square",
                  tooltip: "Clear Search Results", action: #selector(clearClicked))
        configure(toolbarButton: viewModeButton, symbol: "list.bullet",
                  tooltip: "View as List", action: #selector(toggleViewMode))
        configure(toolbarButton: collapseButton, symbol: "rectangle.compress.vertical",
                  tooltip: "Collapse All", action: #selector(toggleCollapseAll))

        replaceToggle.isBordered = false
        replaceToggle.imagePosition = .imageOnly
        replaceToggle.contentTintColor = Theme.textDim
        replaceToggle.toolTip = "Toggle Replace"
        replaceToggle.target = self
        replaceToggle.action = #selector(toggleReplace)
        replaceToggle.refusesFirstResponder = true
        addSubview(replaceToggle)

        searchBox.field.delegate = self
        for toggle in [caseToggle, wordToggle, regexToggle] {
            searchBox.addToggle(toggle)
        }
        addSubview(searchBox)

        replaceBox.field.delegate = self
        replaceBox.addToggle(preserveCaseToggle)
        addSubview(replaceBox)

        configure(toolbarButton: replaceAllButton, symbol: "arrow.2.squarepath",
                  tooltip: "Replace All", action: #selector(replaceAllClicked))
        configure(toolbarButton: detailsToggle, symbol: "ellipsis",
                  tooltip: "Toggle Search Details", action: #selector(toggleDetails))

        scopePicker.controlSize = .small
        scopePicker.font = .systemFont(ofSize: 10)
        for scope in SearchScope.allCases {
            scopePicker.addItem(withTitle: scope.label)
        }
        scopePicker.target = self
        scopePicker.action = #selector(optionsChanged)
        addSubview(scopePicker)

        globBox.field.delegate = self
        globBox.field.font = .systemFont(ofSize: 11)
        addSubview(globBox)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = Theme.textDim
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.stringValue = "Type to search this project"
        addSubview(statusLabel)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("match"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 22
        outlineView.indentationPerLevel = 10
        outlineView.autoresizesOutlineColumn = false
        // .inset, matching the Files tree — not .sourceList, which backs the
        // scroll view with AppKit's sidebar material (blendingMode
        // .behindWindow). Behind-window blending samples the desktop, not the
        // views under it, so the results list took its ground from whatever
        // wallpaper was behind the window instead of from the palette.
        // Order matters: the style resets backgroundColor, so clear it after.
        outlineView.style = .inset
        outlineView.backgroundColor = .clear
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
        updateReplaceChevron()
        updateDetailsTint()
        updateViewModeButton()
        updateCollapseButton()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure(toolbarButton button: NSButton, symbol: String,
                           tooltip: String, action: Selector) {
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = Self.toolbarImage(symbol, describedAs: tooltip)
        button.contentTintColor = Theme.textDim
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.refusesFirstResponder = true
        addSubview(button)
    }

    private static func toolbarImage(_ symbol: String, describedAs description: String?) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
    }

    // Put the cursor in the pattern field: ⌘⇧F, the file header's magnifier and
    // simply selecting the tab all land here.
    func focusSearchField() {
        window?.makeFirstResponder(searchBox.field)
    }

    // Live theme switch. These tints are set on controls at init, so the
    // controller's recursive needsDisplay sweep — which only repaints
    // draw()-based chrome — can't reach them; SidebarView.reapplyTheme() calls
    // this instead.
    func reapplyTheme() {
        statusLabel.textColor = Theme.textDim
        for button in [refreshButton, clearButton, viewModeButton, collapseButton,
                       replaceAllButton, replaceToggle] {
            button.contentTintColor = Theme.textDim
        }
        for toggle in [caseToggle, wordToggle, regexToggle, preserveCaseToggle] {
            SearchFieldBox.style(toggle: toggle)
        }
        for box in [searchBox, replaceBox, globBox] {
            box.reapplyTheme()
        }
        updateDetailsTint()
        // Row views cache token colors in their attributed strings, so the rows
        // have to be rebuilt rather than just repainted.
        outlineView.reloadData()
    }

    // Escape: clear a typed pattern, and — on an already-clear field — hand the
    // sidebar back to the file tree, so ⌘⇧F, Escape, Escape ends where it started.
    private func dismiss() {
        guard searchBox.field.stringValue.isEmpty else {
            clearSearch()
            return
        }
        onDismiss?()
    }

    private func clearSearch() {
        debounce?.cancel()
        searcher.cancel()
        searchBox.field.stringValue = ""
        clearResults()
        // The wash in the open panes must not outlive the list that explains it,
        // and this is the other way the list goes away (Escape, and the header's
        // Clear button) besides emptying the field by hand.
        onHighlightQueryChange?(nil)
        statusLabel.stringValue = "Type to search this project"
    }

    // MARK: - Layout (manual, like the rest of the sidebar)

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContents()
    }

    private func layoutContents() {
        replaceBox.isHidden = !replaceExpanded
        replaceAllButton.isHidden = !replaceExpanded
        scopePicker.isHidden = !detailsExpanded
        globBox.isHidden = !detailsExpanded

        let padding: CGFloat = 10
        let button: CGFloat = 20
        var y = bounds.height

        // Header: caption left, toolbar right, in one 26pt band.
        y -= Self.headerHeight
        headerLabel.sizeToFit()
        headerLabel.frame.origin = NSPoint(
            x: padding,
            y: y + (Self.headerHeight - headerLabel.frame.height) / 2
        )
        var toolbarX = bounds.width - 6
        for item in [collapseButton, viewModeButton, clearButton, refreshButton] {
            toolbarX -= button
            item.frame = NSRect(x: toolbarX, y: y + (Self.headerHeight - button) / 2,
                                width: button, height: button)
            toolbarX -= 2
        }

        // The field block: pattern always, replacement behind the chevron, which
        // spans whatever the block ends up being tall.
        let left = Self.gutterWidth
        let boxWidth = max(0, bounds.width - padding - left)
        y -= 4
        let blockTop = y
        y -= SearchFieldBox.height
        searchBox.frame = NSRect(x: left, y: y, width: boxWidth, height: SearchFieldBox.height)
        if replaceExpanded {
            y -= 4 + SearchFieldBox.height
            let replaceAllWidth: CGFloat = 22
            replaceAllButton.frame = NSRect(x: bounds.width - padding - replaceAllWidth,
                                            y: y + (SearchFieldBox.height - 22) / 2,
                                            width: replaceAllWidth, height: 22)
            replaceBox.frame = NSRect(x: left, y: y,
                                      width: max(0, replaceAllButton.frame.minX - 6 - left),
                                      height: SearchFieldBox.height)
        }
        replaceToggle.frame = NSRect(x: 2, y: y, width: 16, height: max(0, blockTop - y))

        // "⋯" is the disclosure for the scope and glob controls, so it sits
        // above them and stays put when they hide.
        y -= 20
        detailsToggle.frame = NSRect(x: bounds.width - padding - button, y: y, width: button, height: 18)
        if detailsExpanded {
            y -= 22
            scopePicker.frame = NSRect(x: left, y: y, width: boxWidth, height: 20)
            y -= SearchFieldBox.height + 4
            globBox.frame = NSRect(x: left, y: y, width: boxWidth, height: SearchFieldBox.height)
        }

        y -= 24
        statusLabel.frame = NSRect(x: padding, y: y, width: max(0, bounds.width - padding * 2), height: 16)

        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, y - 4))
    }

    // MARK: - Running searches

    // Live search while typing, debounced so rg isn't launched per keystroke.
    func controlTextDidChange(_ notification: Notification) {
        // The replacement template is not part of the search: typing one must
        // neither re-run rg nor clear the matches it is about to be applied to.
        if (notification.object as AnyObject?) === replaceBox.field { return }
        // A glob is one of the two things "⋯" lights up for, and it can be typed
        // while the details are open and then hidden again.
        if (notification.object as AnyObject?) === globBox.field { updateDetailsTint() }
        // Emptying the field clears results at once rather than waiting out the
        // debounce.
        if searchBox.field.stringValue.isEmpty {
            debounce?.cancel()
            searcher.cancel()
            clearResults()
            onHighlightQueryChange?(nil)
            statusLabel.stringValue = "Type to search this project"
            return
        }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runSearch() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // The boxes draw their own focus ring and have no way to notice the field
    // inside them took first responder — see SearchFieldBox.
    func controlTextDidBeginEditing(_ notification: Notification) {
        setFocus(true, for: notification.object as AnyObject?)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        setFocus(false, for: notification.object as AnyObject?)
    }

    private func setFocus(_ focused: Bool, for object: AnyObject?) {
        for box in [searchBox, replaceBox, globBox] where object === box.field {
            box.setFocused(focused)
        }
    }

    // Enter searches immediately (also how a glob edit is applied) — or, from the
    // replace field, starts the replace, since that is the only thing Enter there
    // could mean. Escape clears, then leaves the tab.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if control === replaceBox.field {
                replaceAll()
                return true
            }
            debounce?.cancel()
            runSearch()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        default:
            return false
        }
    }

    @objc private func optionsChanged(_ sender: Any?) {
        for toggle in [caseToggle, wordToggle, regexToggle] {
            SearchFieldBox.style(toggle: toggle)
        }
        updateDetailsTint()
        runSearch()
    }

    // Preserve-case shapes the replacement, not the search, so it must not
    // re-run rg — that would throw away the results it is about to act on.
    @objc private func preserveCaseChanged(_ sender: Any?) {
        SearchFieldBox.style(toggle: preserveCaseToggle)
    }

    @objc private func toggleReplace() {
        replaceExpanded.toggle()
        UserDefaults.standard.set(replaceExpanded, forKey: "searchReplaceExpanded")
        updateReplaceChevron()
        layoutContents()
        if replaceExpanded {
            window?.makeFirstResponder(replaceBox.field)
        }
    }

    @objc private func toggleDetails() {
        detailsExpanded.toggle()
        UserDefaults.standard.set(detailsExpanded, forKey: "searchDetailsExpanded")
        layoutContents()
        updateDetailsTint()
    }

    private func updateReplaceChevron() {
        let symbol = replaceExpanded ? "chevron.down" : "chevron.right"
        replaceToggle.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Toggle Replace")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
    }

    // "⋯" glows amber while the details are open, and — with them collapsed —
    // also when a scope or glob is silently shaping results, so that stays
    // discoverable rather than becoming a mystery empty result set.
    private func updateDetailsTint() {
        let nonDefault = scopePicker.indexOfSelectedItem != SearchScope.project.rawValue
            || !globBox.field.stringValue.isEmpty
        detailsToggle.contentTintColor = (detailsExpanded || nonDefault) ? Theme.accent : Theme.textDim
    }

    @objc private func refreshClicked() {
        debounce?.cancel()
        runSearch()
    }

    @objc private func clearClicked() {
        clearSearch()
    }

    @objc private func toggleViewMode() {
        isFlatList.toggle()
        UserDefaults.standard.set(isFlatList, forKey: "searchResultsFlat")
        updateViewModeButton()
        outlineView.reloadData()
        if !isFlatList { expandAllGroups() }
    }

    private func updateViewModeButton() {
        viewModeButton.image = Self.toolbarImage(isFlatList ? "list.bullet.indent" : "list.bullet",
                                                 describedAs: nil)
        viewModeButton.toolTip = isFlatList ? "View as Tree" : "View as List"
        // Collapsing is a tree idea; a flat list has nothing to collapse.
        collapseButton.isEnabled = !isFlatList
    }

    @objc private func toggleCollapseAll() {
        resultsCollapsed.toggle()
        if resultsCollapsed {
            for group in groups { outlineView.collapseItem(group) }
            updateCollapseButton()
        } else {
            expandAllGroups()
        }
    }

    private func expandAllGroups() {
        for group in groups { outlineView.expandItem(group) }
        resultsCollapsed = false
        updateCollapseButton()
    }

    private func updateCollapseButton() {
        collapseButton.image = Self.toolbarImage(
            resultsCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
            describedAs: nil
        )
        collapseButton.toolTip = resultsCollapsed ? "Expand All" : "Collapse All"
    }

    private func runSearch() {
        searcher.cancel()
        clearResults()

        let pattern = searchBox.field.stringValue
        // The open viewers highlight from the same query the on-disk replace
        // would use (replaceQuery, i.e. SearchReplace.query), so what a pane
        // washes is exactly what rg listed and what Replace All would rewrite —
        // three readings of one pattern that must not drift apart. That is also
        // why whole-word travels through the same property rather than being
        // spelled out again here.
        onHighlightQueryChange?(pattern.isEmpty ? nil : replaceQuery)
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
            wholeWord: wordToggle.state == .on,
            globs: globBox.field.stringValue,
            rootDirectory: resolved.root
        ))
    }

    private func clearResults() {
        groups = []
        flatMatches = []
        groupsByPath = [:]
        matchCount = 0
        isSearching = false
        resultsTruncated = false
        resultsCollapsed = false
        updateCollapseButton()
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
            let node = SearchMatchNode(match: match)
            group.matches.append(node)
            flatMatches.append(node)
        }
        matchCount += matches.count
        // Groups compare by path, so reload keeps the user's collapses while
        // counts on existing groups tick up.
        outlineView.reloadData()
        if !resultsCollapsed {
            for group in newGroups {
                outlineView.expandItem(group)
            }
        }
        updateStatus(suffix: "…")
    }

    private func searchFinished(truncated: Bool, errorMessage: String?) {
        isSearching = false
        resultsTruncated = truncated
        if let errorMessage {
            statusLabel.stringValue = errorMessage
            return
        }
        updateStatus(suffix: truncated ? " (first \(RipgrepSearcher.maxMatches))" : "")
    }

    private func updateStatus(suffix: String) {
        if matchCount == 0 {
            statusLabel.stringValue = isSearching ? "Searching \(scopeLabel)…" : "No results in \(scopeLabel)"
            return
        }
        let results = matchCount == 1 ? "1 result" : "\(matchCount) results"
        let files = groups.count == 1 ? "1 file" : "\(groups.count) files"
        statusLabel.stringValue = "\(results) in \(files) — \(scopeLabel)\(suffix)"
    }

    // MARK: - Replacing across the project

    @objc private func replaceAllClicked() {
        replaceAll()
    }

    private var replaceQuery: FindQuery {
        SearchReplace.query(pattern: searchBox.field.stringValue,
                            isRegex: regexToggle.state == .on,
                            caseSensitive: caseToggle.state == .on,
                            wholeWord: wordToggle.state == .on)
    }

    // Confirm, then rewrite every listed file. The gate, the prose and the pass
    // itself all live in SearchReplace; this half only shows what it says and
    // moves the results along afterwards.
    private func replaceAll() {
        let pattern = searchBox.field.stringValue
        let gate = SearchReplace.gate(pattern: pattern,
                                      fileCount: groups.count,
                                      matchCount: matchCount,
                                      isSearching: isSearching,
                                      truncated: resultsTruncated)
        guard case .ready(let files, let replacements) = gate else {
            statusLabel.stringValue = gate.refusal ?? ""
            return
        }
        guard let root = searchRoot else {
            statusLabel.stringValue = "No directory to replace in"
            return
        }
        let template = replaceBox.field.stringValue
        let prose = SearchReplace.confirmation(files: files, replacements: replacements,
                                               template: template, scopeLabel: scopeLabel)
        // Snapshot what the confirm was shown for: the sheet is async, and a
        // still-typing debounce could otherwise swap the results under it.
        confirm(prose: prose, root: root, paths: groups.map(\.relativePath), template: template)
    }

    // One file's matches, from the ⇄ a file row reveals on hover. Truncation
    // doesn't gate this the way it gates Replace All: the pass rewrites the
    // whole file, so a capped *file list* can't make this one under-replace —
    // only a still-streaming search can.
    func replaceInFile(_ group: SearchFileGroup) {
        let gate = SearchReplace.fileGate(pattern: searchBox.field.stringValue,
                                          matchCount: group.matches.count,
                                          isSearching: isSearching)
        guard case .ready = gate else {
            statusLabel.stringValue = gate.refusal ?? ""
            return
        }
        guard let root = searchRoot else {
            statusLabel.stringValue = "No directory to replace in"
            return
        }
        let template = replaceBox.field.stringValue
        let prose = SearchReplace.confirmation(files: 1, replacements: group.matches.count,
                                               template: template, scopeLabel: group.relativePath)
        confirm(prose: prose, root: root, paths: [group.relativePath], template: template)
    }

    // Drop a file from the results without touching it on disk — the way VS Code
    // lets you clear the noise out of a result set before replacing what is left.
    // Replace All then acts on what is actually listed, which is the promise the
    // status line was already making.
    func dismissGroup(_ group: SearchFileGroup) {
        guard let index = groups.firstIndex(of: group) else { return }
        groups.remove(at: index)
        groupsByPath[group.relativePath] = nil
        matchCount -= group.matches.count
        let dropped = Set(group.matches.map(ObjectIdentifier.init))
        flatMatches.removeAll { dropped.contains(ObjectIdentifier($0)) }
        outlineView.reloadData()
        updateStatus(suffix: resultsTruncated ? " (first \(RipgrepSearcher.maxMatches))" : "")
    }

    private func confirm(prose: (message: String, detail: String), root: String,
                         paths: [String], template: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = prose.message
        alert.informativeText = prose.detail
        alert.addButton(withTitle: "Replace All")
        alert.addButton(withTitle: "Cancel")
        let query = replaceQuery
        let preserveCase = preserveCaseToggle.state == .on
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performReplace(root: root, paths: paths, query: query,
                                 template: template, preserveCase: preserveCase)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(alert.runModal())
        }
    }

    private func performReplace(root: String, paths: [String], query: FindQuery,
                                template: String, preserveCase: Bool) {
        let outcome = SearchReplace.apply(
            root: root,
            relativePaths: paths,
            query: query,
            template: template,
            preserveCase: preserveCase,
            read: { try String(contentsOf: URL(fileURLWithPath: $0), encoding: .utf8) },
            // The atomic writer ⌘S uses, so a crash mid-pass can't leave a
            // half-written source file behind.
            write: { try FileEditWriter.write($1, toPath: $0) }
        )
        let summary = SearchReplace.summary(outcome)
        if !outcome.filesChanged.isEmpty {
            onFilesChanged?(root, outcome.filesChanged)
        }
        // Re-run so the list reflects the files on disk: the replaced matches are
        // gone, and anything the new text now matches shows up. The status line is
        // written after, because runSearch() overwrites it with its own.
        runSearch()
        statusLabel.stringValue = summary
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
