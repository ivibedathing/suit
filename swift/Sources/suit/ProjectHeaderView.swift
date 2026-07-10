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
// a worktree/branch switcher, with branch/worktree counts on the right. The
// switcher enumeration is shared with the palette-reached Git tab header via
// WorktreeSwitcher.
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

    private let iconView = NSImageView(frame: .zero)
    private let nameLabel = NSTextField(labelWithString: "")
    private let searchButton = NSButton(frame: .zero)
    private let chooseButton = NSButton(frame: .zero)
    private let unpinButton = NSButton(frame: .zero)

    private let branchIconView = NSImageView(frame: .zero)
    private let branchButton = NSButton(frame: .zero)
    private let countsLabel = NSTextField(labelWithString: "")
    private let separator = NSBox(frame: .zero)

    // Whether the branch row is shown (only inside a git repo).
    private(set) var hasBranch = false
    // The repo root the switcher operates on, and the checked-out branch (for
    // the menu's checkmark), set on each updateBranch().
    private var repoRoot: String?
    private var currentBranch: String?

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

        countsLabel.font = .systemFont(ofSize: 10)
        countsLabel.textColor = Theme.textDim
        countsLabel.alignment = .right
        addSubview(countsLabel)

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
    func updateBranch(root: String?, branch: String?, branches: Int, worktrees: Int) {
        hasBranch = root != nil
        branchIconView.isHidden = !hasBranch
        branchButton.isHidden = !hasBranch
        countsLabel.isHidden = !hasBranch
        guard hasBranch else { needsLayout = true; return }

        repoRoot = root
        currentBranch = branch
        setBranchTitle(branch ?? "detached HEAD", dim: branch == nil)
        if branches == 0 && worktrees == 0 {
            countsLabel.stringValue = ""
        } else {
            let branchPart = "\(branches) \(branches == 1 ? "branch" : "branches")"
            let worktreePart = "\(worktrees) \(worktrees == 1 ? "worktree" : "worktrees")"
            countsLabel.stringValue = "\(branchPart) · \(worktreePart)"
        }
        branchButton.toolTip = "\(branch ?? "detached HEAD") — \(countsLabel.stringValue)"
        needsLayout = true
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

        // Branch row.
        if hasBranch {
            let rowY: CGFloat = 0
            branchIconView.frame = NSRect(x: padding, y: rowY + (Self.branchRowHeight - 12) / 2, width: 12, height: 12)
            // +2 over the measured width: NSTextField clips its last glyph when
            // the frame matches intrinsicContentSize exactly at this font size.
            let countsWidth = min(ceil(countsLabel.intrinsicContentSize.width) + 2, bounds.width - padding * 2)
            countsLabel.frame = NSRect(x: bounds.width - padding - countsWidth, y: rowY + (Self.branchRowHeight - 14) / 2, width: countsWidth, height: 14)
            let branchX = branchIconView.frame.maxX + 4
            branchButton.frame = NSRect(x: branchX, y: rowY + (Self.branchRowHeight - 16) / 2, width: max(0, countsLabel.frame.minX - 6 - branchX), height: 16)
        }

        separator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
    }
}
