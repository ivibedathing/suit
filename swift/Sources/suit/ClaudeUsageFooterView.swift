import Cocoa

// One line of the usage footer: limit name, a thin fill bar, and the used %.
private final class UsageRowView: NSView {
    static let height: CGFloat = 18

    private let nameLabel = NSTextField(labelWithString: "")
    private let pctLabel = NSTextField(labelWithString: "")
    private var pct: Double?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        nameLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        nameLabel.textColor = Theme.textDim
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        pctLabel.font = Theme.usageFont
        pctLabel.alignment = .right
        addSubview(pctLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(name: String, pct: Double?) {
        nameLabel.stringValue = name
        self.pct = pct
        if let pct {
            pctLabel.stringValue = "\(Int(pct.rounded()))%"
            pctLabel.textColor = Theme.usageLevelColor(pct)
        } else {
            pctLabel.stringValue = "—"
            pctLabel.textColor = Theme.textFaint
        }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        nameLabel.frame = NSRect(x: 10, y: (bounds.height - 13) / 2, width: 74, height: 13)
        pctLabel.frame = NSRect(x: bounds.width - 44, y: (bounds.height - 13) / 2, width: 34, height: 13)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    // The fill bar between the name and the percentage.
    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(
            x: 88, y: (bounds.height - 3) / 2,
            width: max(0, bounds.width - 88 - 48), height: 3
        )
        guard track.width > 12 else { return }
        Theme.hover.setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
        guard let pct else { return }
        let fill = NSRect(
            x: track.minX, y: track.minY,
            width: track.width * CGFloat(min(max(pct, 0), 100)) / 100, height: track.height
        )
        Theme.usageLevelColor(pct).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

// The sidebar's bottom-most strip: Claude Code's global rate-limit usage
// (5h window, all-models week, and any model-scoped weeklies the statusline
// reports, e.g. Fable) plus a gear that opens the Claude Code integration
// settings. Rows show "—" until a fresh claude-status.json exists (the
// statusline script only writes while Claude Code runs).
final class ClaudeUsageFooterView: NSView {
    private static let headerHeight: CGFloat = 16
    private static let padding: CGFloat = 6

    // Opens "Install Claude Code Integration…" (the window controller routes
    // to AppDelegate).
    var onOpenSettings: (() -> Void)?
    // Same contract as RecentFoldersView: poke the sidebar's manual layout
    // when the row count changes.
    var onHeightChange: (() -> Void)?

    private let headerLabel = NSTextField(labelWithString: "Claude Code")
    private let settingsButton = NSButton(frame: .zero)
    private var rowViews: [UsageRowView] = []
    // (name, pct) per visible row; nil pct renders as "—".
    private var rows: [(String, Double?)] = [("5h", nil), ("Week", nil)]

    var desiredHeight: CGFloat {
        Self.padding + Self.headerHeight + CGFloat(rows.count) * UsageRowView.height + Self.padding
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        headerLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        headerLabel.textColor = Theme.textFaint
        addSubview(headerLabel)

        settingsButton.isBordered = false
        settingsButton.bezelStyle = .regularSquare
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Claude Code Settings")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        settingsButton.contentTintColor = Theme.textDim
        settingsButton.toolTip = "Install / update the Claude Code integration"
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        addSubview(settingsButton)

        NotificationCenter.default.addObserver(
            self, selector: #selector(monitorChanged),
            name: ClaudeSessionMonitor.didUpdate, object: nil
        )
        render(usage: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func monitorChanged() {
        render(usage: ClaudeSessionMonitor.shared.usage)
    }

    // Split from monitorChanged so an offscreen harness can feed a snapshot
    // without writing the user's real ~/.suit/claude-status.json.
    func render(usage: ClaudeUsage?) {
        var next: [(String, Double?)] = [("5h", usage?.fiveHourPct), ("Week", usage?.sevenDayPct)]
        for weekly in usage?.modelWeeklies ?? [] {
            next.append(("Week · \(weekly.name)", weekly.pct))
        }
        let countChanged = next.count != rowViews.count
        rows = next

        if countChanged {
            rowViews.forEach { $0.removeFromSuperview() }
            rowViews = rows.map { _ in
                let row = UsageRowView(frame: .zero)
                addSubview(row)
                return row
            }
        }
        for (row, view) in zip(rows, rowViews) {
            view.configure(name: row.0, pct: row.1)
        }
        needsLayout = true
        if countChanged {
            onHeightChange?()
        }
    }

    override func layout() {
        super.layout()
        headerLabel.frame = NSRect(
            x: 10, y: bounds.height - Self.padding - Self.headerHeight + 2,
            width: max(0, bounds.width - 40), height: 13
        )
        settingsButton.frame = NSRect(
            x: bounds.width - 26, y: bounds.height - Self.padding - Self.headerHeight + 1,
            width: 16, height: 15
        )
        var y = bounds.height - Self.padding - Self.headerHeight - UsageRowView.height
        for row in rowViews {
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: UsageRowView.height)
            y -= UsageRowView.height
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    // Hairline along the top, like the Recent Folders strip above it.
    override func draw(_ dirtyRect: NSRect) {
        Theme.hairline.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}
