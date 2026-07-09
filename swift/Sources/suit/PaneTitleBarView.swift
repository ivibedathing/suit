import Cocoa

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
    private let dirtyDot = NSView(frame: .zero)
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

        // Unsaved-edits indicator for the editable viewer (Phase 37): a small
        // accent dot on the right, alongside the session/context chrome.
        dirtyDot.wantsLayer = true
        dirtyDot.layer?.cornerRadius = 2.5
        dirtyDot.layer?.backgroundColor = Theme.accent.cgColor
        dirtyDot.isHidden = true
        addSubview(dirtyDot)
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

    // The open file has unsaved edits (editable viewer, Phase 37). Shown as an
    // accent dot in the header; the strip carries the same flag on the tab.
    var isDirty: Bool = false {
        didSet {
            guard isDirty != oldValue else { return }
            dirtyDot.isHidden = !isDirty
            needsLayout = true
            setFrameSize(frame.size)
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
        let dirtySize: CGFloat = 5
        dirtyDot.frame = NSRect(x: right - dirtySize, y: (bounds.height - dirtySize) / 2, width: dirtySize, height: dirtySize)
        if !dirtyDot.isHidden {
            right = dirtyDot.frame.minX - 6
        }

        let left = iconView.frame.maxX + 6
        label.frame = NSRect(x: left, y: (bounds.height - 14) / 2, width: max(0, right - left), height: 14)
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Pane drag source

    // The labels cover most of the bar and would swallow mouseDown, so claim
    // every hit for the bar itself — a click focuses the pane, a drag moves it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
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

    // A pane-header-style drag preview for a tab being dragged out of the strip,
    // so tearing a tab into its own pane shows the same chrome a pane drag does
    // (a title-bar slice labeled with the tab). Configured from the tab, laid
    // out off-screen, and rasterized — mirrors `refreshChrome`.
    static func dragPreviewImage(for tab: Tab, width: CGFloat = 220) -> NSImage {
        let height = Theme.Metrics.paneHeaderHeight
        let bar = PaneTitleBarView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        bar.title = tab.title
        bar.icon = NSImage(systemSymbolName: tab.kind.symbolName, accessibilityDescription: nil)
        bar.exitStatus = tab.exitStatus
        bar.sessionState = tab.liveSessionState
        bar.contextPct = tab.exitStatus == nil ? tab.claudeSession?.contextPct : nil
        bar.isDirty = tab.isDirty
        bar.setFrameSize(bar.frame.size)   // re-run the custom layout after config
        let image = NSImage(size: bar.bounds.size)
        if let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
            bar.cacheDisplay(in: bar.bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .generic : []
    }
}
