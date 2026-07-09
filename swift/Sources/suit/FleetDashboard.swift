import Cocoa

// ROADMAP Phase 28 — Fleet-supervision dashboard. Suit signals per-window
// session state (tab dots, title-bar meters) but had no cross-window view of
// the whole fleet. This is the one surface that answers "who needs me right
// now" across every window without hunting through tabs: every live Claude
// session as a row (or Kanban card), fed by ClaudeSessionMonitor across all
// windows, sorted needs-you-first, with per-row steering that routes through
// the Phase 8 send path.

// MARK: - Model

// The four steering verbs a row exposes; the controller reports which was
// tapped and the AppDelegate dispatches it against the hosting pane.
enum FleetAction {
    case focus
    case interrupt
    case cont
    case archive
}

// One dashboard row: a live session projected into display fields plus whether
// a pane actually hosts its pty (only hosted sessions can be steered — the
// others are "done" files that outlived their process, or sessions in a window
// that has since closed the tab).
struct FleetRow {
    let id: String
    let state: ClaudeSessionState
    let title: String        // current-task summary / session name
    let project: String      // git-repo name (worktree's parent), or cwd basename
    let worktree: String?    // worktree dir when the session runs in one
    let branch: String?      // resolved async off the main thread; nil until then
    let contextPct: Double?
    let costUSD: Double?
    let hosted: Bool         // some pane in some window hosts this session's pty
    // Subagent tree (ROADMAP Phase 31): indent depth (0 = a top-level session,
    // 1+ = a nested `isolation: worktree` subagent) and whether this row is a
    // bare subagent worktree with no live session (a checkout Claude Code spun
    // for a subagent but whose session file hasn't appeared / was pruned).
    var depth: Int = 0
    var isBareWorktree: Bool = false
}

// Pure projection of the monitor's sessions into ordered rows, standalone so
// the ordering + field mapping is verifiable without any AppKit. Sorted
// needs-you-first (ClaudeSessionState.sortRank), then most-recently-updated,
// matching the monitor's own sort so the dashboard and the picker agree.
enum FleetModel {
    static func rows(
        sessions: [ClaudeSession],
        hostedIds: Set<String>,
        branch: (String) -> String? = { _ in nil }
    ) -> [FleetRow] {
        sessions
            .sorted {
                ($0.state.sortRank, $1.updatedAt.timeIntervalSince1970)
                    < ($1.state.sortRank, $0.updatedAt.timeIntervalSince1970)
            }
            .map { session in
                let place = projectAndWorktree(cwd: session.cwd)
                return FleetRow(
                    id: session.id,
                    state: session.state,
                    title: session.displayName,
                    project: place.project,
                    worktree: place.worktree,
                    branch: session.cwd.flatMap(branch),
                    contextPct: session.contextPct,
                    costUSD: session.costUSD,
                    hosted: hostedIds.contains(session.id)
                )
            }
    }

    // Splits a session cwd into a repo name + optional worktree name. A task
    // worktree lives at `<repo>/.claude/worktrees/<name>`, so the repo name is
    // the segment before `.claude` and the worktree is `<name>`; anything else
    // shows its own basename as the project with no worktree line.
    static func projectAndWorktree(cwd: String?) -> (project: String, worktree: String?) {
        guard let cwd, !cwd.isEmpty else { return ("—", nil) }
        let parts = (cwd as NSString).pathComponents
        if let marker = parts.firstIndex(of: ".claude"),
           marker + 2 < parts.count,
           parts[marker + 1] == "worktrees" {
            let repo = marker > 0 ? parts[marker - 1] : "—"
            return (repo, parts[marker + 2])
        }
        return ((cwd as NSString).lastPathComponent, nil)
    }

