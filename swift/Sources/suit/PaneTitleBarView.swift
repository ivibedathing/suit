import Cocoa

// The Ask · Plan · Agent mode control (ROADMAP Phase 26): a compact three-way
// segmented control that lives on a Claude tab's title bar. Selecting a segment
// asks the pane to switch Claude's permission mode (see ClaudeModeControl). It
// draws its own segments rather than using NSSegmentedControl so it reads as
// chrome and stays legible at the 26pt header height.
final class ModeControlView: NSView {
    // Called with the picked mode when a segment is clicked.
    var onSelect: ((ClaudeMode) -> Void)?

    private static let modes = ClaudeMode.displayOrder
    private static let font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
    private static let segmentPadding: CGFloat = 7
    private static let height: CGFloat = 16

    private var selected: ClaudeMode = .agent
    // Left edges + widths of each segment, recomputed on selection change so
    // hit-testing and drawing agree.
    private var segmentRects: [NSRect] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // The width this control wants — the sum of every segment plus a hairline
    // between them — so the title bar can reserve exactly that.
    var fittingWidth: CGFloat {
        Self.modes.reduce(0) { $0 + segmentWidth(for: $1) } + CGFloat(Self.modes.count - 1)
    }

    func setSelected(_ mode: ClaudeMode) {
        guard mode != selected else { return }
        selected = mode
        needsDisplay = true
    }

    private func segmentWidth(for mode: ClaudeMode) -> CGFloat {
        let size = (mode.label as NSString).size(withAttributes: [.font: Self.font])
        return ceil(size.width) + Self.segmentPadding * 2
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        segmentRects = Self.modes.map { mode in
            let w = segmentWidth(for: mode)
            let rect = NSRect(x: x, y: (bounds.height - Self.height) / 2, width: w, height: Self.height)
            x += w + 1
            return rect
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard segmentRects.count == Self.modes.count else { return }
        for (index, mode) in Self.modes.enumerated() {
            let rect = segmentRects[index]
            let isSelected = mode == selected
            let full = NSRect(x: rect.minX, y: 0, width: rect.width, height: bounds.height)
            let path = NSBezierPath(roundedRect: full.insetBy(dx: 0.5, dy: 3), xRadius: 3, yRadius: 3)
            if isSelected {
                Theme.accent.withAlphaComponent(0.9).setFill()
                path.fill()
            } else {
                Theme.overlay.setFill()
                path.fill()
            }
            let color: NSColor = isSelected ? Theme.bg : Theme.textDim
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color]
            let size = (mode.label as NSString).size(withAttributes: attrs)
            let point = NSPoint(x: rect.midX - size.width / 2, y: (bounds.height - size.height) / 2)
            (mode.label as NSString).draw(at: point, withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = segmentRects.firstIndex(where: { $0.insetBy(dx: -0.5, dy: -3).contains(point) }) else { return }
        onSelect?(Self.modes[index])
    }

    // The tooltip explains the transient nature of the reading.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        toolTip = "Claude mode: Ask · Plan · Agent (Shift+Tab)"
    }
}

// The slim viewport header (browser-tab model): icon + title on the left,
// Claude session dot and context % on the right. It labels what the pane is
// showing — the strip is the single source of tabs — and doubles as the drag
// handle for rearranging whole panes.
final class PaneTitleBarView: NSView, NSDraggingSource {
    weak var pane: Pane?
    private let iconView = NSImageView(frame: .zero)
    private let label = NSTextField(labelWithString: "")
    private let statusDot = NSView(frame: .zero)
    private let contextLabel = NSTextField(labelWithString: "")
    private let modeControl = ModeControlView(frame: .zero)
    private var mouseDownLocation: NSPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Flat bar chrome (Phase 11), replacing the .titlebar vibrancy.
        wantsLayer = true
        layer?.backgroundColor = Theme.barChrome.cgColor
        layer?.cornerRadius = Theme.Metrics.paneCornerRadius
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = Theme.textDim
        addSubview(iconView)

        label.font = Theme.paneHeaderFont
        label.textColor = Theme.textDim
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3
        statusDot.isHidden = true
        addSubview(statusDot)

        contextLabel.font = Theme.contextFont
        contextLabel.textColor = Theme.textFaint
        contextLabel.isHidden = true
        addSubview(contextLabel)

        modeControl.isHidden = true
        modeControl.onSelect = { [weak self] mode in
            self?.pane?.switchClaudeMode(to: mode)
        }
        addSubview(modeControl)
    }

    // Phase 27 — the context meter reads as a one-tap /compact whenever a live
    // session is shown here; a pointing-hand cursor advertises the affordance.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard !contextLabel.isHidden, pane?.canCompactContextSession == true else { return }
        addCursorRect(contextLabel.frame.insetBy(dx: -4, dy: -4), cursor: .pointingHand)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var title: String = "" {
        didSet { label.stringValue = title }
    }

    var icon: NSImage? {
        didSet { iconView.image = icon }
    }

    // Set once the pane's shell process has exited; nil while it's still running.
    var exitStatus: ProcessExitStatus? {
        didSet { updateStatusDot() }
    }

