import Cocoa

// The commit-graph pane: a read-only viewer tab rendering
// `git log --all --date-order` as a clickable DAG — nodes in lanes with edges
// for parents/merges/forks, branch/tag/HEAD badges on tips, age-tinted like the
// blame gutter. The lane assignment + edge routing is the pure CommitGraph
// core; this file is the off-thread load and the custom-view drawing. Clicking
// a node opens that commit's diff in the window's diff tab; the graph refreshes
// on GitStatusMonitor ref events (commits, branch and worktree ops).
final class CommitGraphPaneContent: NSObject, PaneContent {
    weak var pane: Pane?
    weak var tab: Tab?

    private let scrollView = NSScrollView()
    private let graphView = CommitGraphView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let loadMoreButton = NSButton(title: "Load more", target: nil, action: nil)
    private let container = NSView(frame: .zero)

    private(set) var gitRoot: String?
    // Virtualization: the current node cap. "Load more" grows it so large
    // histories stay responsive without hiding that there's more to see.
    private var nodeCap = 500
    private static let capStep = 500
    private var background = Theme.bg
    // Coalesce ref-event reloads so a burst of FS events is one git call.
    private var reloadScheduled = false

    override init() {
        super.init()

        container.wantsLayer = true

        graphView.onSelectCommit = { [weak self] sha in
            guard let self, let root = self.gitRoot else { return }
            self.pane?.openCommitDiff(sha: sha, root: root)
        }

        scrollView.documentView = graphView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = background
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        statusLabel.font = Theme.contextFont
        statusLabel.textColor = Theme.textFaint
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)

        loadMoreButton.bezelStyle = .rounded
        loadMoreButton.controlSize = .small
        loadMoreButton.font = .systemFont(ofSize: 11)
        loadMoreButton.target = self
        loadMoreButton.action = #selector(loadMore)
        loadMoreButton.isHidden = true
        loadMoreButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(loadMoreButton)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -28),

            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),

            loadMoreButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            loadMoreButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(gitDidUpdate),
            name: GitStatusMonitor.didUpdate, object: nil
        )
    }

    // MARK: - PaneContent

    var view: NSView { container }
    var focusTarget: NSView { graphView }
    var defaultTitle: String { "Commit Graph" }
    var initialBackgroundColor: NSColor { background }
    var workingDirectory: String? { gitRoot }

    func applyBackground(_ color: NSColor) {
        background = color
        container.layer?.backgroundColor = color.cgColor
        scrollView.backgroundColor = color
        graphView.background = color
        graphView.needsDisplay = true
    }

    // Live theme switch: re-tint the status label (baked once) and repaint the
    // graph, which reads its node/text tokens live at draw time.
    func reapplyTheme() {
        statusLabel.textColor = Theme.textFaint
        graphView.needsDisplay = true
    }

    func teardown() {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Loading

    // Points the pane at a repo and (re)loads. Instantiating the monitor keeps
    // the ref-watcher running so `gitDidUpdate` fires on commit/branch ops.
    func load(root: String) {
        gitRoot = root
        _ = GitStatusMonitor.shared(forRoot: root)
        tab?.contentTitleDidChange("Commit Graph — \((root as NSString).lastPathComponent)")
        reload()
    }

    @objc private func loadMore() {
        nodeCap += Self.capStep
        reload()
    }

    @objc private func gitDidUpdate() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.reloadScheduled = false
            self?.reload()
        }
    }

    private func reload() {
        guard let root = gitRoot else { return }
        let cap = nodeCap
        // Ask for one extra so we can tell whether more history exists.
        let arguments = ["-C", root] + CommitGraph.logArguments + ["-n", "\(cap + 1)"]
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let output = runProcess("/usr/bin/git", arguments) ?? ""
            let commits = CommitGraph.parse(output)
            let hasMore = commits.count > cap
            let layout = CommitGraph.layout(commits, maxNodes: cap)
            DispatchQueue.main.async {
                guard let self, self.gitRoot == root else { return }
                self.graphView.background = self.background
                self.graphView.setLayout(layout)
                self.loadMoreButton.isHidden = !hasMore
                let shown = layout.nodes.count
                self.statusLabel.stringValue = hasMore
                    ? "\(shown) commits (more available)"
                    : "\(shown) commit\(shown == 1 ? "" : "s")"
            }
        }
    }
}

