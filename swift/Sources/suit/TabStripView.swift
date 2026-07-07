import Cocoa

// A tab dragged from a window's strip: the payload is Tab.id, which resolves
// through AppDelegate across every open window, so tabs can be dropped into
// another window's strip or panes (the running process travels with them).
extension NSPasteboard.PasteboardType {
    static let suitTab = NSPasteboard.PasteboardType("dev.kosych.suit.tab")
}

// One tab in the window strip. Purely visual — TabStripView owns all mouse
// handling so click/drag/close resolution lives in one place.
final class TabItemView: NSView {
    static let pinnedWidth = Theme.Metrics.tabPinnedWidth
    static let maxWidth = Theme.Metrics.tabMaxWidth
    static let minWidth: CGFloat = 56

    private let iconView = NSImageView(frame: .zero)
    private let label = NSTextField(labelWithString: "")
    private let closeLabel = NSTextField(labelWithString: "✕")
    private let sessionDot = NSView(frame: .zero)
    private let visibleTick = NSView(frame: .zero)

    private(set) var tabId: String = ""
    private var isPinnedTab = false
    private var showsDot = false
    private var showsClose = false
    private var isActiveTab = false
    private var isHoveredTab = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = Theme.textDim
        addSubview(iconView)

        label.font = Theme.tabTitleFont
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        closeLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        closeLabel.textColor = Theme.textDim
        closeLabel.alignment = .center
        closeLabel.wantsLayer = true
        closeLabel.layer?.cornerRadius = 3
        addSubview(closeLabel)

        sessionDot.wantsLayer = true
        sessionDot.layer?.cornerRadius = Theme.Metrics.dotSize / 2
        sessionDot.isHidden = true
        addSubview(sessionDot)

        // The "shown in another pane" tick: a short accent bar along the
        // bottom edge, so the strip always reads the current layout.
        visibleTick.wantsLayer = true
        visibleTick.layer?.cornerRadius = 1
        visibleTick.layer?.backgroundColor = Theme.accent.cgColor
        visibleTick.isHidden = true
        addSubview(visibleTick)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // The tab body: top corners rounded, bottom edge square so the active tab
    // sits on (and merges into) the content edge below the strip.
    private func tabPath() -> NSBezierPath {
        let r = Theme.Metrics.tabRadius
        let b = bounds
        let path = NSBezierPath()
        path.move(to: NSPoint(x: b.minX, y: b.minY))
        path.line(to: NSPoint(x: b.minX, y: b.maxY - r))
        path.appendArc(
            withCenter: NSPoint(x: b.minX + r, y: b.maxY - r),
            radius: r, startAngle: 180, endAngle: 90, clockwise: true
        )
        path.line(to: NSPoint(x: b.maxX - r, y: b.maxY))
        path.appendArc(
            withCenter: NSPoint(x: b.maxX - r, y: b.maxY - r),
            radius: r, startAngle: 90, endAngle: 0, clockwise: true
        )
        path.line(to: NSPoint(x: b.maxX, y: b.minY))
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        // Raised and connected for the active tab, hover whisper otherwise;
        // background tabs stay flat on the bar chrome.
        if isActiveTab {
            let path = tabPath()
            Theme.raised.setFill()
            path.fill()
            // Hairline up the sides and over the top only — the bottom stays
            // open so the tab merges into the content edge.
            Theme.hairline.setStroke()
            path.lineWidth = 1
            path.stroke()
        } else if isHoveredTab {
            let path = tabPath()
            Theme.hover.setFill()
            path.fill()
        }
    }