    // The Claude session state of the tab shown here (ROADMAP Phase 4's
    // attention routing): ● busy (orange), ◐ needs-input (yellow, pulsing so
    // it's findable at a glance without stealing focus), ✓ done (green). The
    // exit-status dot wins once the shell is gone.
    var sessionState: ClaudeSessionState? {
        didSet {
            if sessionState != oldValue { updateStatusDot() }
        }
    }

    // The Claude permission mode this tab is in (ROADMAP Phase 26): shows the
    // Ask · Plan · Agent control when the tab hosts a live Claude session, hidden
    // otherwise. Set from Pane.refreshChrome; the reading is best-effort.
    var claudeMode: ClaudeMode? {
        didSet {
            guard claudeMode != oldValue else { return }
            if let mode = claudeMode {
                modeControl.setSelected(mode)
                if modeControl.isHidden {
                    modeControl.isHidden = false
                }
            } else if !modeControl.isHidden {
                modeControl.isHidden = true
            }
            needsLayout = true
            setFrameSize(frame.size)
        }
    }

    // Context-window fill of the Claude session in this pane (ROADMAP Phase 7):
    // the "should I /compact or let it ride" glance. Colored like a fuel gauge
    // as compaction nears; hidden when no session reports it.
    var contextPct: Double? {
        didSet {
            guard contextPct != oldValue else { return }
            if let pct = contextPct {
                contextLabel.stringValue = "\(Int(pct.rounded()))%"
                contextLabel.textColor = Theme.contextLevelColor(pct)
                contextLabel.isHidden = false
            } else {
                contextLabel.isHidden = true
            }
            needsLayout = true
            setFrameSize(frame.size)
            window?.invalidateCursorRects(for: self)
        }
    }

    private func updateStatusDot() {
        statusDot.layer?.removeAnimation(forKey: "suit.pulse")
        if let exitStatus {
            statusDot.isHidden = false
            statusDot.layer?.backgroundColor = (exitStatus.isClean ? Theme.sessionDone : Theme.failed).cgColor
            toolTip = exitStatus.shortLabel
            return
        }
        guard let sessionState else {
            statusDot.isHidden = true
            toolTip = nil
            return
        }
        statusDot.isHidden = false
        statusDot.layer?.backgroundColor = sessionState.color.cgColor
        toolTip = "claude: \(sessionState.label)"
        if sessionState == .needsInput, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.25
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            statusDot.layer?.add(pulse, forKey: "suit.pulse")
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutBar()
    }

    private func layoutBar() {
        let iconSize: CGFloat = 12
        iconView.frame = NSRect(x: 8, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)

        var right = bounds.width - 8
        if !contextLabel.isHidden {
            let size = contextLabel.intrinsicContentSize
            contextLabel.frame = NSRect(x: right - size.width, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            right = contextLabel.frame.minX - 5
        }
        let dotSize: CGFloat = 6
        statusDot.frame = NSRect(x: right - dotSize, y: (bounds.height - dotSize) / 2, width: dotSize, height: dotSize)
        if !statusDot.isHidden {
            right = statusDot.frame.minX - 6
        }

        if !modeControl.isHidden {
            let width = modeControl.fittingWidth
            modeControl.frame = NSRect(x: right - width, y: 0, width: width, height: bounds.height)
            modeControl.needsLayout = true
            right = modeControl.frame.minX - 8
        }

        let left = iconView.frame.maxX + 6
        label.frame = NSRect(x: left, y: (bounds.height - 14) / 2, width: max(0, right - left), height: 14)
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Pane drag source

    // The labels cover most of the bar and would swallow mouseDown, so claim
    // every hit for the bar itself — a click focuses the pane, a drag moves it.
    // The mode control is the one exception: its clicks must reach it, not the
    // drag handle, so a hit inside it returns the control (Phase 26).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if !modeControl.isHidden, hit === modeControl || hit.isDescendant(of: modeControl) {
            return hit
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
    }

    // Only reached for plain clicks: once mouseDragged starts a drag session,
    // AppKit routes the rest of the gesture (including the mouse-up) there.
    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil }
        guard mouseDownLocation != nil, let pane else { return }
        // Phase 27 — a click on the context meter fires /compact instead of
        // focusing, when there's a live session to compact.
        let local = convert(event.locationInWindow, from: nil)
        if !contextLabel.isHidden,
           contextLabel.frame.insetBy(dx: -4, dy: -4).contains(local),
           pane.compactContextSession() {
            return
        }
        window?.makeFirstResponder(pane.focusTarget)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pane, let start = mouseDownLocation else { return }
        // A few points of slop so a sloppy click doesn't become a drag.
        guard hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        mouseDownLocation = nil

        let item = NSPasteboardItem()
        item.setString(pane.dragID, forType: .suitPane)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        // Drag just the title bar's own snapshot — small enough not to hide the
        // drop preview underneath the cursor, but still labeled with the title.
        draggingItem.setDraggingFrame(bounds, contents: snapshotImage(of: self))
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func snapshotImage(of view: NSView) -> NSImage {
        let image = NSImage(size: view.bounds.size)
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .generic : []
    }
}
