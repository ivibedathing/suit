import Cocoa

// The single header at the top of the Files tab (the "Minimal" sidebar
// redesign): it consolidates what used to be two separate strips — the root
// header above the tree and the git footer below it — into one bar, so the
// tab reads as "project identity + actions on top, tree below" with nothing
// stacked underneath.
//
// Top row: the browsed root's name (a pin glyph when pinned rather than
// following the focused pane) on the left, and right-aligned action buttons —
// search (drops the search field over the tree), choose folder, and unpin
// while pinned. Branch row (only inside a git repo): the checked-out branch as
// a worktree/branch switcher, then the upstream sync badge ("↑2 ↓1", click to
// diff against the remote), then the git actions menu (fetch/pull/push, stash,
// discard, new/delete branch). The switcher enumeration is shared with the
// palette-reached Git tab header via WorktreeSwitcher; the actions themselves
// are composed by the UI-free GitBranchOps.
//
// The branch/worktree counts that used to sit at the right of this row now
// live in the branch button's tooltip: at sidebar widths there is room for
// exactly one right-hand affordance per row, and "2 commits to push" is worth
// more than "12 branches" — the counts are still one hover (or one click into
// the switcher menu) away.
final class ProjectHeaderView: NSView {
    static let topRowHeight: CGFloat = 32
    static let branchRowHeight: CGFloat = 22

    // Reveal the search field over the tree (⌘⇧F does the same thing).
    var onSearch: (() -> Void)?
    var onChooseFolder: (() -> Void)?
    var onUnpin: (() -> Void)?
    // Repoint the sidebar at another worktree (absolute path).
    var onSwitchWorktree: ((String) -> Void)?
    // Check out a local branch in the shown repo (repo root, branch name).
    var onCheckoutBranch: ((_ root: String, _ branch: String) -> Void)?
    // Run one composed git action against the shown repo.
    var onBranchAction: ((_ root: String, _ action: GitBranchOps.Action) -> Void)?
    // Open the local↔upstream diff for the checked-out branch in a diff tab.
    var onShowUpstreamDiff: ((_ root: String, _ branch: String) -> Void)?
    // Prompt for a name, then create/checkout the branch.
    var onNewBranch: ((_ root: String) -> Void)?

    private let iconView = NSImageView(frame: .zero)
    private let nameLabel = NSTextField(labelWithString: "")
    private let searchButton = NSButton(frame: .zero)
    private let chooseButton = NSButton(frame: .zero)
    private let unpinButton = NSButton(frame: .zero)

    private let branchIconView = NSImageView(frame: .zero)
    private let branchButton = NSButton(frame: .zero)
    private let syncButton = NSButton(frame: .zero)
    private let actionsButton = NSButton(frame: .zero)
    private let separator = NSBox(frame: .zero)

    // Whether the branch row is shown (only inside a git repo).
    private(set) var hasBranch = false
    // The repo root the switcher operates on, and the checked-out branch (for
    // the menu's checkmark), set on each updateBranch().
    private var repoRoot: String?
    private var currentBranch: String?
    // The rest of the repo state the actions menu reads: upstream position,
    // whether Stash/Discard have anything to act on, and how many stash
    // entries Pop would draw from.
    private var sync: GitBranchOps.SyncState = .untracked
    private var hasLocalChanges = false
    private var stashCount = 0

