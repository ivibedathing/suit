import Cocoa

// The feed panel (ROADMAP Phase 38): a floating, window-spanning "Activity"
// panel — the chronological record of what moved across the fleet, newest-first,
// filterable by repo / kind, with a "what happened today" digest header. A row
// click routes to the thing it names (session pane / PR on GitHub / Autopilot
// log). Same floating-panel shape as the Fleet dashboard (Phase 28).

// Tone → Theme color, kept out of the Foundation-only core.
private extension ActivityKind.Tone {
    var color: NSColor {
        switch self {
        case .positive: return Theme.sessionDone
        case .negative: return Theme.sessionBusy
        case .attention: return Theme.sessionNeedsInput
        case .neutral: return Theme.textDim
        }
    }
}

// One feed row: a tone-colored glyph, a two-line title/subtitle block, and a
// trailing relative age. Reused across reloads via configure(event:).
private final class ActivityRowView: NSView {
    private let glyph = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let ageLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glyph.imageScaling = .scaleProportionallyUpOrDown
        addSubview(glyph)

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = Theme.textDim
        subtitleLabel.lineBreakMode = .byTruncatingTail
        addSubview(subtitleLabel)

        ageLabel.font = Theme.contextFont
        ageLabel.textColor = Theme.textFaint
        ageLabel.alignment = .right
        addSubview(ageLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(event: ActivityEvent, now: Date) {
        let tone = event.kind.tone.color
        if let image = NSImage(systemSymbolName: event.kind.glyph, accessibilityDescription: event.kind.label) {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            glyph.image = image.withSymbolConfiguration(config)
            glyph.contentTintColor = tone
        } else {
            glyph.image = nil
        }
        titleLabel.stringValue = event.title

        var subtitle = event.kind.label
        if let repo = event.repo, !repo.isEmpty { subtitle += "  ·  " + repo }
        if let worktree = event.worktree, !worktree.isEmpty { subtitle += "  ⑂ " + worktree }
        else if let pr = event.prNumber { subtitle += "  ·  #\(pr)" }
        if let detail = event.detail, !detail.isEmpty { subtitle += "  ·  " + detail }
        subtitleLabel.stringValue = subtitle

        ageLabel.stringValue = Self.relativeAge(from: event.timestamp, to: now)
        needsLayout = true
    }

    // Compact relative age: "now", "5m", "3h", "2d".
    static func relativeAge(from timestamp: TimeInterval, to now: Date) -> String {
        let delta = max(0, now.timeIntervalSince1970 - timestamp)
        if delta < 60 { return "now" }
        if delta < 3600 { return "\(Int(delta / 60))m" }
        if delta < 86_400 { return "\(Int(delta / 3600))h" }
        return "\(Int(delta / 86_400))d"
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        glyph.frame = NSRect(x: 14, y: (h - 18) / 2, width: 18, height: 18)
        let ageWidth: CGFloat = 46
        ageLabel.frame = NSRect(x: bounds.width - ageWidth - 12, y: (h - 15) / 2, width: ageWidth, height: 15)
        let textLeft: CGFloat = 42
        let textWidth = max(40, ageLabel.frame.minX - 10 - textLeft)
        titleLabel.frame = NSRect(x: textLeft, y: h / 2 + 1, width: textWidth, height: 17)
        subtitleLabel.frame = NSRect(x: textLeft, y: h / 2 - 17, width: textWidth, height: 15)
    }
}

private final class ActivityPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class ActivityFeedController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    // Routing hooks, wired by the AppDelegate.
    var onFocusSession: ((String) -> Void)?
    var onOpenPR: ((String) -> Void)?
    var onOpenAutopilotLog: (() -> Void)?

    private let panel: ActivityPanel
    private let digestLabel = NSTextField(labelWithString: "")
    private let repoFilter = NSPopUpButton(frame: .zero, pullsDown: false)
    private let kindFilter = NSPopUpButton(frame: .zero, pullsDown: false)
    private let emptyLabel = NSTextField(labelWithString: "No fleet activity yet.")
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    // The filtered, ordered rows the table shows.
    private var rows: [ActivityEvent] = []
    // Filter selections (nil = "all").
    private var repoSelection: String?
    private var kindSelection: ActivityKind?

    private static let topBarHeight: CGFloat = 66

