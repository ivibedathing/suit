import Cocoa

// Feedback inbox (ROADMAP Phase 29): the Git tab's section for machine feedback
// — CI failures, PR review comments, and merge conflicts across the repo's
// worktrees — each attributed to its originating Claude session and one-tap
// routable there. Loading mirrors the branch/PR pass (off the main thread,
// token-guarded); the gather + prompt live in FeedbackInbox / FeedbackRouting.
extension GitView {
    // MARK: - Loading

    // Gathers the repo's feedback events off the main thread, reusing the PR
    // map from the branch pass so gh isn't re-listed. Runs even without gh —
    // merge-conflict detection is pure git — so a conflicted worktree still
    // shows when GitHub is unreachable.
    func loadFeedbackData() {
        guard let root = gitRoot else { return }
        let prs = prByBranch
        // Session snapshot read here on the main thread; the gather attributes
        // events against it without touching the monitor off-thread.
        let sessions = ClaudeSessionMonitor.shared.sessions.map {
            FeedbackInbox.SessionRef(id: $0.id, cwd: $0.cwd, displayName: $0.displayName)
        }
        feedbackToken += 1
        let token = feedbackToken
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let events = FeedbackInbox.gather(root: root, prByBranch: prs, sessions: sessions)
            DispatchQueue.main.async {
                guard let self, token == self.feedbackToken, root == self.gitRoot else { return }
                self.feedbackEvents = events
                self.reload()
            }
        }
    }

    // The originating session's display name for a feedback row, or nil when
    // attribution was ambiguous (the row then reads "route to a session").
    func sessionName(for event: FeedbackEvent) -> String? {
        guard let id = event.sessionId else { return nil }
        return ClaudeSessionMonitor.shared.sessions.first { $0.id == id }?.displayName
    }

    // MARK: - Context menu

    func buildFeedbackMenu(_ menu: NSMenu, event: FeedbackEvent) {
        let route = menu.addItem(withTitle: "Route to Session…", action: #selector(routeFeedbackItem(_:)), keyEquivalent: "")
        route.target = self
        route.representedObject = event.id
        let review = menu.addItem(withTitle: "Start Review Pass in Worktree", action: #selector(startReviewPassItem(_:)), keyEquivalent: "")
        review.target = self
        review.representedObject = event.id
        if event.prNumber != nil, let branch = event.branch, GitHubCLI.isAvailable {
            menu.addItem(.separator())
            let open = menu.addItem(withTitle: "Open PR on GitHub", action: #selector(openFeedbackPRItem(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = branch
        }
    }

    @objc private func routeFeedbackItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let event = feedbackEvents.first(where: { $0.id == id }) else { return }
        onRouteFeedback?(event)
    }

    @objc private func startReviewPassItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let event = feedbackEvents.first(where: { $0.id == id }) else { return }
        onStartReviewPass?(event)
    }

    @objc private func openFeedbackPRItem(_ sender: NSMenuItem) {
        guard let branch = sender.representedObject as? String, let root = gitRoot else { return }
        GitHubCLI.openWeb(root: root, branch: branch, hasPR: true)
    }
}

// One feedback row (Phase 29): a kind glyph (red for CI/conflict, amber for
// review comments), the event title on top, and a faint subtitle naming the
// worktree/branch and the originating session — or "route to a session" when
// attribution was ambiguous.
final class GitFeedbackRowView: NSTableCellView {
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

    func configure(event: FeedbackEvent, sessionName: String?) {
        let tint = Self.tint(for: event.kind)
        icon.image = NSImage(systemSymbolName: event.kind.symbolName, accessibilityDescription: event.kind.label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        icon.contentTintColor = tint

        titleLabel.stringValue = "\(event.kind.label): \(event.title)"

        let worktree = (event.worktreePath as NSString).lastPathComponent
        let where_ = event.branch.map { "\($0)" } ?? worktree
        if let sessionName {
            subtitleLabel.stringValue = "\(where_) · → \(sessionName)"
            subtitleLabel.textColor = Theme.textDim
        } else {
            subtitleLabel.stringValue = "\(where_) · route to a session…"
            subtitleLabel.textColor = Theme.textFaint
        }

        toolTip = "\(event.kind.label) — \(event.title)\n\(event.worktreePath)"
        needsLayout = true
    }

    private static func tint(for kind: FeedbackEventKind) -> NSColor {
        switch kind {
        case .ciFailure, .mergeConflict: return Theme.failed
        case .prComment: return Theme.accent
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
