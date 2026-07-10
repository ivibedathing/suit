import Cocoa

// One changed-file row: status letter (colored like the Files tree's badges),
// then one label carrying "name  directory" as a single attributed string —
// name in primary, directory in faint — so the name never gets squeezed by a
// separately-framed sibling; tail truncation eats the directory first.
final class GitChangeRowView: NSTableCellView {
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
final class GitSectionRowView: NSTableCellView {
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
final class GitHintRowView: NSTableCellView {
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

// One File History commit row: short sha (age-tinted, mono)
// beside the subject on top, author + relative date below in faint text.
final class GitCommitRowView: NSTableCellView {
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

// One branch row: branch-icon + name on the left (current branch in
// accent/semibold), and a right-aligned cluster of ahead/behind counts, an
// optional PR badge, and a dirty dot. A worktree glyph marks branches checked
// out in a linked worktree.
final class GitBranchRowView: NSTableCellView {
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
