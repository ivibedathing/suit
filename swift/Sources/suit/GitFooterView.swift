import Cocoa

// The strip under the Files tree: the checked-out branch on the left, branch
// and worktree counts on the right, fed by GitStatusMonitor. Hidden entirely
// outside git repos.
//
// The branch name is the sidebar's worktree/branch switcher (it moved here when
// the dedicated Git tab was removed): clicking it drops a menu of the repo's
// worktrees and local branches — pick a worktree to repoint the sidebar there,
// or a branch to check it out. The switcher enumeration is shared with the
// (palette-reached) Git tab header via WorktreeSwitcher.
final class GitFooterView: NSView {
    static let height: CGFloat = 24

    private let separator = NSBox(frame: .zero)
    private let iconView = NSImageView(frame: .zero)
    private let branchButton = NSButton(frame: .zero)
    private let countsLabel = NSTextField(labelWithString: "")

    // The repo root the switcher operates on, and the checked-out branch (for
    // the menu's checkmark), set on each update().
    private var root: String?
    private var currentBranch: String?

    // Repoint the sidebar at another worktree (absolute path).
    var onSwitchWorktree: ((String) -> Void)?
    // Check out a local branch in the shown repo (repo root, branch name).
    var onCheckoutBranch: ((_ root: String, _ branch: String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        separator.boxType = .separator
        addSubview(separator)

        iconView.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "git branch")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        iconView.contentTintColor = Theme.textDim
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

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
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    func update(root: String?, branch: String?, branches: Int, worktrees: Int) {
        self.root = root
        self.currentBranch = branch
        setBranchTitle(branch ?? "detached HEAD", dim: branch == nil)
        // The switcher only makes sense once we know the repo root.
        branchButton.isEnabled = root != nil
        // Counts are zero only before the first refresh lands; show nothing
        // rather than "0 branches" for that beat.
        if branches == 0 && worktrees == 0 {
            countsLabel.stringValue = ""
        } else {
            let branchPart = "\(branches) \(branches == 1 ? "branch" : "branches")"
            let worktreePart = "\(worktrees) \(worktrees == 1 ? "worktree" : "worktrees")"
            countsLabel.stringValue = "\(branchPart) · \(worktreePart)"
        }
        toolTip = "\(branch ?? "detached HEAD") — \(countsLabel.stringValue)"
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

    // MARK: - Worktree / branch switcher

    @objc private func openSwitcherMenu() {
        guard let root else { return }
        let menu = NSMenu()

        menu.addItem(GitFooterView.headerItem("Worktrees"))
        for worktree in WorktreeSwitcher.worktrees(root: root) {
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
        menu.addItem(GitFooterView.headerItem("Branches"))
        for branch in WorktreeSwitcher.branches(root: root) {
            let item = menu.addItem(withTitle: branch, action: #selector(checkoutBranchItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = branch
            item.state = branch == currentBranch ? .on : .off
            item.indentationLevel = 1
        }

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: branchButton.frame.minX, y: branchButton.frame.maxY + 2),
            in: self
        )
    }

    private static func headerItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func switchWorktreeItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, path != root else { return }
        onSwitchWorktree?(path)
    }

    @objc private func checkoutBranchItem(_ sender: NSMenuItem) {
        guard let branch = sender.representedObject as? String, branch != currentBranch, let root else { return }
        onCheckoutBranch?(root, branch)
    }

    override func layout() {
        super.layout()
        separator.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        let padding: CGFloat = 8
        iconView.frame = NSRect(x: padding, y: (bounds.height - 12) / 2 - 1, width: 12, height: 12)
        // The counts keep their natural width; the branch name truncates into
        // whatever is left, so a narrow sidebar drops the name, not the counts.
        // +2 over the measured width: NSTextField clips its last glyph when
        // the frame matches intrinsicContentSize exactly at this font size.
        let countsWidth = min(ceil(countsLabel.intrinsicContentSize.width) + 2, bounds.width - padding * 2)
        countsLabel.frame = NSRect(
            x: bounds.width - padding - countsWidth,
            y: (bounds.height - 14) / 2,
            width: countsWidth,
            height: 14
        )
        let branchX = iconView.frame.maxX + 4
        branchButton.frame = NSRect(
            x: branchX,
            y: (bounds.height - 16) / 2,
            width: max(0, countsLabel.frame.minX - 6 - branchX),
            height: 16
        )
    }
}
