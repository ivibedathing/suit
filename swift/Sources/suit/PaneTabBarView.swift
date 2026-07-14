import Cocoa

// One chip in a pane's in-pane tab bar: type icon + title, a Claude session /
// failed dot, and a hover-revealed close box. Purely visual + local hit
// resolution; the bar routes select/close/context back to the pane's host.
final class PaneTabChipView: NSView, NSDraggingSource {
    static let height: CGFloat = 24
    static let minWidth: CGFloat = 70
    static let maxWidth: CGFloat = 180

    private(set) var tabId: String = ""
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var contextMenuProvider: ((String) -> NSMenu?)?
    // Dragged off every Suit window → tear the tab into its own window.
    var onTearOff: ((String, NSPoint) -> Void)?

    // Retained so a drag can render the same pane-header preview a strip drag
    // did, and so the tear-off payload matches the .suitTab drop side.
    private var tab: Tab?
    private var mouseDownLocation: NSPoint?

    private let iconView = NSImageView(frame: .zero)
    private let label = NSTextField(labelWithString: "")
    private let closeLabel = NSTextField(labelWithString: "✕")
    private let sessionDot = NSView(frame: .zero)

    private var isActive = false
    private var isHovered = false
    private var showsDot = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = Theme.textDim
        addSubview(iconView)

        label.font = Theme.tabTitleFont
        label.lineBreakMode = .byTruncatingTail
        label.textColor = Theme.textDim
        addSubview(label)

        closeLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        closeLabel.textColor = Theme.textDim
        closeLabel.alignment = .center
        closeLabel.wantsLayer = true
        closeLabel.layer?.cornerRadius = 3
        closeLabel.isHidden = true
        addSubview(closeLabel)

        sessionDot.wantsLayer = true
        sessionDot.layer?.cornerRadius = Theme.Metrics.dotSize / 2
        sessionDot.isHidden = true
        addSubview(sessionDot)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(tab: Tab, active: Bool) {
        self.tab = tab
        tabId = tab.id
        toolTip = tab.title
        isActive = active

        iconView.image = NSImage(systemSymbolName: tab.kind.symbolName, accessibilityDescription: nil)
        iconView.contentTintColor = active ? Theme.textPrimary : Theme.textDim

        label.stringValue = tab.title
        label.textColor = tab.failed ? Theme.failed : (active ? Theme.textPrimary : Theme.textDim)
        label.font = tab.isPreview
            ? NSFontManager.shared.convert(Theme.tabTitleFont, toHaveTrait: .italicFontMask)
            : Theme.tabTitleFont

        sessionDot.layer?.removeAnimation(forKey: "suit.pulse")
        if let state = tab.liveSessionState {
            showsDot = true
            sessionDot.isHidden = false
            sessionDot.layer?.backgroundColor = state.color.cgColor
            if state == .needsInput, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1.0
                pulse.toValue = 0.25
                pulse.duration = 0.7
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                sessionDot.layer?.add(pulse, forKey: "suit.pulse")
            }
        } else if tab.failed {
            showsDot = true
            sessionDot.isHidden = false
            sessionDot.layer?.backgroundColor = Theme.failed.cgColor
        } else {
            showsDot = false
            sessionDot.isHidden = true
        }