// The scrolling canvas: draws edges, nodes, ref badges and the commit line for
// each row, and maps clicks back to a commit sha. Flipped so row 0 is at top.
private final class CommitGraphView: NSView {
    var onSelectCommit: ((String) -> Void)?
    var background = Theme.bg

    private var layout = CommitGraphLayoutEmpty
    private var now = Date().timeIntervalSince1970

    // Geometry.
    private static let rowHeight: CGFloat = 24
    private static let laneWidth: CGFloat = 14
    private static let nodeRadius: CGFloat = 4
    private static let leftPad: CGFloat = 14
    private static let textGap: CGFloat = 12
    private static let minWidth: CGFloat = 480

    // A small lane palette (Theme has no dedicated lane hues); the HEAD / tip
    // nodes override with the accent.
    private static let laneColors: [NSColor] = [
        NSColor(calibratedRed: 0.85, green: 0.60, blue: 0.24, alpha: 1), // amber
        NSColor(calibratedRed: 0.34, green: 0.70, blue: 0.42, alpha: 1), // green
        NSColor(calibratedRed: 0.36, green: 0.60, blue: 0.90, alpha: 1), // blue
        NSColor(calibratedRed: 0.80, green: 0.45, blue: 0.75, alpha: 1), // magenta
        NSColor(calibratedRed: 0.45, green: 0.72, blue: 0.74, alpha: 1), // teal
        NSColor(calibratedRed: 0.82, green: 0.52, blue: 0.40, alpha: 1), // clay
    ]

    override var isFlipped: Bool { true }

    func setLayout(_ layout: CommitGraphLayout) {
        self.layout = layout
        now = Date().timeIntervalSince1970
        let gutter = Self.leftPad + CGFloat(layout.laneCount) * Self.laneWidth
        let height = max(CGFloat(layout.nodes.count) * Self.rowHeight + 8, 1)
        let width = max(Self.minWidth, gutter + 320)
        setFrameSize(NSSize(width: width, height: height))
        needsDisplay = true
    }

    private func laneColor(_ lane: Int) -> NSColor {
        Self.laneColors[lane % Self.laneColors.count]
    }

    private func x(ofLane lane: Int) -> CGFloat {
        Self.leftPad + CGFloat(lane) * Self.laneWidth + Self.laneWidth / 2
    }

    private func y(ofRow row: Int) -> CGFloat {
        CGFloat(row) * Self.rowHeight + Self.rowHeight / 2 + 4
    }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        dirtyRect.fill()
        guard !layout.nodes.isEmpty else { return }

        // Edges first, so nodes sit on top.
        for edge in layout.edges {
            let start = NSPoint(x: x(ofLane: edge.fromLane), y: y(ofRow: edge.fromRow))
            let end = NSPoint(x: x(ofLane: edge.toLane), y: y(ofRow: edge.toRow))
            let path = NSBezierPath()
            path.move(to: start)
            if edge.fromLane == edge.toLane {
                path.line(to: end)
            } else {
                // A vertical S-curve when the edge changes lanes.
                let midY = (start.y + end.y) / 2
                path.curve(to: end,
                           controlPoint1: NSPoint(x: start.x, y: midY),
                           controlPoint2: NSPoint(x: end.x, y: midY))
            }
            laneColor(edge.toLane).withAlphaComponent(0.65).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }

        let gutter = Self.leftPad + CGFloat(layout.laneCount) * Self.laneWidth
        let textLeft = gutter + Self.textGap

