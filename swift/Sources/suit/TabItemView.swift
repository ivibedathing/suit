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
