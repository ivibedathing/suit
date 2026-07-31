import Cocoa

// The sidebar's Source Control tab — the full local git loop (see, stage,
// commit, sync) merged with the review workflow and worktree orchestration.
// Shows the displayed project's working-tree state: staged and unstaged files
// letter-badged like the Files tree, under a header naming the current branch +
// worktree. The header's dropdown switches the sidebar between the repo's
// worktrees, checks out local branches, and — inside a task worktree — finishes
// the task (merge or discard). Clicking a changed file opens the diff tab
// scoped to that file; untracked files open in the viewer instead (nothing to
// diff).
//
// Three bands, top to bottom:
//
//   * Branch row — worktree/branch switcher, and the one-click marker / full
//     diff / commit graph buttons this tab has always had.
//   * Sync row — the upstream badge ("↑2 ↓1", click to diff against the remote)
//     and the ⋯ actions menu (fetch, pull, push, publish, stash, branches).
//     Both are the Files header's, deliberately: the two surfaces answer the
//     same questions and should not drift apart.
//   * Commit box — message field and commit button, then the file list.
//
// Nothing here decides what a git action *is*: every command comes from the
// UI-free GitBranchOps, and the running/confirming/alerting is the window
// controller's `runBranchAction` (see TerminalWindowController+GitActions), so
// staging from this tab and pulling from the Files header share one runner.
//
// The row views live in GitRowViews.swift; the commit box and staging in
// GitView+Commit.swift, the branch/PR overview in GitView+Branches.swift, the
// worktree/branch switcher in GitView+Worktrees.swift, and the File History
// section in GitView+FileHistory.swift.