        for node in layout.nodes {
            let center = NSPoint(x: x(ofLane: node.lane), y: y(ofRow: node.row))
            let highlight = node.isHead || node.isCurrentBranchTip
            let dot = NSRect(
                x: center.x - Self.nodeRadius, y: center.y - Self.nodeRadius,
                width: Self.nodeRadius * 2, height: Self.nodeRadius * 2
            )
            let circle = NSBezierPath(ovalIn: dot)
            (highlight ? Theme.accent : laneColor(node.lane)).setFill()
            circle.fill()
            if highlight {
                Theme.accent.setStroke()
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: -2, dy: -2))
                ring.lineWidth = 1.5
                ring.stroke()
            }

            var cursor = textLeft
            let rowY = center.y

            // Ref badges (HEAD / branches / tags) before the subject.
            for ref in node.refs {
                cursor = drawBadge(ref, at: cursor, centerY: rowY)
            }

            // Short sha (monospace, faint).
            let shaAttrs: [NSAttributedString.Key: Any] = [
                .font: Theme.contextFont,
                .foregroundColor: Theme.textFaint,
            ]
            let sha = node.shortSha as NSString
            let shaSize = sha.size(withAttributes: shaAttrs)
            sha.draw(at: NSPoint(x: cursor, y: rowY - shaSize.height / 2), withAttributes: shaAttrs)
            cursor += shaSize.width + 8

            // Age (tinted like blame) then the subject fills the rest.
            let age = Self.relativeAge(from: node.timestamp, now: now) as NSString
            let ageAttrs: [NSAttributedString.Key: Any] = [
                .font: Theme.contextFont,
                .foregroundColor: GitAgeTint.color(forTime: TimeInterval(node.timestamp), now: now),
            ]
            let ageSize = age.size(withAttributes: ageAttrs)

            let subjectRight = bounds.width - 8 - ageSize.width - 10
            let subjectAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: highlight ? Theme.textPrimary : Theme.textDim,
            ]
            let subjectRect = NSRect(x: cursor, y: rowY - 8, width: max(20, subjectRight - cursor), height: 16)
            drawTruncated(node.subject, in: subjectRect, attrs: subjectAttrs)

            age.draw(at: NSPoint(x: bounds.width - 8 - ageSize.width, y: rowY - ageSize.height / 2), withAttributes: ageAttrs)
        }
    }

    // Draws a rounded ref pill and returns the x cursor past it.
    private func drawBadge(_ ref: CommitRef, at x: CGFloat, centerY: CGFloat) -> CGFloat {
        let color: NSColor
        switch ref.kind {
        case .head, .currentBranch: color = Theme.accent
        case .branch: color = Theme.sessionDone
        case .remoteBranch: color = Theme.textDim
        case .tag: color = Theme.sessionNeedsInput
        }
        let text = ref.name as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: Theme.bg,
        ]
        let size = text.size(withAttributes: attrs)
        let pad: CGFloat = 5
        let pill = NSRect(x: x, y: centerY - 8, width: ceil(size.width) + pad * 2, height: 16)
        let path = NSBezierPath(roundedRect: pill, xRadius: 3, yRadius: 3)
        color.setFill()
        path.fill()
        text.draw(at: NSPoint(x: x + pad, y: centerY - size.height / 2), withAttributes: attrs)
        return pill.maxX + 5
    }

    private func drawTruncated(_ string: String, in rect: NSRect, attrs: [NSAttributedString.Key: Any]) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        var a = attrs
        a[.paragraphStyle] = style
        (string as NSString).draw(in: rect, withAttributes: a)
    }

    static func relativeAge(from timestamp: Int, now: TimeInterval) -> String {
        let seconds = max(0, now - TimeInterval(timestamp))
        let day = 86_400.0
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < day { return "\(Int(seconds / 3_600))h" }
        if seconds < day * 30 { return "\(Int(seconds / day))d" }
        if seconds < day * 365 { return "\(Int(seconds / (day * 30)))mo" }
        return "\(Int(seconds / (day * 365)))y"
    }

    // MARK: - Click → open commit diff

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = Int((point.y - 4) / Self.rowHeight)
        guard row >= 0, row < layout.nodes.count else { return }
        onSelectCommit?(layout.nodes[row].sha)
    }
}

// An empty layout so the view has a valid initial value.
private let CommitGraphLayoutEmpty = CommitGraphLayout(nodes: [], edges: [], laneCount: 1, hasTruncatedParents: false)