    func configure(tab: Tab, active: Bool, visible: Bool, hovered: Bool, closeHovered: Bool) {
        tabId = tab.id
        isPinnedTab = tab.isPinned
        toolTip = tab.title

        iconView.image = NSImage(systemSymbolName: tab.kind.symbolName, accessibilityDescription: nil)
        iconView.contentTintColor = active ? Theme.textPrimary : Theme.textDim

        label.stringValue = tab.title
        label.isHidden = tab.isPinned
        label.textColor = tab.failed ? Theme.failed : (active ? Theme.textPrimary : Theme.textDim)
        label.font = tab.isPreview
            ? NSFontManager.shared.convert(Theme.tabTitleFont, toHaveTrait: .italicFontMask)
            : Theme.tabTitleFont

        isActiveTab = active
        isHoveredTab = hovered
        needsDisplay = true

        showsClose = !tab.isPinned && (active || hovered)
        closeLabel.isHidden = !showsClose
        // The close box gets its own hover square inside the tab.
        closeLabel.layer?.backgroundColor = closeHovered ? Theme.hover.cgColor : nil
        closeLabel.textColor = closeHovered ? Theme.textPrimary : Theme.textDim

        // Session dot (or the red failed dot once the shell is gone) —
        // attention routes through background tabs (ROADMAP Phase 4/6).
        // Pinned tabs keep their dot too (corner badge over the icon) — the
        // pinned claude session is exactly the one whose needs-input must
        // stay visible.
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

        visibleTick.isHidden = !(visible && !active)
        layoutParts()
    }

    // Bell in a background tab: a brief bright pulse of the item itself.
    func flashForBell() {
        guard let layer else { return }
        let flash = CABasicAnimation(keyPath: "backgroundColor")
        flash.fromValue = NSColor.white.withAlphaComponent(0.55).cgColor
        flash.toValue = layer.backgroundColor
        flash.duration = 0.4
        layer.add(flash, forKey: "suit.tabBell")
    }

    // The close box's hit area (item coordinates), padded for a forgiving target.
    func isCloseHit(_ point: NSPoint) -> Bool {
        showsClose && point.x >= bounds.width - 18
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutParts()
    }

