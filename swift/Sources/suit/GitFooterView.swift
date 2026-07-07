import Cocoa

// The strip under the Files tree: the checked-out branch on the left, branch
// and worktree counts on the right, fed by GitStatusMonitor. Hidden entirely
// outside git repos.
final class GitFooterView: NSView {
    static let height: CGFloat = 24

    private let separator = NSBox(frame: .zero)
    private let iconView = NSImageView(frame: .zero)
    private let branchLabel = NSTextField(labelWithString: "")
    private let countsLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        separator.boxType = .separator
        addSubview(separator)

        iconView.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "git branch")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        iconView.contentTintColor = Theme.textDim
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        branchLabel.font = .systemFont(ofSize: 11, weight: .medium)
        branchLabel.lineBreakMode = .byTruncatingTail
        addSubview(branchLabel)

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

    func update(branch: String?, branches: Int, worktrees: Int) {
        branchLabel.stringValue = branch ?? "detached HEAD"
        branchLabel.textColor = branch == nil ? Theme.textDim : Theme.textPrimary
        // Counts are zero only before the first refresh lands; show nothing
        // rather than "0 branches" for that beat.
        if branches == 0 && worktrees == 0 {
            countsLabel.stringValue = ""
        } else {
            let branchPart = "\(branches) \(branches == 1 ? "branch" : "branches")"
            let worktreePart = "\(worktrees) \(worktrees == 1 ? "worktree" : "worktrees")"
            countsLabel.stringValue = "\(branchPart) · \(worktreePart)"
        }
        toolTip = "\(branchLabel.stringValue) — \(countsLabel.stringValue)"
        needsLayout = true
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
        branchLabel.frame = NSRect(
            x: branchX,
            y: (bounds.height - 15) / 2,
            width: max(0, countsLabel.frame.minX - 6 - branchX),
            height: 15
        )
    }
}