    // Weaves the subagent tree (ROADMAP Phase 31) into the flat session rows:
    // each top-level session keeps its needs-you-first order, immediately
    // followed by its nested `isolation: worktree` subagents (indented via
    // `depth`). A subagent that has its own live session reuses that session's
    // row; one without shows as a bare worktree row. Sessions rendered as a
    // nested child are not repeated at the top level; sessions the tree never
    // saw (e.g. no cwd) fall through as plain roots so none are dropped.
    static func tree(sessionRows: [FleetRow], roots: [SubagentNode]) -> [FleetRow] {
        let nestedSessionIds = Set(
            SubagentTree.flatten(roots)
                .filter { $0.depth > 0 }
                .compactMap { $0.node.sessionId }
        )
        var out: [FleetRow] = []
        for sessionRow in sessionRows {
            if nestedSessionIds.contains(sessionRow.id) { continue }
            guard let root = roots.first(where: { $0.sessionId == sessionRow.id }) else {
                out.append(withDepth(sessionRow, 0))
                continue
            }
            for entry in SubagentTree.flatten([root]) {
                if entry.depth == 0 {
                    out.append(withDepth(sessionRow, 0))
                } else if let sid = entry.node.sessionId,
                          let childRow = sessionRows.first(where: { $0.id == sid }) {
                    out.append(withDepth(childRow, entry.depth))
                } else {
                    out.append(bareRow(for: entry.node, depth: entry.depth))
                }
            }
        }
        return out
    }

    private static func withDepth(_ row: FleetRow, _ depth: Int) -> FleetRow {
        var copy = row
        copy.depth = depth
        return copy
    }

    // A subagent worktree with no live session: shown muted, unsteerable.
    private static func bareRow(for node: SubagentNode, depth: Int) -> FleetRow {
        let place = projectAndWorktree(cwd: node.path)
        return FleetRow(
            id: node.path,
            state: .done,
            title: node.name,
            project: place.project,
            worktree: place.worktree ?? node.name,
            branch: node.branch,
            contextPct: nil,
            costUSD: nil,
            hosted: false,
            depth: depth,
            isBareWorktree: true
        )
    }
}

// MARK: - Kanban

// The optional board layout (Vibe-Kanban model): one card = one worktree = one
// agent. Sessions map onto the three live columns by state; the To-do column is
// present for the model's completeness but sessions never populate it (a session
// exists only once its agent is running), so it renders empty.
enum FleetColumn: Int, CaseIterable {
    case todo
    case running
    case needsYou
    case done

    var title: String {
        switch self {
        case .todo: return "To-do"
        case .running: return "Running"
        case .needsYou: return "Needs you"
        case .done: return "Done"
        }
    }

    static func column(for state: ClaudeSessionState) -> FleetColumn {
        switch state {
        case .working: return .running
        case .needsInput: return .needsYou
        case .done: return .done
        }
    }
}

// MARK: - Views

// A filled status dot, sized to Theme.Metrics.dotSize, colored by session state.
private final class FleetDotView: NSView {
    var color: NSColor = Theme.sessionBusy { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let d = Theme.Metrics.dotSize
        let rect = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }
}

// One list row: dot, a two-line title/place block, trailing context%+cost, and
// the four steering buttons. Reused across reloads via configure(row:).
private final class FleetRowView: NSView {
    // Broadcast selection checkbox (ROADMAP Phase 35): checked rows are the
    // "Broadcast to Selected" target set; disabled on unhosted (unsteerable) rows.
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let dot = FleetDotView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let placeLabel = NSTextField(labelWithString: "")
    private let metricsLabel = NSTextField(labelWithString: "")
    private let focusButton = NSButton()
    private let interruptButton = NSButton()
    private let continueButton = NSButton()
    private let archiveButton = NSButton()

    var onAction: ((FleetAction) -> Void)?
    var onToggleCheck: ((Bool) -> Void)?
    // Cost budget guardrails (ROADMAP Phase 42): right-click ▸ Set Budget… on a
    // steerable row. `rowId` is the session id the override keys on.
    var onSetBudget: ((String) -> Void)?
    private var rowId: String?
    private var isBareRow = false

