import Cocoa

// The sidebar's Git tab — the review-workflow surface (the home ROADMAP
// Phase 5 implied) merged with worktree orchestration. Shows the displayed
// project's working-tree state: staged and unstaged files letter-badged like
// the Files tree, under a header naming the current branch + worktree. The
// header's dropdown switches the sidebar between the repo's worktrees, checks
// out local branches, and — inside a task worktree — finishes the task
// (merge or discard). Clicking a changed file opens the diff tab scoped to
// that file; untracked files open in the viewer instead (nothing to diff).
//
// The row views live in GitRowViews.swift; the branch/PR overview in
// GitView+Branches.swift, the worktree/branch switcher in GitView+Worktrees.swift,
// and the File History section in GitView+FileHistory.swift.

final class GitView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    // Open the diff tab scoped to one changed file (repo root, relative path).
    var onOpenDiff: ((String, String) -> Void)?
    // Open an untracked file in the viewer (absolute path — no diff to show).
    var onOpenFile: ((String) -> Void)?
    // Show the whole working tree's diff for the shown repo root.
    var onShowFullDiff: ((String) -> Void)?
    // Point the sidebar at another worktree (absolute path).
    var onSwitchWorktree: ((String) -> Void)?
    // A finished task worktree was just removed; repoint the sidebar at the
    // repo's main checkout.
    var onTaskFinished: ((String) -> Void)?
    // Open a commit's per-file diff (absolute file path, full sha) — File
    // History rows (ROADMAP Phase 17).
    var onOpenCommitDiff: ((String, String) -> Void)?
    // Drop an away-marker for the shown repo (ROADMAP Phase 24).
    var onMarkNow: ((String) -> Void)?
    // Show the aggregate catch-up diff since the last marker.
    var onCatchUp: ((String) -> Void)?

    enum Row {
        case section(String)
        case hint(String)
        case file(path: String, letter: Character)
        case branch(GitBranchInfo)
        case commit(FileCommit)
    }

    private static let headerHeight: CGFloat = 28

    private let branchIcon = NSImageView(frame: .zero)
    let branchButton = NSButton(frame: .zero)
    private let markerButton = NSButton(frame: .zero)
    private let fullDiffButton = NSButton(frame: .zero)
    private let separator = NSBox(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let tableView = NSTableView(frame: .zero)
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")

    var gitRoot: String?
    var monitor: GitStatusMonitor?
    private var rows: [Row] = []

    // Branch/PR overview (Phase 21), loaded off the main thread and cached:
    // branches from local git, PR badges from `gh` (when installed). `loadToken`
    // discards results that land after the shown root has changed.
    var branches: [GitBranchInfo] = []
    var prByBranch: [String: GitPRInfo] = [:]
    var loadToken = 0

    // File History section (ROADMAP Phase 17): the absolute path of the file
    // whose history is shown, its commits, and a generation guard so a stale
    // async result from a superseded file doesn't land.
    var historyPath: String?
    var historyCommits: [FileCommit] = []
    var historyGeneration = 0

    // The shown repo's main-checkout path, resolved once per repo switch —
    // markers are keyed by it (ROADMAP Phase 24). Kept off `reload()`'s hot
    // FSEvents path since it shells out to git.
    private var markerMainRoot: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        branchIcon.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "git branch")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        branchIcon.contentTintColor = Theme.textDim
        branchIcon.imageScaling = .scaleProportionallyDown
        addSubview(branchIcon)

        branchButton.isBordered = false
        branchButton.imagePosition = .imageTrailing
        branchButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 7, weight: .semibold))
        branchButton.contentTintColor = Theme.textDim
        branchButton.alignment = .left
        branchButton.lineBreakMode = .byTruncatingTail
        branchButton.target = self
        branchButton.action = #selector(openSwitcherMenu)
        branchButton.toolTip = "Switch worktree or branch"
        branchButton.setAccessibilityLabel("Switch worktree or branch")
        addSubview(branchButton)

        markerButton.isBordered = false
        markerButton.imagePosition = .imageOnly
        markerButton.target = self
        markerButton.action = #selector(openMarkerMenu)
        markerButton.contentTintColor = Theme.textDim
        addSubview(markerButton)

        fullDiffButton.image = NSImage(systemSymbolName: "plusminus", accessibilityDescription: "Show Full Diff")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        fullDiffButton.isBordered = false
        fullDiffButton.imagePosition = .imageOnly
        fullDiffButton.toolTip = "Show Full Diff (⌃⌘D)"
        fullDiffButton.target = self
        fullDiffButton.action = #selector(showFullDiff)
        fullDiffButton.contentTintColor = Theme.textDim
        addSubview(fullDiffButton)

        separator.boxType = .separator
        addSubview(separator)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("change"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.backgroundColor = .clear
        tableView.style = .sourceList
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        addSubview(scrollView)

        emptyLabel.alignment = .center
        emptyLabel.textColor = Theme.textFaint
        emptyLabel.font = .systemFont(ofSize: 11)
        addSubview(emptyLabel)

        NotificationCenter.default.addObserver(
            self, selector: #selector(statusChanged(_:)),
            name: GitStatusMonitor.didUpdate, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(markerChanged),
            name: MarkerStore.didUpdate, object: nil
        )
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // Points the tab at the project the sidebar shows; a non-repo directory
    // renders the empty state. Same follow/pin semantics as the Files tab —
    // the window controller calls this from every place it reconfigures the
    // file browser.
    func configure(displayRoot: String) {
        let root = FileIndex.gitRoot(of: displayRoot)
        if root != gitRoot {
            gitRoot = root
            monitor = root.map { GitStatusMonitor.shared(forRoot: $0) }
            // Markers are repo-wide (keyed by the main checkout); resolve it
            // once here rather than on every FSEvents-driven reload.
            markerMainRoot = root.flatMap { MarkerCatchUp.mainRoot($0) }
            // Drop the previous repo's branch/PR cache immediately so a stale
            // list never shows while the new one loads.
            branches = []
            prByBranch = [:]
            // The shown file history belongs to the previous repo; drop it.
            historyPath = nil
            historyCommits = []
            historyGeneration += 1
        }
        monitor?.refresh()
        reload()
        loadBranchData()
    }

    @objc private func statusChanged(_ note: Notification) {
        guard let monitor, (note.object as? GitStatusMonitor) === monitor else { return }
        reload()
        loadBranchData()
    }

    func reload() {
        rows = []
        guard let monitor, gitRoot != nil else {
            setBranchTitle("no repository")
            branchButton.isEnabled = false
            branchButton.toolTip = nil
            fullDiffButton.isEnabled = false
            markerButton.isEnabled = false
            refreshMarkerButton()
            emptyLabel.stringValue = "Not a git repository."
            emptyLabel.isHidden = false
            tableView.reloadData()
            return
        }
        branchButton.isEnabled = true
        fullDiffButton.isEnabled = true
        markerButton.isEnabled = true
        refreshMarkerButton()
        emptyLabel.isHidden = true

        let branch = monitor.currentBranch ?? "detached HEAD"
        setBranchTitle("\(branch) — \((monitor.root as NSString).lastPathComponent)")
        branchButton.toolTip = (monitor.root as NSString).abbreviatingWithTildeInPath

        let staged = monitor.stagedByPath.sorted { $0.key < $1.key }
        let unstaged = monitor.unstagedByPath.sorted { $0.key < $1.key }
        if !staged.isEmpty {
            rows.append(.section("Staged — \(staged.count)"))
            rows += staged.map { .file(path: $0.key, letter: $0.value) }
        }
        if !unstaged.isEmpty {
            rows.append(.section("Changes — \(unstaged.count)"))
            rows += unstaged.map { .file(path: $0.key, letter: $0.value) }
        }
        if staged.isEmpty && unstaged.isEmpty {
            rows.append(.hint("Working tree clean"))
        }
        if let historyPath {
            let name = (historyPath as NSString).lastPathComponent
            rows.append(.section("File History — \(name)"))
            rows += historyCommits.map { .commit($0) }
        }
        if !branches.isEmpty {
            rows.append(.section("Branches — \(branches.count)"))
            rows += branches.map { .branch($0) }
        }
        tableView.reloadData()
    }

    private func setBranchTitle(_ title: String) {
        branchButton.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: Theme.textPrimary,
            ]
        )
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let headerY = bounds.height - Self.headerHeight
        let padding: CGFloat = 8
        let buttonSize: CGFloat = 18
        branchIcon.frame = NSRect(x: padding, y: headerY + (Self.headerHeight - 12) / 2, width: 12, height: 12)
        fullDiffButton.frame = NSRect(
            x: bounds.width - padding - buttonSize,
            y: headerY + (Self.headerHeight - buttonSize) / 2,
            width: buttonSize, height: buttonSize
        )
        markerButton.frame = NSRect(
            x: fullDiffButton.frame.minX - 4 - buttonSize,
            y: headerY + (Self.headerHeight - buttonSize) / 2,
            width: buttonSize, height: buttonSize
        )
        let branchX = branchIcon.frame.maxX + 4
        branchButton.frame = NSRect(
            x: branchX, y: headerY + (Self.headerHeight - 18) / 2,
            width: max(0, markerButton.frame.minX - 6 - branchX), height: 18
        )
        separator.frame = NSRect(x: 0, y: headerY, width: bounds.width, height: 1)
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, headerY - 1))
        let labelHeight: CGFloat = 40
        emptyLabel.frame = NSRect(
            x: 12, y: (max(0, headerY) - labelHeight) / 2,
            width: max(0, bounds.width - 24), height: labelHeight
        )
    }

    // MARK: - Row clicks

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count, let root = gitRoot else { return }
        switch rows[row] {
        case let .file(path, letter):
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            if letter == "?" {
                let absolute = root + "/" + trimmed
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: absolute, isDirectory: &isDirectory),
                      !isDirectory.boolValue else { return }
                onOpenFile?(absolute)
            } else {
                onOpenDiff?(root, trimmed)
            }
        case let .branch(info):
            activate(branch: info)
        case let .commit(commit):
            // A File History row opens that commit's per-file diff (Phase 17).
            if let historyPath {
                onOpenCommitDiff?(historyPath, commit.sha)
            }
        default:
            break
        }
    }

    @objc private func showFullDiff() {
        guard let root = gitRoot else { return }
        onShowFullDiff?(root)
    }

    // MARK: - Away marker (ROADMAP Phase 24)

    private var currentMarker: MarkerStore.Marker? {
        markerMainRoot.flatMap { MarkerStore.shared.marker(forRepo: $0) }
    }

    // Flag icon fills once a marker exists; the tooltip carries when it was set.
    private func refreshMarkerButton() {
        let marker = currentMarker
        let symbol = marker == nil ? "flag" : "flag.fill"
        markerButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Away marker")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        if let marker {
            markerButton.toolTip = "Marked \(MarkerCatchUp.shortTime(marker.at)) — what changed since"
        } else {
            markerButton.toolTip = "Mark now — checkpoint for “what changed while I was away”"
        }
    }

    @objc private func openMarkerMenu() {
        guard gitRoot != nil else { return }
        let menu = NSMenu()

        if let marker = currentMarker {
            menu.addItem(Self.headerItem("Marked \(MarkerCatchUp.shortTime(marker.at))"))
            let catchUp = menu.addItem(withTitle: "What Changed Since Mark", action: #selector(catchUpItem), keyEquivalent: "")
            catchUp.target = self
            menu.addItem(.separator())
        }
        let markItem = menu.addItem(
            withTitle: currentMarker == nil ? "Mark Now" : "Re-mark Now",
            action: #selector(markNowItem), keyEquivalent: ""
        )
        markItem.target = self

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: markerButton.frame.minX, y: markerButton.frame.minY - 2),
            in: self
        )
    }

    @objc private func markNowItem() {
        guard let root = gitRoot else { return }
        onMarkNow?(root)
    }

    @objc private func catchUpItem() {
        guard let root = gitRoot else { return }
        onCatchUp?(root)
    }

    @objc private func markerChanged() {
        refreshMarkerButton()
    }

    // MARK: - Context menu

    @objc private func openDiffFromMenu(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, let root = gitRoot else { return }
        onOpenDiff?(root, path)
    }

    @objc private func openFileFromMenu(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, let root = gitRoot else { return }
        onOpenFile?(root + "/" + path)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else { return }
        switch rows[row] {
        case let .file(path, letter):
            buildFileMenu(menu, path: path, letter: letter)
        case let .branch(info):
            buildBranchMenu(menu, branch: info)
        default:
            break
        }
    }

    private func buildFileMenu(_ menu: NSMenu, path: String, letter: Character) {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        if letter != "?" {
            let diffItem = menu.addItem(withTitle: "Open Diff", action: #selector(openDiffFromMenu(_:)), keyEquivalent: "")
            diffItem.target = self
            diffItem.representedObject = trimmed
        }
        // Deleted files have nothing to open in the viewer.
        if letter != "D" {
            let fileItem = menu.addItem(withTitle: "Open File", action: #selector(openFileFromMenu(_:)), keyEquivalent: "")
            fileItem.target = self
            fileItem.representedObject = trimmed
        }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .section(let title):
            let identifier = NSUserInterfaceItemIdentifier("gitSectionRow")
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? GitSectionRowView ?? {
                let created = GitSectionRowView(frame: .zero)
                created.identifier = identifier
                return created
            }()
            view.configure(title: title)
            return view
        case .file(let path, let letter):
            let identifier = NSUserInterfaceItemIdentifier("gitChangeRow")
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? GitChangeRowView ?? {
                let created = GitChangeRowView(frame: .zero)
                created.identifier = identifier
                return created
            }()
            view.configure(path: path, letter: letter)
            return view
        case .hint(let text):
            let identifier = NSUserInterfaceItemIdentifier("gitHintRow")
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? GitHintRowView ?? {
                let created = GitHintRowView(frame: .zero)
                created.identifier = identifier
                return created
            }()
            view.configure(text: text)
            return view
        case .branch(let info):
            let identifier = NSUserInterfaceItemIdentifier("gitBranchRow")
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? GitBranchRowView ?? {
                let created = GitBranchRowView(frame: .zero)
                created.identifier = identifier
                return created
            }()
            view.configure(branch: info, pr: prByBranch[info.name])
            return view
        case .commit(let commit):
            let identifier = NSUserInterfaceItemIdentifier("gitCommitRow")
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? GitCommitRowView ?? {
                let created = GitCommitRowView(frame: .zero)
                created.identifier = identifier
                return created
            }()
            view.configure(commit: commit)
            return view
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .section:
            return 20
        case .commit:
            return 34
        default:
            return 24
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[row] {
        case .file, .branch, .commit:
            return true
        default:
            return false
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ThemedTableRowView()
    }
}
