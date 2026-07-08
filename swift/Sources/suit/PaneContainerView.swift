import Cocoa

// Draws the focus border and lays out the header above the content view,
// both inset so the border is never painted over by the terminal's own
// (possibly Metal-backed) rendering.
final class PaneContainerView: NSView {
    static let inset: CGFloat = 3
    static let titleBarHeight = Theme.Metrics.paneHeaderHeight

    let titleBar = PaneTitleBarView(frame: .zero)
    // The in-pane tab bar, below the header; visible only with 2+ owned tabs.
    let tabBar = PaneTabBarView(frame: .zero)
    private var tabBarVisible = false
    weak var pane: Pane?
    private var content: NSView
    private let flashOverlay = NSView(frame: .zero)
    private let dropIndicator = NSView(frame: .zero)
    private var screensaver: NSView?

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        addSubview(content)
        addSubview(titleBar)
        tabBar.isHidden = true
        addSubview(tabBar)

        flashOverlay.wantsLayer = true
        flashOverlay.layer?.backgroundColor = NSColor.white.cgColor
        flashOverlay.alphaValue = 0
        flashOverlay.isHidden = true
        addSubview(flashOverlay)

        // Topmost overlay: previews where a title-bar-dragged pane (or a
        // strip-dragged tab) will land.
        dropIndicator.wantsLayer = true
        dropIndicator.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.25).cgColor
        dropIndicator.layer?.borderColor = Theme.accent.cgColor
        dropIndicator.layer?.borderWidth = 2
        dropIndicator.layer?.cornerRadius = Theme.Metrics.paneCornerRadius
        dropIndicator.isHidden = true
        addSubview(dropIndicator)

        registerForDraggedTypes([.suitPane, .suitTab])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutInterior()
    }

    private func layoutInterior() {
        let insetRect = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        titleBar.frame = NSRect(x: insetRect.minX, y: insetRect.maxY - Self.titleBarHeight, width: insetRect.width, height: Self.titleBarHeight)
        let barHeight = tabBarVisible ? PaneTabBarView.height : 0
        tabBar.frame = NSRect(x: insetRect.minX, y: insetRect.maxY - Self.titleBarHeight - barHeight, width: insetRect.width, height: barHeight)
        let contentFrame = NSRect(x: insetRect.minX, y: insetRect.minY, width: insetRect.width, height: insetRect.height - Self.titleBarHeight - barHeight)
        content.frame = contentFrame
        screensaver?.frame = contentFrame
        flashOverlay.frame = bounds
    }

    // Feeds the in-pane tab bar. Toggling its visibility re-lays the content out
    // (the bar steals PaneTabBarView.height when it appears).
    func setTabBar(tabs: [Tab], active: Tab) {
        let shouldShow = tabBar.wantsDisplay(for: tabs)
        tabBar.configure(tabs: tabs, activeId: active.id)
        if shouldShow != tabBarVisible {
            tabBarVisible = shouldShow
            tabBar.isHidden = !shouldShow
            layoutInterior()
        }
    }

    // Swaps which tab's view fills the container (below the title bar,
    // screensaver, flash, and drop overlays).
    func setContentView(_ newView: NSView) {
        guard newView !== content else { return }
        let frame = content.frame
        content.removeFromSuperview()
        content = newView
        newView.frame = frame
        addSubview(newView, positioned: .below, relativeTo: nil)
    }

    // Shown/hidden above the terminal content, below the title bar and bell flash,
    // so toggling a pane's screensaver never hides its title or exit-status dot.
    func setScreensaverView(_ newView: NSView?) {
        screensaver?.removeFromSuperview()
        screensaver = newView
        guard let newView else { return }
        newView.frame = content.frame
        addSubview(newView, positioned: .above, relativeTo: content)
    }

    // A brief full-pane white flash for the terminal bell — visible regardless of
    // the pane's own background color, and useful for noticing a bell in an
    // unfocused pane/window without relying on the (often muted/disabled) system beep.
    func flashForBell() {
        flashOverlay.isHidden = false
        flashOverlay.layer?.removeAllAnimations()
        flashOverlay.alphaValue = 0.35
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            flashOverlay.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.flashOverlay.isHidden = true
        })
    }

    // MARK: - Drop target (panes and tabs)

    // The dragged pane's dragID, but only if this pane can actually accept it
    // (it resolves to another pane in the same window's tree).
    private func acceptableDragID(_ sender: NSDraggingInfo) -> String? {
        guard let pane,
              let id = sender.draggingPasteboard.string(forType: .suitPane),
              pane.canAcceptDrop(ofPaneWithDragID: id) else { return nil }
        return id
    }

    // The dragged tab's id, if this pane can accept it.
    private func acceptableTabId(_ sender: NSDraggingInfo) -> String? {
        guard let pane,
              let id = sender.draggingPasteboard.string(forType: .suitTab),
              pane.canAcceptDrop(ofTabWithId: id) else { return nil }
        return id
    }

    // A tab dropped on the screen replaces what it shows (Chrome/VS Code
    // rule) — .show is the dominant target everywhere, including the header.
    // Only a slim band along each edge still splits the tab out, so splitting
    // stays available but deliberate.
    private func tabDropTarget(at point: NSPoint) -> TabDropTarget {
        if titleBar.frame.contains(point) {
            return .show
        }
        guard bounds.width > 0, bounds.height > 0 else { return .show }
        let band = min(60, min(bounds.width, bounds.height) * 0.2)
        let xDist = min(point.x, bounds.width - point.x)
        let yDist = min(point.y, bounds.height - point.y)
        if xDist > band && yDist > band {
            return .show
        }
        // Inside a band: whichever edge is actually nearest (not flipped, so
        // y grows upward — .top is the maxY side).
        if xDist <= yDist {
            return .edge(point.x < bounds.width / 2 ? .left : .right)
        }
        return .edge(point.y < bounds.height / 2 ? .bottom : .top)
    }

    private func indicatorFrame(forTabTarget target: TabDropTarget) -> NSRect {
        switch target {
        case .show:
            return bounds.insetBy(dx: Self.inset, dy: Self.inset)
        case .edge(let zone):
            return indicatorFrame(for: zone)
        }
    }

    // Not flipped, so y grows upward: .top is the half at maxY.
    private func dropZone(at point: NSPoint) -> PaneDropZone {
        guard bounds.width > 0, bounds.height > 0 else { return .swap }
        let fx = point.x / bounds.width
        let fy = point.y / bounds.height
        if (0.3...0.7).contains(fx) && (0.3...0.7).contains(fy) {
            return .swap
        }
        // Outside the swap region: whichever edge is nearest, in normalized
        // coordinates so wide-but-short panes don't over-favor top/bottom.
        let nearest = min(fx, 1 - fx, fy, 1 - fy)
        if nearest == fx { return .left }
        if nearest == 1 - fx { return .right }
        if nearest == fy { return .bottom }
        return .top
    }

    private func indicatorFrame(for zone: PaneDropZone) -> NSRect {
        let area = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        switch zone {
        case .swap:
            return area
        case .left:
            return NSRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height)
        case .right:
            return NSRect(x: area.midX, y: area.minY, width: area.width / 2, height: area.height)
        case .bottom:
            return NSRect(x: area.minX, y: area.minY, width: area.width, height: area.height / 2)
        case .top:
            return NSRect(x: area.minX, y: area.midY, width: area.width, height: area.height / 2)
        }
    }

    private func updateDropPreview(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        if acceptableTabId(sender) != nil {
            dropIndicator.frame = indicatorFrame(forTabTarget: tabDropTarget(at: point))
            dropIndicator.isHidden = false
            return .generic
        }
        guard acceptableDragID(sender) != nil else {
            dropIndicator.isHidden = true
            return []
        }
        dropIndicator.frame = indicatorFrame(for: dropZone(at: point))
        dropIndicator.isHidden = false
        return .generic
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropPreview(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropPreview(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropIndicator.isHidden = true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropIndicator.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropIndicator.isHidden = true
        guard let pane else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        if let tabId = acceptableTabId(sender) {
            return pane.acceptDrop(ofTabWithId: tabId, target: tabDropTarget(at: point))
        }
        guard let id = acceptableDragID(sender) else { return false }
        return pane.acceptDrop(ofPaneWithDragID: id, zone: dropZone(at: point))
    }
}
