import Cocoa

// One open tab in the sidebar's Sessions list: type icon + title, a Claude
// session / failed dot, and a hover-revealed close box. The active tab (the one
// the focused pane shows) reads with the amber row-selection tint.
private final class SessionRowView: NSView {
    static let height: CGFloat = 26

    private(set) var tabId: String = ""
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?

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

        label.font = .systemFont(ofSize: 11.5, weight: .medium)
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
        tabId = tab.id
        toolTip = tab.title
        isActive = active

        iconView.image = NSImage(systemSymbolName: tab.kind.symbolName, accessibilityDescription: nil)
        iconView.contentTintColor = active ? Theme.accent : Theme.textDim

        label.stringValue = tab.title
        label.textColor = tab.failed ? Theme.failed : (active ? Theme.textPrimary : Theme.textDim)
        label.font = tab.isPreview
            ? NSFontManager.shared.convert(.systemFont(ofSize: 11.5, weight: .medium), toHaveTrait: .italicFontMask)
            : .systemFont(ofSize: 11.5, weight: .medium)

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

    override func draw(_ dirtyRect: NSRect) {
        if isActive {
            Theme.selection.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
        } else if isHovered {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
    }

    override func layout() {
        super.layout()
        let iconSize: CGFloat = 13
        iconView.frame = NSRect(x: 12, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        let dotSize = Theme.Metrics.dotSize
        var right = bounds.width - 10
        let showsClose = isHovered
        closeLabel.isHidden = !showsClose
        if showsClose {
            closeLabel.frame = NSRect(x: bounds.width - 22, y: (bounds.height - 14) / 2, width: 14, height: 14)
            right = closeLabel.frame.minX - 2
        }
        if showsDot {
            sessionDot.frame = NSRect(x: right - dotSize, y: (bounds.height - dotSize) / 2, width: dotSize, height: dotSize)
            right = sessionDot.frame.minX - 4
        }
        let left = iconView.frame.maxX + 7
        label.frame = NSRect(x: left, y: (bounds.height - 15) / 2, width: max(0, right - left), height: 15)
    }

    private func isCloseHit(_ point: NSPoint) -> Bool {
        isHovered && point.x >= bounds.width - 24
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
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        closeLabel.layer?.backgroundColor = nil
        closeLabel.textColor = Theme.textDim
        needsDisplay = true
        needsLayout = true
    }

    override func mouseMoved(with event: NSEvent) {
        let hit = isCloseHit(convert(event.locationInWindow, from: nil))
        closeLabel.layer?.backgroundColor = hit ? Theme.hover.cgColor : nil
        closeLabel.textColor = hit ? Theme.textPrimary : Theme.textDim
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if isCloseHit(point) {
            onClose?(tabId)
        } else {
            onSelect?(tabId)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, bounds.contains(convert(event.locationInWindow, from: nil)) else {
            super.otherMouseUp(with: event)
            return
        }
        onClose?(tabId)
    }
}

// The sidebar's Sessions tab: every open tab in the window, grouped by the pane
// (screen) that owns it — the cross-pane overview that replaces the removed
// top strip. Clicking a row brings that tab forward in its own pane; the close
// box shuts it. Grouping updates live as tabs open, close, and move panes.
final class SessionsView: NSView {
    struct Group {
        let title: String
        let tabs: [Tab]
    }

    // Absolute tab id in / out.
    var onSelectTab: ((String) -> Void)?
    var onCloseTab: ((String) -> Void)?

    private let scrollView = NSScrollView(frame: .zero)
    private let documentView = FlippedView(frame: .zero)
    private var rowViews: [SessionRowView] = []
    private var headerLabels: [NSTextField] = []

    private var groups: [Group] = []
    private var activeId: String?
    private var showHeaders = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(groups: [Group], activeId: String?) {
        self.groups = groups
        self.activeId = activeId
        self.showHeaders = groups.count > 1
        rebuild()
    }

    private func rebuild() {
        rowViews.forEach { $0.removeFromSuperview() }
        headerLabels.forEach { $0.removeFromSuperview() }
        rowViews = []
        headerLabels = []

        for group in groups {
            if showHeaders {
                let header = NSTextField(labelWithString: group.title.uppercased())
                header.font = .systemFont(ofSize: 10, weight: .semibold)
                header.textColor = Theme.textFaint
                header.lineBreakMode = .byTruncatingTail
                documentView.addSubview(header)
                headerLabels.append(header)
            }
            for tab in group.tabs {
                let row = SessionRowView(frame: .zero)
                row.configure(tab: tab, active: tab.id == activeId)
                row.onSelect = { [weak self] id in self?.onSelectTab?(id) }
                row.onClose = { [weak self] id in self?.onCloseTab?(id) }
                documentView.addSubview(row)
                rowViews.append(row)
            }
        }
        layoutDocument()
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        layoutDocument()
    }

    private func layoutDocument() {
        let width = scrollView.contentSize.width
        let rowHeight = SessionRowView.height
        let headerHeight: CGFloat = 20
        var y: CGFloat = 6
        var rowIndex = 0
        var headerIndex = 0
        for group in groups {
            if showHeaders, headerIndex < headerLabels.count {
                let header = headerLabels[headerIndex]
                header.frame = NSRect(x: 14, y: y + 3, width: max(0, width - 24), height: 14)
                headerIndex += 1
                y += headerHeight
            }
            for _ in group.tabs {
                guard rowIndex < rowViews.count else { break }
                rowViews[rowIndex].frame = NSRect(x: 0, y: y, width: width, height: rowHeight)
                rowIndex += 1
                y += rowHeight
            }
            y += 4
        }
        documentView.frame = NSRect(x: 0, y: 0, width: width, height: max(bounds.height, y + 6))
    }
}
