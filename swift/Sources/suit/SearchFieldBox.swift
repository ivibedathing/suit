import Cocoa

// The bordered box the Search tab's two text fields live in: a flat rounded
// rect holding a stripped-bare NSTextField plus the toggles that belong *inside*
// the field — Aa / ab / .* on the pattern row, AB on the replace row.
//
// The toggles sit inside the field rather than on a row of their own because
// that is what they modify: ".*" beside the pattern reads as "this pattern is a
// regex", while the same button parked underneath reads as a mode the whole tab
// is in, which is how the old collapsed options row kept surprising people. The
// cost is that AppKit has no field with trailing accessory buttons — NSSearchField
// offers a magnifier and a cancel ✕ and nothing else — so the ground, the border
// and the focus ring are drawn here and the field inside is stripped of its own.
//
// Focus is *told*, not sensed: SearchView is already the fields' delegate and
// forwards controlTextDidBeginEditing / DidEndEditing to setFocused. That keeps
// this view out of the firstResponder business the window controller owns (see
// Pane.swift — focus is derived in one place), and out of the KVO sweep that
// repaints panes from it.
final class SearchFieldBox: NSView {
    static let height: CGFloat = 26
    // Every toggle is the same square, so a row of them reads as one strip of
    // glyphs rather than as buttons of assorted weights.
    static let toggleSize: CGFloat = 20

    let field = NSTextField(frame: .zero)

    private var toggles: [NSButton] = []
    private var focused = false

    init(placeholder: String) {
        super.init(frame: .zero)
        wantsLayer = true

        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 12)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = Theme.textPrimary
        field.lineBreakMode = .byClipping
        field.cell?.usesSingleLineMode = true
        addSubview(field)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Toggles are appended left-to-right in call order and laid out from the
    // right edge, so the first one added ends up leftmost — the order they are
    // read in.
    func addToggle(_ button: NSButton) {
        toggles.append(button)
        addSubview(button)
    }

    func setFocused(_ value: Bool) {
        guard focused != value else { return }
        focused = value
        needsDisplay = true
    }

    // Clicking the box anywhere that isn't a toggle means "type here"; without
    // this the 8pt of padding around the field is dead space.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Inset by half a point so the 1pt stroke lands on the pixel grid rather
        // than straddling it and rendering as a 2pt smear.
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        Theme.raised.setFill()
        path.fill()
        path.lineWidth = 1
        (focused ? Theme.accent : Theme.hairline).setStroke()
        path.stroke()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var right = bounds.width - 3
        for toggle in toggles.reversed() {
            right -= Self.toggleSize
            toggle.frame = NSRect(
                x: right, y: (bounds.height - 18) / 2,
                width: Self.toggleSize, height: 18
            )
        }
        let left: CGFloat = 7
        field.frame = NSRect(
            x: left, y: (bounds.height - 17) / 2,
            width: max(0, right - left - 4), height: 17
        )
    }

    // Re-read the tokens baked into the field at init. The box's own ground and
    // border are read at draw time, so they only need the repaint.
    func reapplyTheme() {
        field.textColor = Theme.textPrimary
        needsDisplay = true
    }

    // MARK: - Toggles

    // One inline toggle: a flat glyph that lights up on a tinted pad when on.
    // `underlined` draws the whole-word toggle's "ab" with the rule under it,
    // which is the only thing distinguishing it from a case toggle at 11pt.
    static func makeToggle(title: String, underlined: Bool = false, tooltip: String,
                           target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: target, action: action)
        button.setButtonType(.pushOnPushOff)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 3
        button.refusesFirstResponder = true
        button.toolTip = tooltip
        button.identifier = NSUserInterfaceItemIdentifier(underlined ? "underlined:" + title : title)
        style(toggle: button)
        return button
    }

    // Re-applied on every state change and on a theme switch: an attributed
    // title carries its color, so neither follows the palette on its own.
    static func style(toggle button: NSButton) {
        let raw = button.identifier?.rawValue ?? ""
        let underlined = raw.hasPrefix("underlined:")
        let title = underlined ? String(raw.dropFirst("underlined:".count)) : raw
        let on = button.state == .on
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: on ? Theme.textPrimary : Theme.textDim,
        ]
        if underlined {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        button.attributedTitle = NSAttributedString(string: title, attributes: attributes)
        button.layer?.backgroundColor = on ? Theme.selection.cgColor : nil
    }
}