    // Subagent-tree indent (ROADMAP Phase 31): 0 = a top-level session, 1+ a
    // nested subagent; bare worktrees hide their (unsteerable) buttons.
    private var depth = 0
    private var isBareWorktree = false
    private static let indentPerLevel: CGFloat = 22

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        checkbox.target = self
        checkbox.action = #selector(checkToggled)
        addSubview(checkbox)

        addSubview(dot)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        placeLabel.font = .systemFont(ofSize: 11)
        placeLabel.textColor = Theme.textDim
        placeLabel.lineBreakMode = .byTruncatingTail
        addSubview(placeLabel)

        metricsLabel.font = Theme.contextFont
        metricsLabel.textColor = Theme.textDim
        metricsLabel.alignment = .right
        addSubview(metricsLabel)

        configureButton(focusButton, title: "Focus", action: #selector(focusTapped))
        configureButton(interruptButton, title: "Esc", action: #selector(interruptTapped))
        configureButton(continueButton, title: "Continue", action: #selector(continueTapped))
        configureButton(archiveButton, title: "Stop", action: #selector(archiveTapped))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureButton(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.target = self
        button.action = action
        addSubview(button)
    }

    func configure(row: FleetRow, checked: Bool) {
        depth = row.depth
        isBareWorktree = row.isBareWorktree
        rowId = row.id
        isBareRow = row.isBareWorktree
        // Only a hosted (steerable) session can be a broadcast target; a bare
        // subagent worktree has no session to steer.
        checkbox.isEnabled = row.hosted && !isBareWorktree
        checkbox.state = (checked && checkbox.isEnabled) ? .on : .off
        // A bare subagent worktree (no live session) reads muted; a live row
        // uses the session-state dot color.
        dot.color = isBareWorktree ? Theme.textFaint : row.state.color
        titleLabel.stringValue = row.title
        titleLabel.textColor = isBareWorktree ? Theme.textDim : Theme.textPrimary
        var place = isBareWorktree ? "subagent" : row.project
        if !isBareWorktree, let worktree = row.worktree { place += " · " + worktree }
        if let branch = row.branch, !branch.isEmpty { place += "  ⑂ " + branch }
        if !isBareWorktree { place += "  ·  " + row.state.label }
        placeLabel.stringValue = place

        var metrics: [String] = []
        if let ctx = row.contextPct { metrics.append(String(format: "%.0f%% ctx", ctx)) }
        if let cost = row.costUSD, cost > 0 { metrics.append(String(format: "$%.2f", cost)) }
        metricsLabel.stringValue = metrics.joined(separator: "   ")

        // A bare worktree has no session to steer; hide its buttons entirely.
        // Otherwise only a hosted session's pty can be written to (Focus also
        // needs the hosting tab); an unhosted "done" row shows greyed buttons.
        for button in [focusButton, interruptButton, continueButton, archiveButton] {
            button.isHidden = isBareWorktree
            button.isEnabled = !isBareWorktree && row.hosted
        }
        // Continue only makes sense once a session is idle/done.
        continueButton.isEnabled = !isBareWorktree && row.hosted && row.state != .working
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let indent = CGFloat(depth) * Self.indentPerLevel
        checkbox.sizeToFit()
        checkbox.frame = NSRect(x: 12, y: (h - 18) / 2, width: 18, height: 18)
        dot.frame = NSRect(x: 34 + indent, y: (h - 12) / 2, width: 12, height: 12)

        // Buttons pinned right, in reverse order (hidden ones take no space).
        var x = bounds.width - 12
        for button in [archiveButton, continueButton, interruptButton, focusButton] where !button.isHidden {
            button.sizeToFit()
            let w = max(button.frame.width, 40)
            x -= w
            button.frame = NSRect(x: x, y: (h - 20) / 2, width: w, height: 20)
            x -= 6
        }
        let buttonsLeft = x

        let metricsWidth: CGFloat = 130
        metricsLabel.frame = NSRect(x: buttonsLeft - metricsWidth - 12, y: (h - 15) / 2, width: metricsWidth, height: 15)

        let textLeft: CGFloat = 54 + indent
        let textRight = metricsLabel.frame.minX - 10
        let textWidth = max(40, textRight - textLeft)
        titleLabel.frame = NSRect(x: textLeft, y: h / 2 + 1, width: textWidth, height: 17)
        placeLabel.frame = NSRect(x: textLeft, y: h / 2 - 18, width: textWidth, height: 15)
    }

    @objc private func focusTapped() { onAction?(.focus) }
    @objc private func interruptTapped() { onAction?(.interrupt) }
    @objc private func continueTapped() { onAction?(.cont) }
    @objc private func archiveTapped() { onAction?(.archive) }
    @objc private func checkToggled() { onToggleCheck?(checkbox.state == .on) }

    // Right-click ▸ Set Budget… (ROADMAP Phase 42). A bare subagent worktree has
    // no session to budget, so it gets no menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard !isBareRow, rowId != nil else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Set Budget…", action: #selector(setBudgetTapped), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func setBudgetTapped() {
        if let rowId { onSetBudget?(rowId) }
    }
}

// A Kanban card: a compact clickable tile that focuses the session on click.
private final class FleetCardView: NSView {
    private let dot = FleetDotView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let placeLabel = NSTextField(labelWithString: "")
    private var hovering = false
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = Theme.hover.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Theme.hairline.cgColor

        addSubview(dot)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        placeLabel.font = .systemFont(ofSize: 10.5)
        placeLabel.textColor = Theme.textDim
        placeLabel.lineBreakMode = .byTruncatingTail
        addSubview(placeLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(row: FleetRow) {
        dot.color = row.state.color
        titleLabel.stringValue = row.title
        var place = row.worktree ?? row.project
        if let branch = row.branch, !branch.isEmpty { place = branch }
        placeLabel.stringValue = place
    }

    override func layout() {
        super.layout()
        dot.frame = NSRect(x: 8, y: bounds.height - 20, width: 10, height: 10)
        titleLabel.frame = NSRect(x: 22, y: bounds.height - 22, width: bounds.width - 30, height: 16)
        placeLabel.frame = NSRect(x: 8, y: 6, width: bounds.width - 16, height: 14)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        layer?.borderColor = Theme.accent.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        layer?.borderColor = Theme.hairline.cgColor
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - Controller

private final class FleetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// The dashboard controller: a floating panel over all windows, refreshed on
// ClaudeSessionMonitor updates while it's visible. List and Board are two
// layouts of the same `rows`; the segmented control swaps between them.
final class FleetDashboardController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    // Dispatch hooks, wired by the AppDelegate.
    var onFocus: ((String) -> Void)?
    var onInterrupt: ((String) -> Void)?
    var onContinue: ((String) -> Void)?
    var onArchive: ((String) -> Void)?
    // Broadcast (ROADMAP Phase 35): fan one instruction across a scope of
    // sessions — the checked rows, or every live one.
    var onBroadcast: ((Broadcast.Scope) -> Void)?
    // Cost budget guardrails (ROADMAP Phase 42): "Set Budget…" on a row — a
    // per-session dollar override.
    var onSetBudget: ((String) -> Void)?
    // The set of session ids some pane currently hosts (steerable rows).
    var hostedIds: (() -> Set<String>)?

    private let panel: FleetPanel
    private let segmented = NSSegmentedControl(labels: ["List", "Board"], trackingMode: .selectOne, target: nil, action: nil)
    private let broadcastAllButton = NSButton()
    private let broadcastSelectedButton = NSButton()
    private let countLabel = NSTextField(labelWithString: "")
    // Broadcast selection: the row ids checked in the List view; pruned to live
    // rows on every reload so a finished session's check can't linger.
    private var checkedIds: Set<String> = []
    private let emptyLabel = NSTextField(labelWithString: "No active Claude sessions.")
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let boardScroll = NSScrollView()
    private let boardView = NSView()

    private var rows: [FleetRow] = []
    // Branch lookups are cached by cwd; an empty string marks "resolved, not a
    // repo" so we don't re-shell every reload.
    private var branchCache: [String: String] = [:]
    private var branchInFlight: Set<String> = []
    // Subagent tree (ROADMAP Phase 31): the repo's worktree list, cached by
    // cwd (all cwds in one repo resolve to the same set). Re-shelled off the
    // main thread the first time a cwd is seen; a fresh reload lands the
    // subagents (and drops the ones whose worktrees Claude Code has removed).
    private var worktreesCache: [String: [SubagentTreeWorktree]] = [:]
    private var worktreesInFlight: Set<String> = []

    private static let topBarHeight: CGFloat = 44

    override init() {
        panel = FleetPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = "Fleet"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.delegate = self
        panel.minSize = NSSize(width: 520, height: 300)

        let content = NSView(frame: panel.contentLayoutRect)
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.bg.cgColor
        panel.contentView = content

        segmented.selectedSegment = 0
        segmented.target = self
        segmented.action = #selector(layoutModeChanged)
        segmented.controlSize = .small
        segmented.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(segmented)

        // Broadcast controls (Phase 35): "All" fans to every live session, the
        // selected button to the checked rows (its title carries the count).
        configureBroadcastButton(broadcastAllButton, title: "Broadcast All", action: #selector(broadcastAllTapped))
        configureBroadcastButton(broadcastSelectedButton, title: "Broadcast Selected", action: #selector(broadcastSelectedTapped))
        content.addSubview(broadcastAllButton)
        content.addSubview(broadcastSelectedButton)

        countLabel.font = Theme.usageFont
        countLabel.textColor = Theme.textDim
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(countLabel)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = Theme.textFaint
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        content.addSubview(emptyLabel)

        // List
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("fleet"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 56
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)

        // Board
        boardView.wantsLayer = true
        boardScroll.documentView = boardView
        boardScroll.hasHorizontalScroller = true
        boardScroll.drawsBackground = false
        boardScroll.isHidden = true
        boardScroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(boardScroll)

        NSLayoutConstraint.activate([
            segmented.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            segmented.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),

            broadcastAllButton.leadingAnchor.constraint(equalTo: segmented.trailingAnchor, constant: 12),
            broadcastAllButton.centerYAnchor.constraint(equalTo: segmented.centerYAnchor),

            broadcastSelectedButton.leadingAnchor.constraint(equalTo: broadcastAllButton.trailingAnchor, constant: 6),
            broadcastSelectedButton.centerYAnchor.constraint(equalTo: segmented.centerYAnchor),

            countLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            countLabel.centerYAnchor.constraint(equalTo: segmented.centerYAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: broadcastSelectedButton.trailingAnchor, constant: 8),

            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.topBarHeight),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            boardScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            boardScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            boardScroll.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.topBarHeight),
            boardScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: -Self.topBarHeight / 2),
            emptyLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            emptyLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionsUpdated),
            name: ClaudeSessionMonitor.didUpdate, object: nil
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
                panel.setFrameOrigin(NSPoint(
                    x: frame.midX - size.width / 2,
                    y: frame.midY - size.height / 2
                ))
            } else {
                panel.center()
            }
        }
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func sessionsUpdated() {
        guard panel.isVisible else { return }
        reload()
    }

    // MARK: - Data

    private func reload() {
        let sessions = ClaudeSessionMonitor.shared.sessions
        let hosted = hostedIds?() ?? []
        let sessionRows = FleetModel.rows(sessions: sessions, hostedIds: hosted) { [weak self] cwd in
            self?.branch(forCwd: cwd)
        }

        // Subagent tree (ROADMAP Phase 31): nest each session's
        // `isolation: worktree` subagents under it, discovered from the repo's
        // worktree list. Pruning is implicit — a removed worktree simply drops
        // out of the gathered list, so its row disappears.
        let treeSessions: [SubagentTreeSession] = sessions.compactMap { session in
            guard let cwd = session.cwd, !cwd.isEmpty else { return nil }
            return SubagentTreeSession(id: session.id, cwd: cwd, state: session.state.label)
        }
        let worktrees = gatheredWorktrees(for: sessions)
        let roots = SubagentTree.build(sessions: treeSessions, worktrees: worktrees)
        rows = FleetModel.tree(sessionRows: sessionRows, roots: roots)

        // Broadcast (ROADMAP Phase 35): drop checks for rows that are gone or no
        // longer steerable, so a finished session's check can't linger.
        let steerable = Set(rows.filter { $0.hosted }.map { $0.id })
        checkedIds.formIntersection(steerable)

        let sessionCount = rows.filter { !$0.isBareWorktree }.count
        let needsYou = rows.filter { $0.state == .needsInput }.count
        countLabel.stringValue = rows.isEmpty
            ? ""
            : "\(sessionCount) session\(sessionCount == 1 ? "" : "s")" + (needsYou > 0 ? " · \(needsYou) need you" : "")
        emptyLabel.isHidden = !rows.isEmpty
        refreshBroadcastButtons()

        tableView.reloadData()
        if !boardScroll.isHidden { rebuildBoard() }
    }

    // Cached branch lookup: returns the cached value immediately, kicking off a
    // one-shot `git rev-parse` off the main thread the first time a cwd is seen
    // and reloading when it lands. Nil until resolved (or when not a repo).
    private func branch(forCwd cwd: String) -> String? {
        if let cached = branchCache[cwd] { return cached.isEmpty ? nil : cached }
        guard !branchInFlight.contains(cwd) else { return nil }
        branchInFlight.insert(cwd)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let value = Self.gitBranch(cwd: cwd) ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.branchInFlight.remove(cwd)
                self.branchCache[cwd] = value
                if self.panel.isVisible { self.reload() }
            }
        }
        return nil
    }