    override init() {
        panel = ActivityPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = "Activity"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.delegate = self
        panel.minSize = NSSize(width: 480, height: 300)

        let content = NSView(frame: panel.contentLayoutRect)
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.bg.cgColor
        panel.contentView = content

        digestLabel.font = .systemFont(ofSize: 12, weight: .medium)
        digestLabel.textColor = Theme.textDim
        digestLabel.lineBreakMode = .byTruncatingTail
        digestLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(digestLabel)

        repoFilter.target = self
        repoFilter.action = #selector(filterChanged)
        repoFilter.controlSize = .small
        repoFilter.font = .systemFont(ofSize: 11)
        repoFilter.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(repoFilter)

        kindFilter.target = self
        kindFilter.action = #selector(filterChanged)
        kindFilter.controlSize = .small
        kindFilter.font = .systemFont(ofSize: 11)
        kindFilter.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(kindFilter)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = Theme.textFaint
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        content.addSubview(emptyLabel)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("activity"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 48
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.target = self
        tableView.action = #selector(rowClicked)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)

        NSLayoutConstraint.activate([
            digestLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            digestLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            digestLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),

            repoFilter.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            repoFilter.topAnchor.constraint(equalTo: digestLabel.bottomAnchor, constant: 8),

            kindFilter.leadingAnchor.constraint(equalTo: repoFilter.trailingAnchor, constant: 8),
            kindFilter.centerYAnchor.constraint(equalTo: repoFilter.centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.topBarHeight),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: Self.topBarHeight / 2),
            emptyLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            emptyLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(activityUpdated),
            name: ActivityStore.didUpdate, object: nil
        )
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: - Showing

    func toggle(relativeTo window: NSWindow?) {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            show(relativeTo: window)
        }
    }

    func show(relativeTo window: NSWindow?) {
        reload()
        if !panel.isVisible {
            if let window {
                let frame = window.frame
                let size = panel.frame.size
                panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
            } else {
                panel.center()
            }
        }
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func activityUpdated() {
        guard panel.isVisible else { return }
        reload()
    }

    // MARK: - Data

    private func reload() {
        let all = ActivityStore.shared.events

        // Rebuild the filter menus, preserving the current selection when it
        // still exists among the rows.
        rebuildRepoFilter(from: all)
        rebuildKindFilter(from: all)

        rows = ActivityFeed.ordered(
            ActivityFeed.filter(all, repo: repoSelection, kind: kindSelection)
        )

        let digest = DailyDigest.rollup(events: all, day: Date())
        digestLabel.stringValue = "Today — " + digest.summary

        emptyLabel.isHidden = !rows.isEmpty
        emptyLabel.stringValue = all.isEmpty ? "No fleet activity yet." : "No activity matches the filter."
        tableView.reloadData()
    }

    private func rebuildRepoFilter(from events: [ActivityEvent]) {
        let repos = ActivityFeed.repos(in: events)
        repoFilter.removeAllItems()
        repoFilter.addItem(withTitle: "All repos")
        repoFilter.menu?.addItem(.separator())
        repoFilter.addItems(withTitles: repos)
        if let repoSelection, repos.contains(repoSelection) {
            repoFilter.selectItem(withTitle: repoSelection)
        } else {
            self.repoSelection = nil
            repoFilter.selectItem(at: 0)
        }
    }

    private func rebuildKindFilter(from events: [ActivityEvent]) {
        let kinds = ActivityFeed.kinds(in: events)
        kindFilter.removeAllItems()
        kindFilter.addItem(withTitle: "All kinds")
        kindFilter.menu?.addItem(.separator())
        for kind in kinds {
            let item = NSMenuItem(title: kind.label, action: nil, keyEquivalent: "")
            item.representedObject = kind.rawValue
            kindFilter.menu?.addItem(item)
        }
        if let kindSelection, kinds.contains(kindSelection) {
            kindFilter.selectItem(withTitle: kindSelection.label)
        } else {
            self.kindSelection = nil
            kindFilter.selectItem(at: 0)
        }
    }

    @objc private func filterChanged() {
        repoSelection = repoFilter.indexOfSelectedItem <= 0 ? nil : repoFilter.titleOfSelectedItem
        if kindFilter.indexOfSelectedItem <= 0 {
            kindSelection = nil
        } else if let raw = kindFilter.selectedItem?.representedObject as? String {
            kindSelection = ActivityKind(rawValue: raw)
        }
        reload()
    }

    // MARK: - Actions

    @objc private func rowClicked() {
        let clicked = tableView.clickedRow
        guard rows.indices.contains(clicked) else { return }
        switch rows[clicked].route {
        case .session(let id): onFocusSession?(id)
        case .pr(let url): onOpenPR?(url)
        case .autopilotLog: onOpenAutopilotLog?()
        case .none: NSSound.beep()
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("activityRow")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? ActivityRowView ?? {
            let created = ActivityRowView(frame: .zero)
            created.identifier = identifier
            return created
        }()
        view.configure(event: rows[row], now: Date())
        return view
    }

    // MARK: - Window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        panel.orderOut(nil)
        return false
    }
}