        needsDisplay = true
        needsLayout = true
    }

    // Live theme switch: re-run configure with the current tab/active state so
    // every cached color (icon/label tints, the session dot) re-reads its token.
    func reapplyTheme() {
        guard let tab else { return }
        configure(tab: tab, active: isActive)
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = bounds.insetBy(dx: 1, dy: 2)
        if isActive {
            let path = NSBezierPath(roundedRect: body, xRadius: 5, yRadius: 5)
            Theme.raised.setFill()
            path.fill()
            Theme.hairline.setStroke()
            path.lineWidth = 1
            path.stroke()
            // Accent underline anchors the active chip.
            Theme.accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: body.minX + 4, y: body.minY, width: body.width - 8, height: 2), xRadius: 1, yRadius: 1).fill()
        } else if isHovered {
            let path = NSBezierPath(roundedRect: body, xRadius: 5, yRadius: 5)
            Theme.hover.setFill()
            path.fill()
        }
    }

    override func layout() {
        super.layout()
        let iconSize = Theme.Metrics.tabIconSize
        iconView.frame = NSRect(x: 8, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        let dotSize = Theme.Metrics.dotSize
        var right = bounds.width - 7
        let showsClose = isActive || isHovered
        closeLabel.isHidden = !showsClose
        if showsClose {
            closeLabel.frame = NSRect(x: bounds.width - 19, y: (bounds.height - 14) / 2, width: 14, height: 14)
            right = closeLabel.frame.minX - 1
        }
        if showsDot {
            sessionDot.frame = NSRect(x: right - dotSize - 2, y: (bounds.height - dotSize) / 2, width: dotSize, height: dotSize)
            right = sessionDot.frame.minX - 3
        }
        let left = iconView.frame.maxX + 6
        label.frame = NSRect(x: left, y: (bounds.height - 15) / 2, width: max(0, right - left), height: 15)
    }

    private func isCloseHit(_ point: NSPoint) -> Bool {
        (isActive || isHovered) && point.x >= bounds.width - 20
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
        needsLayout = true
        updateCloseHover(event)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        closeLabel.layer?.backgroundColor = nil
        closeLabel.textColor = Theme.textDim
        needsDisplay = true
        needsLayout = true
    }

    override func mouseMoved(with event: NSEvent) {
        updateCloseHover(event)
    }

    private func updateCloseHover(_ event: NSEvent) {
        let hit = isCloseHit(convert(event.locationInWindow, from: nil))
        closeLabel.layer?.backgroundColor = hit ? Theme.hover.cgColor : nil
        closeLabel.textColor = hit ? Theme.textPrimary : Theme.textDim
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
    }

    // Only reached for a plain click: once mouseDragged begins a drag session,
    // AppKit routes the rest of the gesture (including mouse-up) there instead.
    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil }
        guard mouseDownLocation != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if isCloseHit(point) {
            onClose?(tabId)
        } else {
            onSelect?(tabId)
        }
    }

    // Dragging a chip tears the tab out: the payload is the tab id under
    // .suitTab, so a pane's edge drop-zones split it into its own pane (and a
    // drop over no window tears it into its own window) — the same machinery a
    // window-strip tab drag used, now reachable from the in-pane tab bar.
    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation, let tab else { return }
        // A few points of slop so a sloppy click doesn't become a drag.
        guard hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        mouseDownLocation = nil

        let item = NSPasteboardItem()
        item.setString(tabId, forType: .suitTab)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        // Preview as a pane header (matching a pane drag), centered under the
        // cursor and small enough not to hide the drop indicator beneath it.
        let preview = PaneTitleBarView.dragPreviewImage(for: tab)
        let local = convert(event.locationInWindow, from: nil)
        let frame = NSRect(
            x: local.x - preview.size.width / 2,
            y: local.y - preview.size.height / 2,
            width: preview.size.width,
            height: preview.size.height
        )
        draggingItem.setDraggingFrame(frame, contents: preview)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .generic : []
    }

    // A drag that ended on no drop target: if it left every Suit window (and
    // wasn't Esc-cancelled), tear the tab off into its own window. Mirrors the
    // window strip's tear-off. Esc-cancel also ends with operation == [], but
    // the cancel keystroke is still NSApp.currentEvent here.
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard operation == [] else { return }
        if let event = NSApp.currentEvent, event.type == .keyDown, event.keyCode == 53 {
            return
        }
        let overSuitWindow = NSApp.windows.contains { window in
            window.isVisible && window.frame.contains(screenPoint)
        }
        if !overSuitWindow {
            onTearOff?(tabId, screenPoint)
        }
    }

    // Middle-click closes, browser-style.
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, bounds.contains(convert(event.locationInWindow, from: nil)) else {
            super.otherMouseUp(with: event)
            return
        }
        onClose?(tabId)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?(tabId)
    }
}

