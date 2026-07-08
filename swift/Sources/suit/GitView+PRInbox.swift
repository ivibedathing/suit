import Cocoa

// PR review inbox (ROADMAP Phase 39): the Git tab's section listing open PRs
// that involve me — authored, assigned, or review-requested — so other people's
// PRs can be reviewed end-to-end without leaving Suit. Loading mirrors the
// branch/feedback pass (off the main thread, token-guarded); the gh calls +
// parsing live in GitHubCLI.reviewInbox / PRReviewInbox (UI-free).
extension GitView {
    // MARK: - Loading

    // Fetches the inbox off the main thread; no-op without gh (the section just
    // stays hidden). Called from the branch/PR pass and the palette reveal.
    func loadReviewInbox() {
        guard let root = gitRoot, GitHubCLI.isAvailable else { return }
        reviewInboxToken += 1
        let token = reviewInboxToken
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let prs = GitHubCLI.reviewInbox(root: root)
            DispatchQueue.main.async {
                guard let self, token == self.reviewInboxToken, root == self.gitRoot else { return }
                self.reviewPRs = prs
                self.reload()
            }
        }
    }

    // MARK: - Context menu

    func buildPRInboxMenu(_ menu: NSMenu, pr: PRReviewItem) {
        let review = menu.addItem(withTitle: "Review Changes", action: #selector(reviewPRItem(_:)), keyEquivalent: "")
        review.target = self
        review.representedObject = pr.number
        menu.addItem(.separator())
        let open = menu.addItem(withTitle: "Open on GitHub", action: #selector(openPRInboxItem(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = pr.url
    }

    @objc private func reviewPRItem(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? Int,
              let pr = reviewPRs.first(where: { $0.number == number }) else { return }
        onOpenPR?(pr)
    }

    @objc private func openPRInboxItem(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String,
              let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

// One PR inbox row: the check glyph + PR title on top, a faint "#N · author ·
// branch" subtitle below — the "what's waiting for my review" at a glance.
final class GitPRInboxRowView: NSTableCellView {
    private let icon = NSImageView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)
        titleLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        subtitleLabel.font = .systemFont(ofSize: 10)
        subtitleLabel.textColor = Theme.textFaint
        subtitleLabel.lineBreakMode = .byTruncatingTail
        addSubview(subtitleLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(pr: PRReviewItem) {
        let tint = Self.tint(for: pr.checks)
        icon.image = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: "pull request")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        icon.contentTintColor = tint

        titleLabel.stringValue = pr.title.isEmpty ? "PR #\(pr.number)" : pr.title

        let glyph = pr.checksGlyph.isEmpty ? "" : " \(pr.checksGlyph)"
        let author = pr.author.isEmpty ? "" : " · \(pr.author)"
        subtitleLabel.stringValue = "#\(pr.number)\(glyph)\(author) · \(pr.branch)"

        toolTip = "PR #\(pr.number) — \(pr.title)\n\(pr.branch) · \(pr.author)"
        needsLayout = true
    }

    // Tint the PR-icon by the check rollup, matching the Git tab's badge colors.
    private static func tint(for checks: PRReviewItem.Checks) -> NSColor {
        switch checks {
        case .passing: return Theme.sessionDone
        case .failing: return Theme.failed
        case .pending: return Theme.accent
        case .none: return Theme.textDim
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 6, y: (bounds.height - 15) / 2, width: 16, height: 15)
        let textX: CGFloat = 26
        titleLabel.frame = NSRect(x: textX, y: bounds.height - 20, width: max(0, bounds.width - textX - 8), height: 15)
        subtitleLabel.frame = NSRect(x: textX, y: 3, width: max(0, bounds.width - textX - 8), height: 13)
    }
}
