import Cocoa

// The sidebar's Git tab — the review-workflow surface (the home ROADMAP
// Phase 5 implied) merged with worktree orchestration. Shows the displayed
// project's working-tree state: staged and unstaged files letter-badged like
// the Files tree, under a header naming the current branch + worktree. The
// header's dropdown switches the sidebar between the repo's worktrees, checks
// out local branches, and — inside a task worktree — finishes the task
// (merge or discard). Clicking a changed file opens the diff tab scoped to
// that file; untracked files open in the viewer instead (nothing to diff).

// One changed-file row: status letter (colored like the Files tree's badges),
// then one label carrying "name  directory" as a single attributed string —
// name in primary, directory in faint — so the name never gets squeezed by a
// separately-framed sibling; tail truncation eats the directory first.
private final class GitChangeRowView: NSTableCellView {
    private let letterLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        letterLabel.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        letterLabel.alignment = .center
        addSubview(letterLabel)

        pathLabel.lineBreakMode = .byTruncatingTail
        addSubview(pathLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(path: String, letter: Character) {
        letterLabel.stringValue = String(letter)
        letterLabel.textColor = GitStatusMonitor.badgeColor(for: letter)
        // Untracked directories arrive as "dir/" from porcelain.
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let name = (trimmed as NSString).lastPathComponent
        let directory = (trimmed as NSString).deletingLastPathComponent
        let text = NSMutableAttributedString(
            string: name,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11.5),
                .foregroundColor: Theme.textPrimary,
            ]
        )
        if !directory.isEmpty {
            text.append(NSAttributedString(
                string: "  " + directory,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: Theme.textFaint,
                ]
            ))
        }
        pathLabel.attributedStringValue = text
        toolTip = path
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        letterLabel.frame = NSRect(x: 6, y: (bounds.height - 13) / 2, width: 14, height: 13)
        pathLabel.frame = NSRect(x: 24, y: (bounds.height - 16) / 2, width: max(0, bounds.width - 32), height: 16)
    }
}

// A "STAGED — 2" / "CHANGES — 5" section divider row.
private final class GitSectionRowView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 9.5, weight: .semibold)
        label.textColor = Theme.textFaint
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String) {
        label.stringValue = title.uppercased()
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 8, y: 2, width: max(0, bounds.width - 16), height: 13)
    }
}

// One faint inline hint row ("Working tree clean") — the reassurance that used
// to be the big centered empty label, kept as a table row now that branches
// live below the changes.
private final class GitHintRowView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 11)
        label.textColor = Theme.textFaint
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String) {
        label.stringValue = text
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 24, y: (bounds.height - 16) / 2, width: max(0, bounds.width - 32), height: 16)
    }
}

// One File History commit row (ROADMAP Phase 17): short sha (age-tinted, mono)
// beside the subject on top, author + relative date below in faint text.
private final class GitCommitRowView: NSTableCellView {
    private let shaLabel = NSTextField(labelWithString: "")
    private let subjectLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        shaLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        addSubview(shaLabel)
        subjectLabel.font = .systemFont(ofSize: 11.5)
        subjectLabel.textColor = Theme.textPrimary
        subjectLabel.lineBreakMode = .byTruncatingTail
        addSubview(subjectLabel)
        metaLabel.font = .systemFont(ofSize: 10)
        metaLabel.textColor = Theme.textFaint
        metaLabel.lineBreakMode = .byTruncatingTail
        addSubview(metaLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(commit: FileCommit) {
        shaLabel.stringValue = commit.shortSha
        shaLabel.textColor = GitAgeTint.color(forTime: commit.time, now: Date().timeIntervalSince1970)
        subjectLabel.stringValue = commit.subject
        metaLabel.stringValue = "\(commit.author) · \(Self.relativeAge(commit.time))"
        toolTip = "\(commit.shortSha)  \(commit.subject)\n\(commit.author)"
        needsLayout = true
    }

    // Compact "3d" / "5mo" / "2y" age used in the meta line.
    static func relativeAge(_ time: TimeInterval) -> String {
        guard time > 0 else { return "" }
        let seconds = max(0, Date().timeIntervalSince1970 - time)
        let days = Int(seconds / 86_400)
        if days <= 0 { return "today" }
        if days < 31 { return "\(days)d" }
        if days < 365 { return "\(days / 30)mo" }
        return "\(days / 365)y"
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let shaWidth: CGFloat = 62
        shaLabel.frame = NSRect(x: 8, y: bounds.height - 20, width: shaWidth, height: 14)
        subjectLabel.frame = NSRect(x: 8 + shaWidth + 4, y: bounds.height - 20, width: max(0, bounds.width - shaWidth - 20), height: 15)
        metaLabel.frame = NSRect(x: 8, y: 3, width: max(0, bounds.width - 16), height: 13)
    }
}

// One branch row (Phase 21): branch-icon + name on the left (current branch in
// accent/semibold), and a right-aligned cluster of ahead/behind counts, an
// optional PR badge, and a dirty dot. A worktree glyph marks branches checked
// out in a linked worktree.
private final class GitBranchRowView: NSTableCellView {
    private let icon = NSImageView(frame: .zero)
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let dirtyDot = NSView(frame: .zero)
    private let worktreeIcon = NSImageView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)

        nameLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(nameLabel)

        worktreeIcon.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "worktree")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .regular))
        worktreeIcon.contentTintColor = Theme.textFaint
        worktreeIcon.imageScaling = .scaleProportionallyDown
        addSubview(worktreeIcon)

        detailLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        detailLabel.alignment = .right
        addSubview(detailLabel)

        dirtyDot.wantsLayer = true
        dirtyDot.layer?.backgroundColor = Theme.sessionBusy.cgColor
        dirtyDot.layer?.cornerRadius = 3
        addSubview(dirtyDot)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(branch: GitBranchInfo, pr: GitPRInfo?) {
        let symbol = branch.isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch"
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        icon.contentTintColor = branch.isCurrent ? Theme.accent : Theme.textDim

        nameLabel.attributedStringValue = NSAttributedString(
            string: branch.name,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: branch.isCurrent ? .semibold : .regular),
                .foregroundColor: branch.isCurrent ? Theme.accent : Theme.textPrimary,
            ]
        )
        worktreeIcon.isHidden = branch.worktreePath == nil || branch.isCurrent

        let detail = NSMutableAttributedString()
        if branch.ahead > 0 {
            detail.append(NSAttributedString(string: "↑\(branch.ahead) ", attributes: [
                .foregroundColor: Theme.sessionDone,
                .font: detailLabel.font as Any,
            ]))
        }
        if branch.behind > 0 {
            detail.append(NSAttributedString(string: "↓\(branch.behind) ", attributes: [
                .foregroundColor: Theme.sessionBusy,
                .font: detailLabel.font as Any,
            ]))
        }
        if let pr {
            let glyph: String
            switch pr.checks {
            case .passing: glyph = " ✓"
            case .failing: glyph = " ✕"
            case .pending: glyph = " •"
            case nil: glyph = ""
            }
            detail.append(NSAttributedString(string: "#\(pr.number)\(glyph)", attributes: [
                .foregroundColor: Self.prColor(pr),
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            ]))
        }
        detailLabel.attributedStringValue = detail

        dirtyDot.isHidden = !branch.isDirty
        var tip = branch.name
        if let upstream = branch.upstream { tip += " → \(upstream)" }
        if branch.ahead > 0 || branch.behind > 0 { tip += " (ahead \(branch.ahead), behind \(branch.behind))" }
        if let pr { tip += " · PR #\(pr.number) \(pr.state.rawValue.lowercased())" }
        toolTip = tip
        needsLayout = true
    }

    private static func prColor(_ pr: GitPRInfo) -> NSColor {
        switch pr.state {
        case .open: return Theme.accent
        case .merged: return Theme.sessionDone
        case .closed: return Theme.textDim
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 6, y: (bounds.height - 13) / 2, width: 14, height: 13)
        var rightEdge = bounds.width - 8
        if !dirtyDot.isHidden {
            dirtyDot.frame = NSRect(x: rightEdge - 6, y: (bounds.height - 6) / 2, width: 6, height: 6)
            rightEdge -= 12
        }
        detailLabel.sizeToFit()
        let detailWidth = min(detailLabel.frame.width + 2, max(0, bounds.width - 120))
        detailLabel.frame = NSRect(x: rightEdge - detailWidth, y: (bounds.height - 15) / 2, width: detailWidth, height: 15)
        rightEdge -= detailWidth + 6
        var nameX: CGFloat = 24
        if !worktreeIcon.isHidden {
            worktreeIcon.frame = NSRect(x: nameX, y: (bounds.height - 11) / 2, width: 11, height: 11)
            nameX += 15
        }
        nameLabel.frame = NSRect(x: nameX, y: (bounds.height - 16) / 2, width: max(0, rightEdge - nameX), height: 16)
    }
}

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

    private enum Row {
        case section(String)
        case hint(String)
        case file(path: String, letter: Character)
        case branch(GitBranchInfo)
        case commit(FileCommit)
    }

    private static let headerHeight: CGFloat = 28

    private let branchIcon = NSImageView(frame: .zero)
    private let branchButton = NSButton(frame: .zero)
    private let fullDiffButton = NSButton(frame: .zero)
    private let separator = NSBox(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let tableView = NSTableView(frame: .zero)
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")

    private var gitRoot: String?
    private var monitor: GitStatusMonitor?
    private var rows: [Row] = []

    // Branch/PR overview (Phase 21), loaded off the main thread and cached:
    // branches from local git, PR badges from `gh` (when installed). `loadToken`
    // discards results that land after the shown root has changed.
    private var branches: [GitBranchInfo] = []
    private var prByBranch: [String: GitPRInfo] = [:]
    private var loadToken = 0

    // File History section (ROADMAP Phase 17): the absolute path of the file
    // whose history is shown, its commits, and a generation guard so a stale
    // async result from a superseded file doesn't land.
    private var historyPath: String?
    private var historyCommits: [FileCommit] = []
    private var historyGeneration = 0

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

    private func reload() {
        rows = []
        guard let monitor, gitRoot != nil else {
            setBranchTitle("no repository")
            branchButton.isEnabled = false
            branchButton.toolTip = nil
            fullDiffButton.isEnabled = false
            emptyLabel.stringValue = "Not a git repository."
            emptyLabel.isHidden = false
            tableView.reloadData()
            return
        }
        branchButton.isEnabled = true
        fullDiffButton.isEnabled = true
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

    // Show File History for a file (ROADMAP Phase 17): reveal its commits under
    // a "File History" section. Loaded async off the main thread; a later call
    // for another file supersedes an in-flight one via the generation guard.
    func showFileHistory(absolutePath: String) {
        historyPath = absolutePath
        historyCommits = []
        historyGeneration += 1
        let generation = historyGeneration
        reload()
        GitFileHistory.compute(filePath: absolutePath) { [weak self] _, commits in
            guard let self, self.historyGeneration == generation else { return }
            self.historyCommits = commits
            self.reload()
        }
    }

    // MARK: - Branch / PR overview (Phase 21)

    // Loads local branches (ahead/behind, worktree, dirty) off the main thread,
    // then — if `gh` is installed — layers PR badges on in a second pass so the
    // branch list never waits on the network.
    private func loadBranchData() {
        guard let root = gitRoot else { return }
        let current = monitor?.currentBranch
        loadToken += 1
        let token = loadToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let list = GitBranchList.compute(root: root, currentBranch: current)
            DispatchQueue.main.async {
                guard let self, token == self.loadToken, root == self.gitRoot else { return }
                self.branches = list
                self.reload()
                self.loadPullRequests(root: root, token: token)
            }
        }
    }

    private func loadPullRequests(root: String, token: Int) {
        guard GitHubCLI.isAvailable else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let prs = GitHubCLI.pullRequests(root: root)
            guard !prs.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, token == self.loadToken, root == self.gitRoot else { return }
                self.prByBranch = prs
                self.reload()
            }
        }
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
        let branchX = branchIcon.frame.maxX + 4
        branchButton.frame = NSRect(
            x: branchX, y: headerY + (Self.headerHeight - 18) / 2,
            width: max(0, fullDiffButton.frame.minX - 6 - branchX), height: 18
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

    // Clicking a branch: switch to its worktree when it lives in one (git won't
    // check out a branch already claimed by another worktree), else check it
    // out in place. The current branch is a no-op.
    private func activate(branch: GitBranchInfo) {
        guard !branch.isCurrent else { return }
        if let worktree = branch.worktreePath {
            onSwitchWorktree?(worktree)
        } else {
            checkout(branch: branch.name)
        }
    }

    @objc private func showFullDiff() {
        guard let root = gitRoot else { return }
        onShowFullDiff?(root)
    }

    // MARK: - Worktree / branch switcher

    @objc private func openSwitcherMenu() {
        guard let root = gitRoot else { return }
        let menu = NSMenu()

        menu.addItem(Self.headerItem("Worktrees"))
        for worktree in Self.listWorktrees(root: root) {
            let name = (worktree.path as NSString).lastPathComponent
            let item = menu.addItem(
                withTitle: "\(name) — \(worktree.branch ?? "detached")",
                action: #selector(switchWorktreeItem(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = worktree.path
            item.state = worktree.path == root ? .on : .off
            item.toolTip = worktree.path
            item.indentationLevel = 1
        }

        menu.addItem(.separator())
        menu.addItem(Self.headerItem("Branches"))
        let current = monitor?.currentBranch
        for branch in Self.listBranches(root: root) {
            let item = menu.addItem(withTitle: branch, action: #selector(checkoutBranchItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = branch
            item.state = branch == current ? .on : .off
            item.indentationLevel = 1
        }

        if WorktreeTasks.isTaskWorktree(root) {
            menu.addItem(.separator())
            let mergeItem = menu.addItem(withTitle: "Finish Task: Merge & Remove", action: #selector(finishTaskMerge), keyEquivalent: "")
            mergeItem.target = self
            let discardItem = menu.addItem(withTitle: "Finish Task: Discard & Remove", action: #selector(finishTaskDiscard), keyEquivalent: "")
            discardItem.target = self
        }

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: branchButton.frame.minX, y: branchButton.frame.minY - 2),
            in: self
        )
    }

    private static func headerItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func switchWorktreeItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, path != gitRoot else { return }
        onSwitchWorktree?(path)
    }

    @objc private func checkoutBranchItem(_ sender: NSMenuItem) {
        guard let branch = sender.representedObject as? String, branch != monitor?.currentBranch else { return }
        checkout(branch: branch)
    }

    private func checkout(branch: String) {
        guard let root = gitRoot else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = WorktreeTasks.runGit(root, ["checkout", branch])
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure(let error) = result {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Checkout Failed"
                    alert.informativeText = error.message
                    alert.runModal()
                }
                self.monitor?.refresh()
            }
        }
    }

    @objc private func finishTaskMerge() {
        confirmFinishTask(merge: true)
    }

    @objc private func finishTaskDiscard() {
        confirmFinishTask(merge: false)
    }

    // The dropdown twin of the pane header's "Finish Claude Task…": merge (or
    // drop) the task branch, remove the worktree, and hand the sidebar back to
    // the main checkout.
    private func confirmFinishTask(merge: Bool) {
        guard let root = gitRoot else { return }
        let branch = WorktreeTasks.currentBranch(root) ?? "the task branch"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = merge ? "Merge & Remove Task Worktree?" : "Discard & Remove Task Worktree?"
        alert.informativeText = merge
            ? "Merges \(branch) into the main checkout's current branch, then removes the worktree and branch."
            : "Removes the worktree and deletes \(branch) without merging. Uncommitted work is lost."
        let confirm = alert.addButton(withTitle: merge ? "Merge & Remove" : "Discard & Remove")
        if !merge {
            confirm.hasDestructiveAction = true
        }
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Resolved before finish() removes the worktree out from under us.
        let mainRoot = WorktreeTasks.mainRoot(ofWorktree: root)
        if let error = WorktreeTasks.finish(worktreePath: root, merge: merge) {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = "Finish Claude Task"
            failure.informativeText = error
            failure.runModal()
            return
        }
        if let mainRoot {
            onTaskFinished?(mainRoot)
        }
    }

    // `git worktree list --porcelain`: blocks of "worktree <path>" followed by
    // "branch refs/heads/<name>" or "detached".
    private static func listWorktrees(root: String) -> [(path: String, branch: String?)] {
        guard let output = runProcess("/usr/bin/git", ["-C", root, "worktree", "list", "--porcelain"]) else {
            return []
        }
        var result: [(path: String, branch: String?)] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("worktree ") {
                result.append((path: String(line.dropFirst("worktree ".count)), branch: nil))
            } else if line.hasPrefix("branch refs/heads/"), !result.isEmpty {
                result[result.count - 1].branch = String(line.dropFirst("branch refs/heads/".count))
            }
        }
        return result
    }

    private static func listBranches(root: String) -> [String] {
        guard let output = runProcess("/usr/bin/git", ["-C", root, "for-each-ref", "--format=%(refname:short)", "refs/heads"]) else {
            return []
        }
        return output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
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

    // Per-branch gh actions (Phase 21). gh entries only appear when gh is
    // installed; without it, a disabled hint says so and Checkout still works.
    private func buildBranchMenu(_ menu: NSMenu, branch: GitBranchInfo) {
        if !branch.isCurrent {
            let title = branch.worktreePath != nil ? "Switch to Worktree" : "Checkout"
            let item = menu.addItem(withTitle: title, action: #selector(activateBranchItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = branch.name
        }
        menu.addItem(.separator())
        if GitHubCLI.isAvailable {
            let createItem = menu.addItem(withTitle: "Create PR…", action: #selector(createPRItem(_:)), keyEquivalent: "")
            createItem.target = self
            createItem.representedObject = branch.name
            let openItem = menu.addItem(withTitle: "Open on GitHub", action: #selector(openOnGitHubItem(_:)), keyEquivalent: "")
            openItem.target = self
            openItem.representedObject = branch.name
        } else {
            menu.addItem(Self.headerItem("Install the gh CLI for PR actions"))
        }
    }

    @objc private func activateBranchItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let info = branches.first(where: { $0.name == name }) else { return }
        activate(branch: info)
    }

    @objc private func createPRItem(_ sender: NSMenuItem) {
        guard let branch = sender.representedObject as? String, let root = gitRoot else { return }
        // Title prefilled from the branch's last path component, dashes → spaces.
        let leaf = branch.split(separator: "/").last.map(String.init) ?? branch
        let suggested = leaf.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        OverlayPromptController.shared.ask(
            caption: "Create PR — title", text: suggested, placeholder: "Pull request title",
            over: window
        ) { [weak self] title in
            guard let self, !title.isEmpty else { return }
            self.runCreatePR(root: root, branch: branch, title: title)
        }
    }

    private func runCreatePR(root: String, branch: String, title: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let body = GitHubCLI.commitBody(root: root, branch: branch)
            let result = GitHubCLI.createPR(root: root, branch: branch, title: title, body: body)
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let url):
                    self.monitor?.refresh()
                    self.loadBranchData()
                    let alert = NSAlert()
                    alert.messageText = "Pull Request Created"
                    alert.informativeText = url.isEmpty ? "The PR was created." : url
                    if !url.isEmpty, let prURL = URL(string: url) {
                        alert.addButton(withTitle: "Open in Browser")
                        alert.addButton(withTitle: "Done")
                        if alert.runModal() == .alertFirstButtonReturn {
                            NSWorkspace.shared.open(prURL)
                        }
                    } else {
                        alert.runModal()
                    }
                case .failure(let error):
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Create PR Failed"
                    alert.informativeText = error.message
                    alert.runModal()
                }
            }
        }
    }

    @objc private func openOnGitHubItem(_ sender: NSMenuItem) {
        guard let branch = sender.representedObject as? String, let root = gitRoot else { return }
        GitHubCLI.openWeb(root: root, branch: branch, hasPR: prByBranch[branch] != nil)
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