final class GitView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    // Open the diff tab scoped to one changed file (repo root, relative path).
    var onOpenDiff: ((String, String) -> Void)?
    // Open an untracked file in the viewer (absolute path — no diff to show).
    var onOpenFile: ((String) -> Void)?
    // Show the whole working tree's diff for the shown repo root.
    var onShowFullDiff: ((String) -> Void)?
    // Open the commit-graph pane for the shown repo.
    var onShowCommitGraph: ((String) -> Void)?
    // Point the sidebar at another worktree (absolute path).
    var onSwitchWorktree: ((String) -> Void)?
    // A finished task worktree was just removed; repoint the sidebar at the
    // repo's main checkout.
    var onTaskFinished: ((String) -> Void)?
    // Open a commit's per-file diff (absolute file path, full sha) — File
    // History rows.
    var onOpenCommitDiff: ((String, String) -> Void)?
    // Drop an away-marker for the shown repo.
    var onMarkNow: ((String) -> Void)?
    // Show the aggregate catch-up diff since the last marker.
    var onCatchUp: ((String) -> Void)?
    // Route a feedback event into its originating Claude session.
    var onRouteFeedback: ((FeedbackEvent) -> Void)?
    // Kick a dedicated review pass in the event's worktree (optional).
    var onStartReviewPass: ((FeedbackEvent) -> Void)?
    // Open an inbox PR's diff for review.
    var onOpenPR: ((PRReviewItem) -> Void)?
    // Run one composed git action against the shown repo, through the window
    // controller's runner (confirmation, off-thread git, failure alert, index
    // rescan). The completion reports whether every command exited zero — the
    // commit box clears its message only on a real commit.
    var onRunAction: ((_ root: String, _ action: GitBranchOps.Action, _ completion: ((Bool) -> Void)?) -> Void)?
    // Prompt for a name, then create and check out the branch.
    var onNewBranch: ((String) -> Void)?
    // Open the local↔upstream diff for the checked-out branch.
    var onShowUpstreamDiff: ((_ root: String, _ branch: String) -> Void)?
    // How many files are changed right now, for the activity bar's badge.
    var onChangeCountChanged: ((Int) -> Void)?

    enum Row {
        // A section divider, with the bulk staging action its header offers
        // (nil for the sections that aren't about the index).
        case section(String, SectionAction?)
        case hint(String)
        case file(path: String, letter: Character, staged: Bool)
        case branch(GitBranchInfo)
        case commit(FileCommit)
        case feedback(FeedbackEvent)
        case reviewPR(PRReviewItem)
    }

    enum SectionAction {
        case stageAll
        case unstageAll
    }

    // "SOURCE CONTROL" above the branch row — the tab's own title, on the band
    // every sidebar tab opens with (SidebarTitle). The branch row already carries
    // four affordances at sidebar width, so the title takes a row of its own
    // rather than squeezing in beside them.
    private static let titleHeight = SidebarTitle.height
    private static let headerHeight: CGFloat = 28
    private static let syncRowHeight: CGFloat = 22
    // What the file list keeps no matter how far the commit box has been dragged
    // — a couple of rows plus its section header, enough to still be a list.
    private static let minListHeight: CGFloat = 90

    private let titleLabel = SidebarTitle.label("SOURCE CONTROL")
    private let branchIcon = NSImageView(frame: .zero)
    let branchButton = NSButton(frame: .zero)
    private let markerButton = NSButton(frame: .zero)
    private let fullDiffButton = NSButton(frame: .zero)
    private let graphButton = NSButton(frame: .zero)
    let syncButton = NSButton(frame: .zero)
    let actionsButton = NSButton(frame: .zero)
    private let separator = NSBox(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let tableView = NSTableView(frame: .zero)
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")

    // The commit box (built and driven by GitView+Commit.swift): a message text
    // view on a rounded ground, and the commit button with its options menu.
    let commitBox = NSView(frame: .zero)
    let commitTextView = CommitMessageTextView(frame: .zero)
    let commitScroll = NSScrollView(frame: .zero)
    let commitButton = NSButton(frame: .zero)
    let commitOptionsButton = NSButton(frame: .zero)
    let commitResizeGrip = CommitResizeGrip(frame: .zero)
    // How tall the message field wants to be. The user's, dragged on the grip
    // under the field and remembered across launches — clamped again at layout
    // time, so a height dragged in a tall window can't swallow the file list in
    // a short one.
    var commitMessageHeight: CGFloat = {
        let saved = CGFloat(UserDefaults.standard.double(forKey: GitView.commitMessageHeightKey))
        guard saved > 0 else { return GitView.minCommitMessageHeight }
        return min(GitView.maxCommitMessageHeight, max(GitView.minCommitMessageHeight, saved))
    }()
    var commitDragStartHeight: CGFloat = 0
    // Amend is a mode, not a one-shot menu item: it changes what the button
    // says and does until it is turned off or a commit lands.
    var amendMode = false

    // The repo state the sync badge and the ⋯ menu read, refreshed from the
    // monitor on every reload() so the menu can never offer an action the repo
    // has nothing to do (push with no upstream, pop with an empty stash).
    var sync: GitBranchOps.SyncState = .untracked
    var stashCount = 0
    var hasLocalChanges = false
    // Repo-relative paths in each column, in the order the rows show them —
    // what "Stage All" and the per-file actions operate on.
    var stagedPaths: [String] = []
    var unstagedPaths: [String] = []
    // Untracked ("?") paths, the subset of unstagedPaths that a discard deletes
    // rather than restores.
    var untrackedPaths: Set<String> = []

    var gitRoot: String?
    var monitor: GitStatusMonitor?
    private var rows: [Row] = []

    // Branch/PR overview, loaded off the main thread and cached:
    // branches from local git, PR badges from `gh` (when installed). `loadToken`
    // discards results that land after the shown root has changed.
    var branches: [GitBranchInfo] = []
    var prByBranch: [String: GitPRInfo] = [:]
    var loadToken = 0

    // File History section: the absolute path of the file
    // whose history is shown, its commits, and a generation guard so a stale
    // async result from a superseded file doesn't land.
    var historyPath: String?
    var historyCommits: [FileCommit] = []
    var historyGeneration = 0

    // The shown repo's main-checkout path, resolved once per repo switch —
    // markers are keyed by it. Kept off `reload()`'s hot
    // FSEvents path since it shells out to git.
    private var markerMainRoot: String?
    // Feedback inbox: CI failures / PR review comments / merge
    // conflicts across the repo's worktrees, gathered off the main thread and
    // token-guarded against a superseded root, same pattern as the branch load.
    var feedbackEvents: [FeedbackEvent] = []
    var feedbackToken = 0
    // PR review inbox: open PRs that involve me (authored /
    // assigned / review-requested), from `gh`, loaded off the main thread and
    // token-guarded against a superseded root like the branch/feedback passes.
    var reviewPRs: [PRReviewItem] = []
    var reviewInboxToken = 0

    // MARK: - Refresh policy
    //
    // What this tab shows splits in two, and the halves want opposite rules:
    //
    //   * The working-tree state comes off the status monitor and is nearly
    //     free. It also feeds the activity bar's change badge, so it has to
    //     stay correct while the tab is hidden — it follows every didUpdate.
    //   * The branch list, the feedback gather and the two `gh pr list` passes
    //     shell out (the last two over the network) and are drawn *only* here.
    //     Those used to be driven straight off filesystem events, which meant a
    //     build or a busy agent kept three gh passes permanently in flight —
    //     the app's single largest CPU cost.
    //
    // So: the cheap half follows the monitor; the expensive half runs only when
    // something actually happened that could have changed it — the shown repo
    // changed, the branch moved, the tab was revealed, or the user asked. There
    // is deliberately no interval and no polling: with several sessions working
    // different worktrees at once, a timer means every window re-listing PRs
    // forever over repos nobody is looking at.
    //
    // `remoteLoadedRoot` is the root the cached PR/inbox data belongs to, and
    // `remoteLoadedBranch` the branch it was checked out on. Setting the root
    // to nil is how a caller says "this is stale now".
    var remoteLoadedRoot: String?
    var remoteLoadedBranch: String?

    // Whether the tab is actually on screen. The sidebar shows one tab at a
    // time by toggling `isHidden` (SidebarView.applyTabVisibility), so this is
    // the honest answer for both a hidden tab and a hidden sidebar.
    var isShowing: Bool { window != nil && !isHiddenOrHasHiddenAncestor }

    // One pass fans out into four async loads that each used to call reload()
    // as they landed — four full row rebuilds where one would do. Coalescing
    // onto the next runloop turn collapses them, which is most of what the
    // display-cycle view churn was.
    private var reloadScheduled = false
    // Set when a reload built rows while hidden: there is no point rebuilding
    // NSTableView's row views for a tab nobody can see, so the rows are kept
    // and the table catches up on reveal.
    private var needsTableReload = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        addSubview(titleLabel)

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

        graphButton.image = NSImage(systemSymbolName: "point.3.filled.connected.trianglepath.dotted", accessibilityDescription: "Show Commit Graph")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        graphButton.isBordered = false
        graphButton.imagePosition = .imageOnly
        graphButton.toolTip = "Show Commit Graph"
        graphButton.target = self
        graphButton.action = #selector(showCommitGraph)
        graphButton.contentTintColor = Theme.textDim
        addSubview(graphButton)

        // Sync row: the upstream badge is only a button when clicking it would
        // show something (see updateSyncButton), and the ⋯ menu is the same
        // action set the Files header offers.
        syncButton.isBordered = false
        syncButton.imagePosition = .noImage
        syncButton.alignment = .left
        syncButton.target = self
        syncButton.action = #selector(showUpstreamDiff)
        addSubview(syncButton)

        actionsButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Git actions")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        actionsButton.isBordered = false
        actionsButton.imagePosition = .imageOnly
        actionsButton.contentTintColor = Theme.textDim
        actionsButton.target = self
        actionsButton.action = #selector(openActionsMenu)
        actionsButton.toolTip = "Git actions — fetch, pull, push, stash, branches"
        actionsButton.setAccessibilityLabel("Git actions")
        addSubview(actionsButton)

        setupCommitBox()

        separator.boxType = .separator
        addSubview(separator)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("change"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.backgroundColor = .clear
        // .inset, matching the Files tree — not .sourceList, which wraps the
        // list in AppKit's own sidebar material. That material follows the
        // window's NSAppearance rather than the palette, so under a light theme
        // (the appearance stays dark) the list kept a dark slab behind
        // palette-coloured text. Only visible now that this is a tab you sit in.
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        let menu = NSMenu()
        menu.delegate = self
        // Manual enabling: the row menus disable items to *explain* a refusal
        // (a branch a worktree holds can't be deleted), and AppKit's automatic
        // pass would re-enable anything whose selector the view implements.
        // Every item here is enabled unless it says otherwise, headerItem
        // included — it disables itself.
        menu.autoenablesItems = false
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
            // The feedback inbox is repo-scoped too.
            feedbackEvents = []
            // As is the PR review inbox.
            reviewPRs = []
        }
        monitor?.refresh()
        reload()
        // A new repo invalidates the cached PR/inbox data outright.
        remoteLoadedRoot = nil
        loadBranchData()
    }

    @objc private func statusChanged(_ note: Notification) {
        guard let monitor, (note.object as? GitStatusMonitor) === monitor else { return }
        // A branch move is the one working-tree change that can invalidate the
        // PR badges and the review inbox — a different branch has different
        // PRs. Editing files cannot, so it does not re-list anything.
        if monitor.currentBranch != remoteLoadedBranch {
            remoteLoadedRoot = nil
        }
        setNeedsReload()
        loadBranchData()
    }

    // Rebuilds the rows once on the next runloop turn, however many callers
    // asked. Every async load completion goes through here.
    func setNeedsReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            self.reload()
        }
    }

    // The sidebar calls this when Source Control becomes the shown tab: catch
    // the table up on rows built while hidden, then refresh the data that only
    // this tab draws.
    func sidebarTabDidBecomeVisible() {
        if needsTableReload {
            needsTableReload = false
            tableView.reloadData()
        }
        loadBranchData()
    }

    // Whether the network-backed passes may run right now: only when the data
    // on hand doesn't belong to the shown repo, or a caller says it's stale.
    // No clock is consulted — nothing here refreshes merely because time
    // passed.
    func mayLoadRemote(force: Bool) -> Bool {
        guard GitHubCLI.isAvailable, isShowing else { return false }
        return force || remoteLoadedRoot != gitRoot
    }

    // Records which repo + branch the PR/inbox data now describes, so the next
    // pass can tell "already have this" from "this is about somewhere else".
    func markRemoteLoaded() {
        remoteLoadedRoot = gitRoot
        remoteLoadedBranch = monitor?.currentBranch
    }

    func reload() {
        rows = []
        guard let monitor, gitRoot != nil else {
            setBranchTitle("no repository")
            branchButton.isEnabled = false
            branchButton.toolTip = nil
            fullDiffButton.isEnabled = false
            markerButton.isEnabled = false
            graphButton.isEnabled = false
            actionsButton.isEnabled = false
            syncButton.isEnabled = false
            syncButton.attributedTitle = NSAttributedString(string: "")
            stagedPaths = []
            unstagedPaths = []
            untrackedPaths = []
            hasLocalChanges = false
            // The rail badge counts changes in the shown repo; outside one
            // there are none to report.
            onChangeCountChanged?(0)
            refreshMarkerButton()
            refreshCommitBox()
            emptyLabel.stringValue = "Not a git repository."
            emptyLabel.isHidden = false
            applyRows()
            return
        }
        branchButton.isEnabled = true
        fullDiffButton.isEnabled = true
        markerButton.isEnabled = true
        graphButton.isEnabled = true
        actionsButton.isEnabled = true
        refreshMarkerButton()
        emptyLabel.isHidden = true

        // Everything the sync badge, the ⋯ menu and the commit button read
        // comes off the monitor in one place, so they can't disagree.
        sync = monitor.sync
        stashCount = monitor.stashCount
        hasLocalChanges = monitor.hasLocalChanges

        let branch = monitor.currentBranch
        setBranchTitle("\(branch ?? "detached HEAD") — \((monitor.root as NSString).lastPathComponent)")
        branchButton.toolTip = (monitor.root as NSString).abbreviatingWithTildeInPath
        updateSyncButton(branch: branch)

        // Feedback inbox first — machine feedback that needs routing is the
        // "who needs me right now" of the review workflow.
        if !feedbackEvents.isEmpty {
            rows.append(.section("Feedback — \(feedbackEvents.count)", nil))
            rows += feedbackEvents.map { .feedback($0) }
        }

        // PR review inbox next: other people's PRs awaiting my review,
        // the outward-facing twin of the local review workflow.
        if !reviewPRs.isEmpty {
            rows.append(.section("PR Review Inbox — \(reviewPRs.count)", nil))
            rows += reviewPRs.map { .reviewPR($0) }
        }

        let staged = monitor.stagedByPath.sorted { $0.key < $1.key }
        let unstaged = monitor.unstagedByPath.sorted { $0.key < $1.key }
        stagedPaths = staged.map { Self.pathspec($0.key) }
        unstagedPaths = unstaged.map { Self.pathspec($0.key) }
        untrackedPaths = Set(unstaged.filter { $0.value == "?" }.map { Self.pathspec($0.key) })
        if !staged.isEmpty {
            rows.append(.section("Staged — \(staged.count)", .unstageAll))
            rows += staged.map { .file(path: $0.key, letter: $0.value, staged: true) }
        }
        if !unstaged.isEmpty {
            rows.append(.section("Changes — \(unstaged.count)", .stageAll))
            rows += unstaged.map { .file(path: $0.key, letter: $0.value, staged: false) }
        }
        if staged.isEmpty && unstaged.isEmpty {
            rows.append(.hint("Working tree clean"))
        }
        if let historyPath {
            let name = (historyPath as NSString).lastPathComponent
            rows.append(.section("File History — \(name)", nil))
            rows += historyCommits.map { .commit($0) }
        }
        if !branches.isEmpty {
            rows.append(.section("Branches — \(branches.count)", nil))
            rows += branches.map { .branch($0) }
        }
        refreshCommitBox()
        // A path changed in both columns counts once — the badge answers "how
        // many files are dirty", which is what the file tree's badges show too.
        onChangeCountChanged?(Set(stagedPaths).union(unstagedPaths).count)
        applyRows()
    }

    // Pushes freshly built rows into the table — unless nobody is looking, in
    // which case the rows are already stored and the table is caught up on
    // reveal. Row views are the expensive part of a reload, not `rows`.
    private func applyRows() {
        guard isShowing else {
            needsTableReload = true
            return
        }
        needsTableReload = false
        tableView.reloadData()
    }

    // Porcelain reports an untracked directory as "dir/"; git takes the
    // trailing slash fine, but the rows, the tooltips and the discard
    // confirmation all read better without it, so it comes off in one place.
    static func pathspec(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    // The sync badge, exactly as the Files header draws it: a button only when
    // clicking it would show a diff, dim read-only text otherwise.
    private func updateSyncButton(branch: String?) {
        guard let branch else {
            syncButton.isEnabled = false
            syncButton.attributedTitle = NSAttributedString(string: "detached HEAD", attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: Theme.textFaint,
            ])
            syncButton.toolTip = "HEAD isn’t on a branch, so there is nothing to track."
            return
        }
        let color: NSColor = sync.isGone ? Theme.failed : (sync.hasDifference ? Theme.accent : Theme.textDim)
        syncButton.attributedTitle = NSAttributedString(
            string: sync.badge,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: sync.hasDifference ? .semibold : .regular),
                .foregroundColor: color,
            ]
        )
        syncButton.isEnabled = sync.hasDifference && !sync.isGone
        syncButton.toolTip = sync.tooltip(branch: branch)
        syncButton.setAccessibilityLabel(syncButton.toolTip)
    }

    @objc private func showUpstreamDiff() {
        guard let root = gitRoot, let branch = monitor?.currentBranch, sync.hasUpstream else { return }
        onShowUpstreamDiff?(root, branch)
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
        let titleY = bounds.height - Self.titleHeight
        let headerY = titleY - Self.headerHeight
        let padding: CGFloat = 8
        let buttonSize: CGFloat = 18

        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(
            x: SidebarTitle.leftInset,
            y: titleY + (Self.titleHeight - titleLabel.frame.height) / 2
        )

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
        graphButton.frame = NSRect(
            x: markerButton.frame.minX - 4 - buttonSize,
            y: headerY + (Self.headerHeight - buttonSize) / 2,
            width: buttonSize, height: buttonSize
        )
        let branchX = branchIcon.frame.maxX + 4
        branchButton.frame = NSRect(
            x: branchX, y: headerY + (Self.headerHeight - 18) / 2,
            width: max(0, graphButton.frame.minX - 6 - branchX), height: 18
        )

        // Sync row under the branch row: badge on the left, ⋯ on the right.
        // Both hide outside a repo, where there is no upstream and no action.
        let syncY = headerY - Self.syncRowHeight
        let inRepo = gitRoot != nil
        syncButton.isHidden = !inRepo
        actionsButton.isHidden = !inRepo
        actionsButton.frame = NSRect(
            x: bounds.width - padding - buttonSize,
            y: syncY + (Self.syncRowHeight - buttonSize) / 2,
            width: buttonSize, height: buttonSize
        )
        syncButton.frame = NSRect(
            x: padding, y: syncY + (Self.syncRowHeight - 14) / 2,
            width: max(0, actionsButton.frame.minX - 6 - padding), height: 14
        )

        // Commit box below that, as tall as the message field has been dragged;
        // it collapses to nothing outside a repo, where there is nothing to
        // commit. The window has the last word: whatever was dragged in a tall
        // sidebar gives way here rather than leaving the file list a sliver.
        let boxCeiling = max(Self.minCommitBoxHeight, syncY - Self.minListHeight)
        let boxHeight = inRepo ? min(commitBoxHeight, boxCeiling) : 0
        commitBox.isHidden = !inRepo
        commitBox.frame = NSRect(x: 0, y: syncY - boxHeight, width: bounds.width, height: boxHeight)
        layoutCommitBox()

        let listTop = commitBox.frame.minY
        separator.frame = NSRect(x: 0, y: listTop, width: bounds.width, height: 1)
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, listTop - 1))
        let labelHeight: CGFloat = 40
        emptyLabel.frame = NSRect(
            x: 12, y: (max(0, listTop) - labelHeight) / 2,
            width: max(0, bounds.width - 24), height: labelHeight
        )
    }

    // MARK: - Row clicks

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count, let root = gitRoot else { return }
        switch rows[row] {
        case let .file(path, letter, _):
            let trimmed = Self.pathspec(path)
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
            // A File History row opens that commit's per-file diff.
            if let historyPath {
                onOpenCommitDiff?(historyPath, commit.sha)
            }
        case let .feedback(event):
            // Clicking a feedback row routes it to its session.
            onRouteFeedback?(event)
        case let .reviewPR(pr):
            // Clicking a PR inbox row opens its diff for review.
            onOpenPR?(pr)
        default:
            break
        }
    }

    @objc private func showFullDiff() {
        guard let root = gitRoot else { return }
        onShowFullDiff?(root)
    }

    @objc private func showCommitGraph() {
        guard let root = gitRoot else { return }
        onShowCommitGraph?(root)
    }

    // MARK: - Away marker

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
        case let .file(path, letter, staged):
            buildFileMenu(menu, path: path, letter: letter, staged: staged)
        case let .branch(info):
            buildBranchMenu(menu, branch: info)
        case let .feedback(event):
            buildFeedbackMenu(menu, event: event)
        case let .reviewPR(pr):
            buildPRInboxMenu(menu, pr: pr)
        default:
            break
        }
    }

    private func buildFileMenu(_ menu: NSMenu, path: String, letter: Character, staged: Bool) {
        let trimmed = Self.pathspec(path)
        // Staging leads: it's what the row's own button does, and the menu is
        // where the keyboard-and-right-click half of the same gesture lives.
        let stageItem = menu.addItem(
            withTitle: staged ? "Unstage Changes" : "Stage Changes",
            action: staged ? #selector(unstageFromMenu(_:)) : #selector(stageFromMenu(_:)),
            keyEquivalent: ""
        )
        stageItem.target = self
        stageItem.representedObject = trimmed
        // Discarding a staged path would also throw away the staged version, so
        // it is offered on the working-tree column only — unstage first.
        if !staged {
            let discardItem = menu.addItem(
                withTitle: "Discard Changes…", action: #selector(discardFromMenu(_:)), keyEquivalent: ""
            )
            discardItem.target = self
            discardItem.representedObject = trimmed
        }
        menu.addItem(.separator())
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
        case .section(let title, let action):
            let identifier = NSUserInterfaceItemIdentifier("gitSectionRow")
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? GitSectionRowView ?? {
                let created = GitSectionRowView(frame: .zero)
                created.identifier = identifier
                return created
            }()
            // Recycled rows carry the previous section's handler, so both the
            // symbol and the closure are re-set (or cleared) every time.
            switch action {
            case .stageAll:
                view.configure(title: title, actionSymbol: "plus", tooltip: "Stage all changes") { [weak self] in
                    self?.stageAll()
                }
            case .unstageAll:
                view.configure(title: title, actionSymbol: "minus", tooltip: "Unstage everything") { [weak self] in
                    self?.unstageAll()
                }
            case nil:
                view.configure(title: title)
            }
            return view
        case .file(let path, let letter, let staged):
            let identifier = NSUserInterfaceItemIdentifier("gitChangeRow")
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? GitChangeRowView ?? {
                let created = GitChangeRowView(frame: .zero)
                created.identifier = identifier
                return created
            }()
            let pathspec = Self.pathspec(path)
            view.configure(path: path, letter: letter, staged: staged) { [weak self] in
                guard let self else { return }
                if staged {
                    self.run(.unstage(paths: [pathspec]))
                } else {
                    self.run(.stage(paths: [pathspec]))
                }
            }
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
        case .feedback(let event):
            let identifier = NSUserInterfaceItemIdentifier("gitFeedbackRow")
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? GitFeedbackRowView ?? {
                let created = GitFeedbackRowView(frame: .zero)
                created.identifier = identifier
                return created
            }()
            view.configure(event: event, sessionName: sessionName(for: event))
            return view
        case .reviewPR(let pr):
            let identifier = NSUserInterfaceItemIdentifier("gitPRInboxRow")
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? GitPRInboxRowView ?? {
                let created = GitPRInboxRowView(frame: .zero)
                created.identifier = identifier
                return created
            }()
            view.configure(pr: pr)
            return view
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .section:
            return 20
        case .commit, .feedback, .reviewPR:
            return 34
        default:
            return 24
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[row] {
        case .file, .branch, .commit, .feedback, .reviewPR:
            return true
        default:
            return false
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ThemedTableRowView()
    }

    // Live theme switch: this tab bakes tints into its header buttons and
    // draws the commit box's ground into a layer, and neither is reached by the
    // controller's recursive needsDisplay sweep (that only repaints draw()-based
    // chrome). Called from SidebarView.reapplyTheme, like the Search tab's.
    func reapplyTheme() {
        for button in [markerButton, fullDiffButton, graphButton, actionsButton] {
            button.contentTintColor = Theme.textDim
        }
        branchIcon.contentTintColor = Theme.textDim
        branchButton.contentTintColor = Theme.textDim
        emptyLabel.textColor = Theme.textFaint
        reapplyCommitBoxTheme()
        reload()
    }
}