    private func layoutParts() {
        let iconSize = Theme.Metrics.tabIconSize
        let dotSize = Theme.Metrics.dotSize
        let tickInset = Theme.Metrics.visibleTickInset
        let tickFrame = NSRect(
            x: tickInset, y: 1,
            width: max(0, bounds.width - tickInset * 2),
            height: Theme.Metrics.visibleTickHeight
        )
        if isPinnedTab {
            iconView.frame = NSRect(x: (bounds.width - iconSize) / 2, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
            // Corner badge: the session/failed dot stays visible on the
            // icon-only pinned item.
            sessionDot.frame = NSRect(x: bounds.width - dotSize - 4, y: bounds.height - dotSize - 4, width: dotSize, height: dotSize)
            visibleTick.frame = tickFrame
            return
        }
        iconView.frame = NSRect(x: 8, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        var right = bounds.width - 6
        if showsClose {
            closeLabel.frame = NSRect(x: bounds.width - 20, y: (bounds.height - 14) / 2, width: 14, height: 14)
            right = closeLabel.frame.minX - 2
        }
        if showsDot {
            sessionDot.frame = NSRect(x: right - dotSize - 2, y: (bounds.height - dotSize) / 2, width: dotSize, height: dotSize)
            right = sessionDot.frame.minX - 4
        }
        let left = iconView.frame.maxX + 6
        label.frame = NSRect(x: left, y: (bounds.height - 15) / 2, width: max(0, right - left), height: 15)
        visibleTick.frame = tickFrame
    }
}

// The window-level tab strip (browser-style): its own row directly below the
// title bar (the title bar owns window dragging — a tab drag can never move
// the window), owning every tab item, the "+" and overflow affordances, and
// the usage readout. All policy lives in the callbacks —
// TerminalWindowController decides what select/close/drop mean.
final class TabStripView: NSView, NSDraggingSource {
    static let height = Theme.Metrics.stripHeight
    private static let leftInset: CGFloat = 10

    // Data in: the strip pulls a snapshot on every reload().
    var tabsProvider: () -> [Tab] = { [] }
    var activeTabProvider: () -> Tab? = { nil }

    // Actions out.
    var onSelect: ((Tab) -> Void)?
    var onClose: ((Tab) -> Void)?
    var onNewTab: (() -> Void)?
    var onNewClaudeTab: (() -> Void)?     // the ✦ quick-access button
    var onKeep: ((Tab) -> Void)?          // double-click a preview tab
    var onRename: ((Tab) -> Void)?        // double-click a normal tab
    var contextMenuProvider: ((Tab) -> NSMenu?)?
    // A .suitTab drop on the strip at an insertion index (same window reorder
    // or cross-window adoption — the controller resolves the id).
    var onDropTab: ((String, Int) -> Bool)?
    // A drag session that ended outside every Suit window: tear off.
    var onTearOff: ((String, NSPoint) -> Void)?

    private var itemViews: [String: TabItemView] = [:]
    private var orderedItems: [TabItemView] = []
    private let newTabLabel = NSTextField(labelWithString: "+")
    private let claudeLabel = NSTextField(labelWithString: "✦")
    private let overflowLabel = NSTextField(labelWithString: "⌄")
    private let usageLabel = NSTextField(labelWithString: "")
    private let dropCaret = NSView(frame: .zero)

    private var hoveredTabId: String?
    private var closeHoveredTabId: String?
    private var hoveredButton: NSTextField?
    private var mouseDownLocation: NSPoint?
    private var draggedTabId: String?
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Flat bar chrome (Phase 11) — the committed-dark design replaced the
        // .titlebar vibrancy with the Theme fill.
        wantsLayer = true
        layer?.backgroundColor = Theme.barChrome.cgColor

        newTabLabel.font = .systemFont(ofSize: 15, weight: .regular)
        newTabLabel.textColor = Theme.textDim
        newTabLabel.alignment = .center
        newTabLabel.wantsLayer = true
        newTabLabel.layer?.cornerRadius = 4
        newTabLabel.toolTip = "New Terminal Tab (⌘T)"
        addSubview(newTabLabel)

        claudeLabel.font = .systemFont(ofSize: 12, weight: .regular)
        claudeLabel.textColor = Theme.textDim
        claudeLabel.alignment = .center
        claudeLabel.wantsLayer = true
        claudeLabel.layer?.cornerRadius = 4
        claudeLabel.toolTip = "New Claude Session (⌃⌘C)"
        addSubview(claudeLabel)

        overflowLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        overflowLabel.textColor = Theme.textDim
        overflowLabel.alignment = .center
        overflowLabel.wantsLayer = true
        overflowLabel.layer?.cornerRadius = 4
        overflowLabel.toolTip = "All Tabs"
        addSubview(overflowLabel)

        usageLabel.font = Theme.usageFont
        usageLabel.textColor = Theme.textDim
        usageLabel.alignment = .right
        addSubview(usageLabel)

        dropCaret.wantsLayer = true
        dropCaret.layer?.backgroundColor = Theme.accent.cgColor
        dropCaret.layer?.cornerRadius = 1
        dropCaret.isHidden = true
        addSubview(dropCaret)

        registerForDraggedTypes([.suitTab])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Rendering

    // Rebuilds the strip from the providers. Persisting tabs animate to their
    // new frames; new ones appear in place, closed ones vanish.
    func reload(animated: Bool = false) {
        let tabs = tabsProvider()
        let active = activeTabProvider()

        var seen = Set<String>()
        var newOrder: [TabItemView] = []
        for tab in tabs {
            seen.insert(tab.id)
            let item: TabItemView
            if let existing = itemViews[tab.id] {
                item = existing
            } else {
                item = TabItemView(frame: .zero)
                itemViews[tab.id] = item
                addSubview(item, positioned: .below, relativeTo: dropCaret)
            }
            item.configure(
                tab: tab,
                active: tab === active,
                visible: tab.pane != nil,
                hovered: tab.id == hoveredTabId,
                closeHovered: tab.id == closeHoveredTabId
            )
            newOrder.append(item)
        }
        for (id, item) in itemViews where !seen.contains(id) {
            item.removeFromSuperview()
            itemViews.removeValue(forKey: id)
        }
        orderedItems = newOrder
        layoutStrip(animated: animated)
    }

    func flashTab(withId id: String) {
        itemViews[id]?.flashForBell()
    }

    func setUsage(text: String, color: NSColor) {
        usageLabel.stringValue = text
        usageLabel.textColor = color
        needsLayout = true
        layoutStrip(animated: false)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutStrip(animated: false)
    }

    private func layoutStrip(animated: Bool) {
        let usageWidth = min(140, usageLabel.intrinsicContentSize.width + 10)
        usageLabel.frame = NSRect(x: bounds.width - usageWidth - 8, y: (bounds.height - 14) / 2, width: usageWidth, height: 14)

        let buttonSize = Theme.Metrics.stripButtonSize
        overflowLabel.frame = NSRect(x: usageLabel.frame.minX - buttonSize - 4, y: (bounds.height - buttonSize) / 2, width: buttonSize, height: buttonSize)
        claudeLabel.frame = NSRect(x: overflowLabel.frame.minX - buttonSize - 2, y: (bounds.height - buttonSize) / 2, width: buttonSize, height: buttonSize)
        newTabLabel.frame = NSRect(x: claudeLabel.frame.minX - buttonSize - 2, y: (bounds.height - buttonSize) / 2, width: buttonSize, height: buttonSize)

        let tabs = tabsProvider()
        let left = Self.leftInset
        let right = newTabLabel.frame.minX - 6
        let available = max(0, right - left)
        let gap = Theme.Metrics.tabGap

        let pinned = tabs.filter { $0.isPinned }
        let normal = tabs.count - pinned.count
        let pinnedTotal = CGFloat(pinned.count) * (TabItemView.pinnedWidth + gap)
        var normalWidth: CGFloat = 0
        if normal > 0 {
            let room = available - pinnedTotal - gap * CGFloat(max(0, normal - 1))
            normalWidth = max(24, min(TabItemView.maxWidth, room / CGFloat(normal)))
        }

        var x = left
        // Tabs are bottom-aligned: the active one connects to the content edge.
        let itemHeight = Theme.Metrics.tabHeight
        let animate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animate ? Theme.Metrics.easeDuration : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for (i, tab) in tabs.enumerated() {
                guard i < orderedItems.count else { break }
                let item = orderedItems[i]
                let width = tab.isPinned ? TabItemView.pinnedWidth : normalWidth
                let frame = NSRect(x: x, y: 0, width: min(width, max(0, right - x)), height: itemHeight)
                if animate, item.frame != .zero {
                    item.animator().frame = frame
                } else {
                    item.frame = frame
                }
                x += width + gap
            }
        }
    }

    // Which tab item `point` (strip coordinates) lands on.
    private func tabId(at point: NSPoint) -> String? {
        orderedItems.first { $0.frame.contains(point) }?.tabId
    }

    private func tab(withId id: String) -> Tab? {
        tabsProvider().first { $0.id == id }
    }

    // Where a tab dropped at `x` should be inserted: before the first item
    // whose midpoint is past the drop, else at the end.
    private func insertionIndex(atX x: CGFloat) -> Int {
        for (i, item) in orderedItems.enumerated() {
            if x < item.frame.midX { return i }
        }
        return orderedItems.count
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let id = tabId(at: point)
        var closeId: String?
        if let id, let item = itemViews[id], item.isCloseHit(convert(point, to: item)) {
            closeId = id
        }
        if id != hoveredTabId || closeId != closeHoveredTabId {
            hoveredTabId = id
            closeHoveredTabId = closeId
            reload()
        }
        updateButtonHover(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredTabId != nil || closeHoveredTabId != nil {
            hoveredTabId = nil
            closeHoveredTabId = nil
            reload()
        }
        updateButtonHover(at: nil)
    }

    // The "+" and ⌄ affordances light up as hover squares.
    private func updateButtonHover(at point: NSPoint?) {
        var target: NSTextField?
        if let point {
            if newTabLabel.frame.contains(point) {
                target = newTabLabel
            } else if claudeLabel.frame.contains(point) {
                target = claudeLabel
            } else if overflowLabel.frame.contains(point) {
                target = overflowLabel
            }
        }
        guard target !== hoveredButton else { return }
        hoveredButton?.layer?.backgroundColor = nil
        hoveredButton?.textColor = Theme.textDim
        hoveredButton = target
        target?.layer?.backgroundColor = Theme.hover.cgColor
        target?.textColor = Theme.textPrimary
    }

    // MARK: - Mouse (the item labels would swallow events; claim the whole bar
    // and resolve manually so dragging works from anywhere)

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil }
        guard mouseDownLocation != nil else { return }
        let point = convert(event.locationInWindow, from: nil)

        if newTabLabel.frame.insetBy(dx: -3, dy: -3).contains(point) {
            onNewTab?()
            return
        }
        if claudeLabel.frame.insetBy(dx: -3, dy: -3).contains(point) {
            onNewClaudeTab?()
            return
        }
        if overflowLabel.frame.insetBy(dx: -3, dy: -3).contains(point) {
            showOverflowMenu()
            return
        }
        guard let id = tabId(at: point), let tab = tab(withId: id) else { return }
        if event.clickCount == 2 {
            if tab.isPreview {
                onKeep?(tab)
            } else {
                onRename?(tab)
            }
            return
        }
        if let item = itemViews[id], item.isCloseHit(convert(point, to: item)) {
            onClose?(tab)
            return
        }
        onSelect?(tab)
    }