// A pane's own tab bar (the tabs-on-the-pane model): a slim row of chips
// directly under the pane header, listing every tab the pane owns and switching
// between them. Hidden unless the pane holds more than one tab, so a
// single-tab pane looks exactly as before. There is no window-level strip;
// this and the sidebar Sessions tab together replace it.
final class PaneTabBarView: NSView {
    static let height: CGFloat = 28
    private static let gap: CGFloat = 3
    private static let inset: CGFloat = 4

    var onSelect: ((Tab) -> Void)?
    var onClose: ((Tab) -> Void)?
    var onTearOff: ((Tab, NSPoint) -> Void)?
    var contextMenuProvider: ((Tab) -> NSMenu?)?

    private var chips: [String: PaneTabChipView] = [:]
    private var order: [Tab] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.barChrome.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Live theme switch: re-set the flat bar ground baked in at init and
    // re-theme every chip; the bottom hairline redraws from the token live.
    func reapplyTheme() {
        layer?.backgroundColor = Theme.barChrome.cgColor
        for chip in chips.values { chip.reapplyTheme() }
        needsDisplay = true
    }

    // Whether the bar should take vertical space (only with 2+ tabs).
    func wantsDisplay(for tabs: [Tab]) -> Bool { tabs.count > 1 }

    // Chip frame lookup for offscreen design renders (design/tabs-demo), so a
    // scripted drag's ghost can lift off from the real chip's position.
    func chipFrame(forTabId id: String) -> NSRect? { chips[id]?.frame }

    func configure(tabs: [Tab], activeId: String?) {
        order = tabs
        var seen = Set<String>()
        for tab in tabs {
            seen.insert(tab.id)
            let chip: PaneTabChipView
            if let existing = chips[tab.id] {
                chip = existing
            } else {
                chip = PaneTabChipView(frame: .zero)
                chip.onSelect = { [weak self] id in
                    guard let self, let tab = self.order.first(where: { $0.id == id }) else { return }
                    self.onSelect?(tab)
                }
                chip.onClose = { [weak self] id in
                    guard let self, let tab = self.order.first(where: { $0.id == id }) else { return }
                    self.onClose?(tab)
                }
                chip.onTearOff = { [weak self] id, point in
                    guard let self, let tab = self.order.first(where: { $0.id == id }) else { return }
                    self.onTearOff?(tab, point)
                }
                chip.contextMenuProvider = { [weak self] id in
                    guard let self, let tab = self.order.first(where: { $0.id == id }) else { return nil }
                    return self.contextMenuProvider?(tab)
                }
                chips[tab.id] = chip
                addSubview(chip)
            }
            chip.configure(tab: tab, active: tab.id == activeId)
        }
        for (id, chip) in chips where !seen.contains(id) {
            chip.removeFromSuperview()
            chips.removeValue(forKey: id)
        }
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !order.isEmpty else { return }
        let available = bounds.width - Self.inset * 2
        let count = CGFloat(order.count)
        let totalGap = Self.gap * (count - 1)
        var width = (available - totalGap) / count
        width = max(24, min(PaneTabChipView.maxWidth, width))
        let y = (bounds.height - PaneTabChipView.height) / 2
        var x = Self.inset
        for tab in order {
            guard let chip = chips[tab.id] else { continue }
            chip.frame = NSRect(x: x, y: y, width: min(width, max(0, bounds.width - Self.inset - x)), height: PaneTabChipView.height)
            x += width + Self.gap
        }
    }

    // Hairline along the bottom so the bar reads as a distinct band above the
    // content the way the header does above it.
    override func draw(_ dirtyRect: NSRect) {
        Theme.hairline.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
