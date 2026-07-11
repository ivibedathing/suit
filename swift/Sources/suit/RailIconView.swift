import Cocoa

// One icon in the sidebar's tab rail: a flat hover-square in the artifact
// language (hover #262A31, amber-tinted selection, accent icon when selected)
// — the native NSSegmentedControl read as aqua chrome, not the mockup's rail.
final class RailIconView: NSView {
    static let size: CGFloat = 26

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

    private let iconView = NSImageView(frame: .zero)

    init(tab: SidebarView.Tab) {
        self.tab = tab
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        toolTip = tab.label
        iconView.image = tab.icon
        iconView.contentTintColor = Theme.textDim
        let iconSize: CGFloat = 16
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
        guard isSelected || isHovered else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        (isSelected ? Theme.selection : Theme.hover).setFill()
        path.fill()
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