    // Middle-click closes, browser-style.
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let id = tabId(at: point), let tab = tab(withId: id) {
            onClose?(tab)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let id = tabId(at: point), let tab = tab(withId: id) else { return nil }
        return contextMenuProvider?(tab)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation else { return }
        guard hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        mouseDownLocation = nil

        let startPoint = convert(start, from: nil)
        // Background drags are inert: the title bar above owns window moves.
        guard let id = tabId(at: startPoint), let item = itemViews[id] else { return }
        draggedTabId = id
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(id, forType: .suitTab)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(item.frame, contents: snapshotImage(of: item))
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

    // MARK: - Overflow menu

    private func showOverflowMenu() {
        let menu = NSMenu()
        let active = activeTabProvider()
        for tab in tabsProvider() {
            let item = NSMenuItem(title: tab.title, action: #selector(overflowPick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tab.id
            item.state = tab === active ? .on : (tab.pane != nil ? .mixed : .off)
            item.image = NSImage(systemSymbolName: tab.kind.symbolName, accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: overflowLabel.frame.minX, y: overflowLabel.frame.minY - 2), in: self)
    }

    @objc private func overflowPick(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let tab = tab(withId: id) else { return }
        onSelect?(tab)
    }

    // MARK: - Drag source

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .generic : []
    }

    // A drag that ended on no target: if it left every Suit window, tear the
    // tab off into its own window at the drop point (browser behavior).
    // An Esc-cancelled drag also ends with operation == [] — the cancel
    // keystroke is still NSApp.currentEvent here, and cancelling must not
    // tear anything off.
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        defer { draggedTabId = nil }
        guard operation == [], let id = draggedTabId else { return }
        if let event = NSApp.currentEvent, event.type == .keyDown, event.keyCode == 53 {
            return
        }
        let overSuitWindow = NSApp.windows.contains { window in
            window.isVisible && window.frame.contains(screenPoint)
        }
        if !overSuitWindow {
            onTearOff?(id, screenPoint)
        }
    }

    // MARK: - Drop target (reorder within, or adopt from another window)

    private func updateDropCaret(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.string(forType: .suitTab) != nil else {
            dropCaret.isHidden = true
            return []
        }
        let point = convert(sender.draggingLocation, from: nil)
        let index = insertionIndex(atX: point.x)
        let x: CGFloat
        if index < orderedItems.count {
            x = orderedItems[index].frame.minX - 2
        } else if let last = orderedItems.last {
            x = last.frame.maxX + 1
        } else {
            x = Self.leftInset
        }
        dropCaret.frame = NSRect(x: x, y: 5, width: 2, height: bounds.height - 10)
        dropCaret.isHidden = false
        return .generic
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropCaret(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropCaret(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropCaret.isHidden = true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropCaret.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropCaret.isHidden = true
        guard let id = sender.draggingPasteboard.string(forType: .suitTab) else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        return onDropTab?(id, insertionIndex(atX: point.x)) ?? false
    }
}
