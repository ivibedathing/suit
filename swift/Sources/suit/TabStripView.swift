import Cocoa

// The window-level tab strip (browser-style): its own row directly below the
// title bar (the title bar owns window dragging — a tab drag can never move
// the window), owning every tab item, the "+" and overflow affordances, and
// the usage readout. All policy lives in the callbacks —
// TerminalWindowController decides what select/close/drop mean.
final class TabStripView: NSView, NSDraggingSource {
    static let height = Theme.Metrics.stripHeight
    // internal: read by the TabStripView+DragDrop extension (drop-caret math).
    static let leftInset: CGFloat = 10

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

    // internal: the TabStripView+DragDrop extension reads these while starting
    // a drag and tracking drops.
    var itemViews: [String: TabItemView] = [:]
    var orderedItems: [TabItemView] = []
    private let newTabLabel = NSTextField(labelWithString: "+")
    private let claudeLabel = NSTextField(labelWithString: "✦")
    private let overflowLabel = NSTextField(labelWithString: "⌄")
    private let usageLabel = NSTextField(labelWithString: "")
    let dropCaret = NSView(frame: .zero)

    private var hoveredTabId: String?
    private var closeHoveredTabId: String?
    private var hoveredButton: NSTextField?
    var mouseDownLocation: NSPoint?
    var draggedTabId: String?
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Flat bar chrome — the committed-dark design replaced the
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
    // internal: also used by the TabStripView+DragDrop extension.
    func tabId(at point: NSPoint) -> String? {
        orderedItems.first { $0.frame.contains(point) }?.tabId
    }

    private func tab(withId id: String) -> Tab? {
        tabsProvider().first { $0.id == id }
    }

    // Where a tab dropped at `x` should be inserted: before the first item
    // whose midpoint is past the drop, else at the end.
    // internal: also used by the TabStripView+DragDrop extension.
    func insertionIndex(atX x: CGFloat) -> Int {
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
}
