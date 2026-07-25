import Cocoa

// One icon in the window's activity bar: a flat hover-square in the artifact
// language (hover #262A31, amber-tinted selection, accent icon when selected)
// — the native NSSegmentedControl read as aqua chrome, not the mockup's rail.
// Sized for the 48pt bar (see ActivityBarView.width); the square and its glyph
// scale together, so changing `size` alone leaves the icon small and centered.
final class RailIconView: NSView {
    static let size: CGFloat = 40

    let tab: SidebarView.Tab
    var onClick: ((SidebarView.Tab) -> Void)?

    var isSelected = false {
        didSet {
            iconView.contentTintColor = isSelected ? Theme.accent : Theme.textDim
            needsDisplay = true
        }
    }
    private var isHovered = false {
        didSet { needsDisplay = true }
    }
    // A count in the icon's bottom-right corner — how many files the Source
    // Control tab has to show. Zero draws nothing: a badge is only information
    // when it is sometimes absent.
    var badgeCount = 0 {
        didSet {
            guard badgeCount != oldValue else { return }
            needsDisplay = true
        }
    }

    private let iconView = NSImageView(frame: .zero)

    init(tab: SidebarView.Tab) {
        self.tab = tab
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        toolTip = tab.label
        iconView.image = tab.icon
        iconView.contentTintColor = Theme.textDim
        let iconSize: CGFloat = 24
        iconView.frame = NSRect(
            x: (Self.size - iconSize) / 2, y: (Self.size - iconSize) / 2,
            width: iconSize, height: iconSize
        )
        addSubview(iconView)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tab.label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Live theme switch: re-set the icon tint baked in at init (selection state
    // is preserved); the hover/selection fill in draw() re-reads its token live.
    func reapplyTheme() {
        iconView.contentTintColor = isSelected ? Theme.accent : Theme.textDim
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected || isHovered {
            let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
            (isSelected ? Theme.selection : Theme.hover).setFill()
            path.fill()
        }
        drawBadge()
    }

    // The count pill: accent ground, bar-chrome text so it reads on any
    // palette, clamped to "99+" so a repo mid-rebase can't widen the rail.
    private func drawBadge() {
        guard badgeCount > 0 else { return }
        let text = badgeCount > 99 ? "99+" : String(badgeCount)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: Theme.barChrome,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let height: CGFloat = 14
        let width = max(height, textSize.width + 8)
        // Bottom-right of the square, half a pill outside the glyph's box.
        let rect = NSRect(x: bounds.maxX - width - 1, y: bounds.minY + 2, width: width, height: height)
        Theme.accent.setFill()
        NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
        (text as NSString).draw(
            at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
            withAttributes: attributes
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?(tab)
        }
    }
}
