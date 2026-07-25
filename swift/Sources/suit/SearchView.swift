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
// Layout, top to bottom: the pattern field with the options toggle beside it, the
// replace field with its Replace All button, the regex/case/glob/scope controls
// (collapsed behind that toggle), a status line, and the results grouped by file.
// Clicking a match opens it in the window's viewer pane at that line. Replace All
// confirms first and then rewrites the listed files on disk — see SearchReplace,
// which owns every decision about that pass.
final class SearchView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSTextFieldDelegate {
    // Set by the window controller; receives the file's absolute path and line.
    var onOpenMatch: ((String, Int) -> Void)?
    // Resolves the picked scope to a directory to run rg in, plus a short
    // label for the status line. nil falls back to doing nothing (no project).
    var scopeResolver: ((SearchScope) -> (root: String, label: String)?)?
    // Escape on an already-empty field asks to leave the tab (the sidebar sends
    // it back to Files). The tab has no ✕ of its own: the activity bar is how a
    // tab is left, and a second close affordance would just disagree with it.
    var onDismiss: (() -> Void)?
    // Fired after a Replace All rewrote files, so the window can refresh what it
    // derives from them (git status letters, file badges).
    var onFilesChanged: ((_ root: String, _ relativePaths: [String]) -> Void)?
    // The live pattern as a FindQuery, for the open viewers to highlight their
    // own occurrences of — nil once the field is empty. Fired on every state the
    // results themselves change on (typing settles, Enter, a toggle, a clear), so
    // the wash in the panes can never outlive the list that explains it.
    var onHighlightQueryChange: ((FindQuery?) -> Void)?

    private let searchField = NSSearchField(frame: .zero)
    private let replaceField = NSTextField(frame: .zero)
    private let replaceAllButton = NSButton(title: "Replace All", target: nil, action: nil)
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
    // Whether rg stopped at its match cap. Read by the replace gate: a capped
    // list is a partial view of the matches, and replacing a partial view is a
    // silent under-replace.
    private var resultsTruncated = false
    // The regex/case/scope/glob controls stay hidden behind the toggle next to
    // the search field until asked for; the two input rows are always shown.
    private var optionsExpanded = UserDefaults.standard.bool(forKey: "searchOptionsExpanded")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        searchField.placeholderString = "Search project…"
        searchField.font = .systemFont(ofSize: 12)
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false
        addSubview(searchField)

        replaceField.placeholderString = "Replace…"
        replaceField.font = .systemFont(ofSize: 12)
        replaceField.delegate = self
        replaceField.bezelStyle = .roundedBezel
        addSubview(replaceField)

        replaceAllButton.bezelStyle = .texturedRounded
        replaceAllButton.controlSize = .small
        replaceAllButton.font = .systemFont(ofSize: 11)
        replaceAllButton.toolTip = "Replace every listed match, rewriting those files on disk"
        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAllClicked)
        addSubview(replaceAllButton)

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
        statusLabel.stringValue = "Type to search this project"
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

    // Put the cursor in the pattern field: ⌘⇧F, the file header's magnifier and
    // simply selecting the tab all land here.
    func focusSearchField() {
        window?.makeFirstResponder(searchField)
    }

    // Live theme switch. These tints are set on controls at init, so the
    // controller's recursive needsDisplay sweep — which only repaints
    // draw()-based chrome — can't reach them; SidebarView.reapplyTheme() calls
    // this instead.
    func reapplyTheme() {
        statusLabel.textColor = Theme.textFaint
        styleModeToggles()
        updateOptionsToggleTint()
    }

    // Escape: clear a typed pattern, and — on an already-clear field — hand the
    // sidebar back to the file tree, so ⌘⇧F, Escape, Escape ends where it started.
    private func dismiss() {
        guard searchField.stringValue.isEmpty else {
            debounce?.cancel()
            searcher.cancel()
            searchField.stringValue = ""
            clearResults()
            onHighlightQueryChange?(nil)
            statusLabel.stringValue = "Type to search this project"
            return
        }
        onDismiss?()
    }

    // MARK: - Layout (manual, like the rest of the sidebar)

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContents()
    }

    private func layoutContents() {
        regexToggle.isHidden = !optionsExpanded
        caseToggle.isHidden = !optionsExpanded
        scopePicker.isHidden = !optionsExpanded
        globField.isHidden = !optionsExpanded

        let padding: CGFloat = 10
        let width = max(0, bounds.width - padding * 2)
        let button: CGFloat = 24
        let gap: CGFloat = 4
        var y = bounds.height

        // Pattern row: field on the left, options toggle right-aligned.
        y -= 26
        optionsToggle.frame = NSRect(x: padding + width - button, y: y + 2, width: button, height: 20)
        searchField.frame = NSRect(x: padding, y: y, width: max(0, optionsToggle.frame.minX - gap - padding), height: 24)

        // Replace row: the template field, then the button that applies it. The
        // button holds a fixed width so a narrow sidebar shrinks the field rather
        // than clipping the verb.
        y -= 26
        let replaceButtonWidth: CGFloat = 78
        replaceAllButton.frame = NSRect(x: padding + width - replaceButtonWidth, y: y + 1, width: replaceButtonWidth, height: 21)
        replaceField.frame = NSRect(x: padding, y: y, width: max(0, replaceAllButton.frame.minX - gap - padding), height: 22)

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
        // The replacement template is not part of the search: typing one must
        // neither re-run rg nor clear the matches it is about to be applied to.
        if (notification.object as AnyObject?) === replaceField { return }
        // Emptying the field clears results at once rather than waiting out the
        // debounce.
        if searchField.stringValue.isEmpty {
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

    // Enter searches immediately (also how a glob edit is applied) — or, from the
    // replace field, starts the replace, since that is the only thing Enter there
    // could mean. Escape clears, then leaves the tab.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if control === replaceField {
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
        // The open viewers highlight from the same query the on-disk replace
        // would use (SearchReplace.query), so what a pane washes is exactly what
        // rg listed and what Replace All would rewrite — three readings of one
        // pattern that must not drift apart.
        onHighlightQueryChange?(pattern.isEmpty ? nil : SearchReplace.query(
            pattern: pattern,
            isRegex: regexToggle.state == .on,
            caseSensitive: caseToggle.state == .on
        ))
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
        resultsTruncated = false
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
        resultsTruncated = truncated
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

    // MARK: - Replacing across the project

    @objc private func replaceAllClicked() {
        replaceAll()
    }

    // Confirm, then rewrite every listed file. The gate, the prose and the pass
    // itself all live in SearchReplace; this half only shows what it says and
    // moves the results along afterwards.
    private func replaceAll() {
        let pattern = searchField.stringValue
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
        let template = replaceField.stringValue
        let prose = SearchReplace.confirmation(files: files, replacements: replacements,
                                               template: template, scopeLabel: scopeLabel)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = prose.message
        alert.informativeText = prose.detail
        alert.addButton(withTitle: "Replace All")
        alert.addButton(withTitle: "Cancel")
        // Snapshot what the confirm was shown for: the sheet is async, and a
        // still-typing debounce could otherwise swap the results under it.
        let paths = groups.map(\.relativePath)
        let query = SearchReplace.query(pattern: pattern,
                                        isRegex: regexToggle.state == .on,
                                        caseSensitive: caseToggle.state == .on)
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performReplace(root: root, paths: paths, query: query, template: template)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(alert.runModal())
        }
    }

    private func performReplace(root: String, paths: [String], query: FindQuery, template: String) {
        let outcome = SearchReplace.apply(
            root: root,
            relativePaths: paths,
            query: query,
            template: template,
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