    // The header's height for the current state — one row outside a repo, two
    // inside. FileBrowserView reads this to lay itself out.
    var preferredHeight: CGFloat {
        Self.topRowHeight + (hasBranch ? Self.branchRowHeight : 0)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = Theme.textDim
        addSubview(iconView)

        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = Theme.textPrimary
        nameLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(nameLabel)

        configure(button: searchButton, symbol: "magnifyingglass", tooltip: "Search project (⌘⇧F)", action: #selector(search))
        configure(button: chooseButton, symbol: "folder.badge.plus", tooltip: "Select Folder…", action: #selector(chooseFolder))
        configure(button: unpinButton, symbol: "pin.slash", tooltip: "Unpin — follow the focused pane again", action: #selector(unpin))
        unpinButton.isHidden = true

        branchIconView.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "git branch")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        branchIconView.contentTintColor = Theme.textDim
        branchIconView.imageScaling = .scaleProportionallyDown
        addSubview(branchIconView)

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

        syncButton.isBordered = false
        syncButton.imagePosition = .noImage
        syncButton.alignment = .right
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

        separator.boxType = .separator
        addSubview(separator)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure(button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.contentTintColor = Theme.textDim
        addSubview(button)
    }

    // MARK: - Content

    func updateRoot(path: String, pinned: Bool) {
        nameLabel.stringValue = (path as NSString).lastPathComponent
        nameLabel.toolTip = (path as NSString).abbreviatingWithTildeInPath
        iconView.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "folder", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        iconView.contentTintColor = pinned ? Theme.accent : Theme.textDim
        unpinButton.isHidden = !pinned
        needsLayout = true
    }

    // Feeds the branch row; `root == nil` hides it (not a git repo).
    func updateBranch(
        root: String?, branch: String?, branches: Int, worktrees: Int,
        sync: GitBranchOps.SyncState = .untracked, hasLocalChanges: Bool = false, stashCount: Int = 0
    ) {
        hasBranch = root != nil
        branchIconView.isHidden = !hasBranch
        branchButton.isHidden = !hasBranch
        syncButton.isHidden = !hasBranch
        actionsButton.isHidden = !hasBranch
        guard hasBranch else { needsLayout = true; return }

        repoRoot = root
        currentBranch = branch
        self.sync = sync
        self.hasLocalChanges = hasLocalChanges
        self.stashCount = stashCount
        setBranchTitle(branch ?? "detached HEAD", dim: branch == nil)

        let counts: String
        if branches == 0 && worktrees == 0 {
            counts = ""
        } else {
            let branchPart = "\(branches) \(branches == 1 ? "branch" : "branches")"
            let worktreePart = "\(worktrees) \(worktrees == 1 ? "worktree" : "worktrees")"
            counts = " — \(branchPart) · \(worktreePart)"
        }
        branchButton.toolTip = "\(branch ?? "detached HEAD")\(counts)"
        updateSyncButton(branch: branch)
        needsLayout = true
    }

    // The sync badge. It is only a *button* when clicking it would show
    // something: with no upstream, or nothing to pull or push, it stays as dim
    // read-only text rather than opening an empty diff tab.
    private func updateSyncButton(branch: String?) {
        guard let branch else {
            // Detached HEAD tracks nothing; the row's actions still apply.
            syncButton.isEnabled = false
            syncButton.attributedTitle = NSAttributedString(string: "")
            syncButton.toolTip = nil
            return
        }
        let clickable = sync.hasDifference && !sync.isGone
        let color: NSColor = sync.isGone ? Theme.failed : (sync.hasDifference ? Theme.accent : Theme.textDim)
        syncButton.attributedTitle = NSAttributedString(
            string: sync.badge,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: sync.hasDifference ? .semibold : .regular),
                .foregroundColor: color,
            ]
        )
        syncButton.isEnabled = clickable
        syncButton.toolTip = sync.tooltip(branch: branch)
        syncButton.setAccessibilityLabel(syncButton.toolTip)
    }

    private func setBranchTitle(_ title: String, dim: Bool) {
        branchButton.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: dim ? Theme.textDim : Theme.textPrimary,
            ]
        )
    }

    // MARK: - Actions

    @objc private func search() { onSearch?() }
    @objc private func chooseFolder() { onChooseFolder?() }
    @objc private func unpin() { onUnpin?() }

    // MARK: - Worktree / branch switcher

    @objc private func openSwitcherMenu() {
        guard let repoRoot else { return }
        let menu = NSMenu()

        menu.addItem(Self.headerItem("Worktrees"))
        for worktree in WorktreeSwitcher.worktrees(root: repoRoot) {
            let name = (worktree.path as NSString).lastPathComponent
            let item = menu.addItem(
                withTitle: "\(name) — \(worktree.branch ?? "detached")",
                action: #selector(switchWorktreeItem(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = worktree.path
            item.state = worktree.path == repoRoot ? .on : .off
            item.toolTip = worktree.path
            item.indentationLevel = 1
        }

        menu.addItem(.separator())
        menu.addItem(Self.headerItem("Branches"))
        for branch in WorktreeSwitcher.branches(root: repoRoot) {
            let item = menu.addItem(withTitle: branch, action: #selector(checkoutBranchItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = branch
            item.state = branch == currentBranch ? .on : .off
            item.indentationLevel = 1
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
        guard let path = sender.representedObject as? String, path != repoRoot else { return }
        onSwitchWorktree?(path)
    }

    @objc private func checkoutBranchItem(_ sender: NSMenuItem) {
        guard let branch = sender.representedObject as? String, branch != currentBranch, let repoRoot else { return }
        onCheckoutBranch?(repoRoot, branch)
    }

    // MARK: - Git actions menu

    // The "⋯" menu on the branch row. Every entry is a GitBranchOps.Action
    // carried on the item, so this method holds no git knowledge beyond which
    // actions make sense in the current state — an item that couldn't succeed
    // (push with no upstream, pop with an empty stash, stash with a clean tree)
    // is disabled rather than hidden, so the menu's shape stays stable.
    @objc private func openActionsMenu() {
        guard let repoRoot else { return }
        let menu = NSMenu()
        // Items are enabled from repo state, not from responder-chain
        // validation — AppKit's auto-enabling would undo every isEnabled below.
        menu.autoenablesItems = false
        let dirty = hasLocalChanges

        addAction(to: menu, title: "Fetch", action: .fetch)
        // Pull needs somewhere to pull from; behind == 0 is *not* a reason to
        // disable it, since the counts are only as fresh as the last fetch.
        addAction(to: menu, title: "Pull", action: .pull, enabled: sync.hasUpstream && !sync.isGone)
        addAction(to: menu, title: "Pull (Rebase)", action: .pullRebase, enabled: sync.hasUpstream && !sync.isGone)
        if sync.hasUpstream && !sync.isGone {
            addAction(to: menu, title: sync.ahead > 0 ? "Push (\(sync.ahead))" : "Push", action: .push)
        } else if let branch = currentBranch {
            addAction(to: menu, title: "Publish Branch", action: .publish(branch: branch))
        }

        if sync.hasDifference, !sync.isGone, currentBranch != nil {
            menu.addItem(.separator())
            let item = menu.addItem(
                withTitle: "Diff vs \(sync.upstream ?? "Upstream")",
                action: #selector(showUpstreamDiff), keyEquivalent: ""
            )
            item.target = self
        }

        menu.addItem(.separator())
        addAction(to: menu, title: "Stash Changes", action: .stash, enabled: dirty)
        addAction(
            to: menu, title: stashCount > 0 ? "Pop Stash (\(stashCount))" : "Pop Stash",
            action: .stashPop, enabled: stashCount > 0
        )
        addAction(to: menu, title: "Discard All Changes…", action: .discardAll, enabled: dirty)

        menu.addItem(.separator())
        let newItem = menu.addItem(withTitle: "New Branch…", action: #selector(newBranchItem), keyEquivalent: "")
        newItem.target = self
        addDeleteBranchItem(to: menu, root: repoRoot)

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: actionsButton.frame.minX - 160, y: actionsButton.frame.minY - 2),
            in: self
        )
    }

    private func addAction(to menu: NSMenu, title: String, action: GitBranchOps.Action, enabled: Bool = true) {
        let item = menu.addItem(withTitle: title, action: #selector(runBranchActionItem(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = BoxedAction(action)
        item.isEnabled = enabled
    }

    // Delete is a submenu of the branches git would actually let us delete —
    // never the checked-out one, never one another worktree holds, since
    // `git branch -d` refuses both and an always-failing menu entry is worse
    // than no entry. Only the safe `-d` is offered; force-deleting an unmerged
    // branch is reached by escalation from the failure alert, so the "these
    // commits become unreachable" warning is shown at the moment it's true.
    private func addDeleteBranchItem(to menu: NSMenu, root: String) {
        let claimed = Set(WorktreeSwitcher.worktrees(root: root).compactMap { $0.branch })
        let deletable = GitBranchOps.deletableBranches(
            all: WorktreeSwitcher.branches(root: root), current: currentBranch, checkedOutElsewhere: claimed
        )
        let parent = menu.addItem(withTitle: "Delete Branch", action: nil, keyEquivalent: "")
        guard !deletable.isEmpty else {
            parent.isEnabled = false
            return
        }
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for name in deletable {
            addAction(to: submenu, title: name, action: .deleteBranch(name: name, force: false))
        }
        parent.submenu = submenu
    }

    // NSMenuItem.representedObject is `Any?`, but an enum with associated
    // values doesn't survive the round trip as cleanly as a class reference —
    // box it so the cast back is unambiguous.
    private final class BoxedAction {
        let action: GitBranchOps.Action
        init(_ action: GitBranchOps.Action) { self.action = action }
    }

    @objc private func runBranchActionItem(_ sender: NSMenuItem) {
        guard let boxed = sender.representedObject as? BoxedAction, let repoRoot else { return }
        onBranchAction?(repoRoot, boxed.action)
    }

    @objc private func newBranchItem() {
        guard let repoRoot else { return }
        onNewBranch?(repoRoot)
    }

    @objc private func showUpstreamDiff() {
        guard let repoRoot, let currentBranch, sync.hasUpstream else { return }
        onShowUpstreamDiff?(repoRoot, currentBranch)
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let padding: CGFloat = 8
        let buttonSize: CGFloat = 20
        let gap: CGFloat = 2

        // Top row sits at the top of the view (branch row, if any, below it).
        let topY = bounds.height - Self.topRowHeight

        // Right-aligned action buttons: choose (rightmost), search, then unpin.
        var right = bounds.width - padding + gap
        for button in [chooseButton, searchButton] {
            right -= gap
            button.frame = NSRect(x: right - buttonSize, y: topY + (Self.topRowHeight - buttonSize) / 2, width: buttonSize, height: buttonSize)
            right = button.frame.minX
        }
        if !unpinButton.isHidden {
            right -= gap
            unpinButton.frame = NSRect(x: right - buttonSize, y: topY + (Self.topRowHeight - buttonSize) / 2, width: buttonSize, height: buttonSize)
            right = unpinButton.frame.minX
        }

        iconView.frame = NSRect(x: padding, y: topY + (Self.topRowHeight - 14) / 2, width: 14, height: 14)
        let nameX = iconView.frame.maxX + 6
        nameLabel.frame = NSRect(x: nameX, y: topY + (Self.topRowHeight - 16) / 2, width: max(0, right - nameX - 4), height: 16)

        // Branch row: [icon] [branch ▾] … [sync badge] [⋯].
        if hasBranch {
            let rowY: CGFloat = 0
            branchIconView.frame = NSRect(x: padding, y: rowY + (Self.branchRowHeight - 12) / 2, width: 12, height: 12)

            let actionsSize: CGFloat = 18
            actionsButton.frame = NSRect(
                x: bounds.width - padding - actionsSize, y: rowY + (Self.branchRowHeight - actionsSize) / 2,
                width: actionsSize, height: actionsSize
            )
            // +4 over the measured width: a borderless NSButton clips its last
            // glyph when the frame matches its title width exactly.
            let syncWidth = min(ceil(syncButton.attributedTitle.size().width) + 4, bounds.width / 2)
            syncButton.frame = NSRect(
                x: actionsButton.frame.minX - 4 - syncWidth, y: rowY + (Self.branchRowHeight - 14) / 2,
                width: syncWidth, height: 14
            )
            let branchX = branchIconView.frame.maxX + 4
            branchButton.frame = NSRect(
                x: branchX, y: rowY + (Self.branchRowHeight - 16) / 2,
                width: max(0, syncButton.frame.minX - 6 - branchX), height: 16
            )
        }

        separator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
    }
}