    private static func gitBranch(cwd: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd, "symbolic-ref", "--short", "-q", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let branch = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }

    // The union of every session repo's worktrees, deduped by path — the raw
    // material the subagent tree nests. Each distinct session cwd resolves its
    // repo's worktrees once (cached); uncached cwds kick off an off-thread
    // `git worktree list` and reload when they land.
    private func gatheredWorktrees(for sessions: [ClaudeSession]) -> [SubagentTreeWorktree] {
        var byPath: [String: SubagentTreeWorktree] = [:]
        for session in sessions {
            guard let cwd = session.cwd, !cwd.isEmpty else { continue }
            for worktree in worktrees(forCwd: cwd) {
                byPath[worktree.path] = worktree
            }
        }
        return Array(byPath.values)
    }

    private func worktrees(forCwd cwd: String) -> [SubagentTreeWorktree] {
        if let cached = worktreesCache[cwd] { return cached }
        guard !worktreesInFlight.contains(cwd) else { return [] }
        worktreesInFlight.insert(cwd)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let value = Self.listWorktrees(cwd: cwd)
            DispatchQueue.main.async {
                guard let self else { return }
                self.worktreesInFlight.remove(cwd)
                self.worktreesCache[cwd] = value
                if self.panel.isVisible { self.reload() }
            }
        }
        return []
    }

    // Parses `git worktree list --porcelain` into (path, branch?) entries. The
    // porcelain form is blocks of `worktree <path>` / optional `branch
    // refs/heads/<name>` / `detached`, separated by blank lines.
    private static func listWorktrees(cwd: String) -> [SubagentTreeWorktree] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd, "worktree", "list", "--porcelain"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        let text = String(decoding: data, as: UTF8.self)

        var result: [SubagentTreeWorktree] = []
        var path: String?
        var branch: String?
        func flush() {
            if let path { result.append(SubagentTreeWorktree(path: path, branch: branch)) }
            path = nil
            branch = nil
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                flush()
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch refs/heads/") {
                branch = String(line.dropFirst("branch refs/heads/".count))
            }
        }
        flush()
        return result
    }

    // MARK: - Layout mode

    @objc private func layoutModeChanged() {
        let board = segmented.selectedSegment == 1
        boardScroll.isHidden = !board
        scrollView.isHidden = board
        if board { rebuildBoard() }
    }

    private func rebuildBoard() {
        boardView.subviews.forEach { $0.removeFromSuperview() }

        let columnWidth: CGFloat = 200
        let gap: CGFloat = 12
        let cardHeight: CGFloat = 56
        let cardGap: CGFloat = 8
        let headerHeight: CGFloat = 26
        let columns = FleetColumn.allCases
        let totalWidth = CGFloat(columns.count) * columnWidth + CGFloat(columns.count + 1) * gap
        let viewHeight = boardScroll.contentView.bounds.height
        boardView.frame = NSRect(x: 0, y: 0, width: max(totalWidth, boardScroll.bounds.width), height: viewHeight)

        for (index, column) in columns.enumerated() {
            let x = gap + CGFloat(index) * (columnWidth + gap)

            let header = NSTextField(labelWithString: column.title.uppercased())
            header.font = Theme.captionFont
            header.textColor = Theme.textDim
            header.frame = NSRect(x: x, y: viewHeight - headerHeight, width: columnWidth, height: 16)
            boardView.addSubview(header)

            let cards = rows.filter { !$0.isBareWorktree && FleetColumn.column(for: $0.state) == column }
            var y = viewHeight - headerHeight - cardHeight
            for row in cards {
                let card = FleetCardView(frame: NSRect(x: x, y: y, width: columnWidth, height: cardHeight))
                card.configure(row: row)
                card.onClick = { [weak self] in self?.onFocus?(row.id) }
                boardView.addSubview(card)
                y -= cardHeight + cardGap
            }
        }
    }

    // MARK: - Actions

    private func dispatch(_ action: FleetAction, id: String) {
        switch action {
        case .focus: onFocus?(id)
        case .interrupt: onInterrupt?(id)
        case .cont: onContinue?(id)
        case .archive: onArchive?(id)
        }
    }

    @objc private func rowDoubleClicked() {
        let clicked = tableView.clickedRow
        guard rows.indices.contains(clicked) else { return }
        let row = rows[clicked]
        // Bare subagent worktrees have no session to focus.
        guard !row.isBareWorktree else { return }
        onFocus?(row.id)
    }

    // MARK: - Broadcast

    private func configureBroadcastButton(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    // Enable "All" whenever any steerable session exists, and "Selected" only
    // when checked rows remain after pruning; the latter's title carries the
    // live count so the button reads "Broadcast Selected (2)".
    private func refreshBroadcastButtons() {
        let hostedCount = rows.filter { $0.hosted }.count
        broadcastAllButton.isEnabled = hostedCount > 0
        let selectedCount = checkedIds.count
        broadcastSelectedButton.isEnabled = selectedCount > 0
        broadcastSelectedButton.title = selectedCount > 0 ? "Broadcast Selected (\(selectedCount))" : "Broadcast Selected"
    }

    @objc private func broadcastAllTapped() {
        onBroadcast?(.allLive)
    }

    @objc private func broadcastSelectedTapped() {
        guard !checkedIds.isEmpty else { NSSound.beep(); return }
        onBroadcast?(.selected(checkedIds))
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("fleetRow")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? FleetRowView ?? {
            let created = FleetRowView(frame: .zero)
            created.identifier = identifier
            return created
        }()
        let fleetRow = rows[row]
        view.configure(row: fleetRow, checked: checkedIds.contains(fleetRow.id))
        view.onAction = { [weak self] action in self?.dispatch(action, id: fleetRow.id) }
        view.onSetBudget = { [weak self] id in self?.onSetBudget?(id) }
        view.onToggleCheck = { [weak self] checked in
            guard let self else { return }
            if checked { self.checkedIds.insert(fleetRow.id) } else { self.checkedIds.remove(fleetRow.id) }
            self.refreshBroadcastButtons()
        }
        return view
    }

    // MARK: - Window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        panel.orderOut(nil)
        return false
    }
}
