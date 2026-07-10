import Cocoa

// A single-field prompt on the overlay surface: the artifact's
// panel language (flat #23262C, radius 10, hairline border, mono caption)
// instead of a stock NSAlert with an accessory field. Used for rename-tab
// and new-Claude-task; Enter commits, Esc cancels.
//
// The prompt can carry one optional accessory toggle (an
// "Isolate in worktree" switch on the new-task prompt); the panel grows a
// row and `onCommit` reports the toggle's final state alongside the text.
final class OverlayPromptController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    static let shared = OverlayPromptController()

    private final class PromptPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private static let panelWidth: CGFloat = 420
    private static let baseHeight: CGFloat = 92
    // Extra height reserved for the accessory toggle row when present.
    private static let toggleRowHeight: CGFloat = 30

    private let panel: PromptPanel
    private let surface = NSView(frame: .zero)
    private let captionLabel = NSTextField(labelWithString: "")
    private let field = NSTextField(frame: .zero)
    private let toggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    // Reports (enteredText, toggleOn). Callers that don't use the toggle get
    // its initial value back unchanged.
    private var onCommit: ((String, Bool) -> Void)?

    override init() {
        panel = PromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.baseHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false

        super.init()

        panel.delegate = self

        surface.wantsLayer = true
        surface.layer?.backgroundColor = Theme.overlay.cgColor
        surface.layer?.cornerRadius = Theme.Metrics.overlayRadius
        surface.layer?.borderWidth = 1
        surface.layer?.borderColor = Theme.hairline.cgColor
        surface.layer?.masksToBounds = true
        surface.autoresizingMask = [.width, .height]
        panel.contentView = surface

        captionLabel.font = Theme.captionFont
        captionLabel.textColor = Theme.textFaint
        surface.addSubview(captionLabel)

        field.font = .systemFont(ofSize: 18, weight: .light)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = Theme.textPrimary
        field.delegate = self
        surface.addSubview(field)

        toggle.font = Theme.captionFont
        toggle.contentTintColor = Theme.textDim
        toggle.isHidden = true
        surface.addSubview(toggle)
    }

    // Shows the prompt centered over `window`'s top third. `caption` renders
    // as the uppercase mono overlay caption. The single-field convenience —
    // no accessory toggle.
    func ask(caption: String, text: String = "", placeholder: String = "",
             over window: NSWindow?, onCommit: @escaping (String) -> Void) {
        ask(caption: caption, text: text, placeholder: placeholder,
            toggleLabel: nil, toggleOn: false, over: window) { value, _ in onCommit(value) }
    }

    // The full form. `toggleLabel != nil` shows the accessory checkbox seeded
    // to `toggleOn`; `onCommit` then reports its final state.
    func ask(caption: String, text: String = "", placeholder: String = "",
             toggleLabel: String?, toggleOn: Bool = false,
             over window: NSWindow?, onCommit: @escaping (String, Bool) -> Void) {
        self.onCommit = onCommit

        let hasToggle = toggleLabel != nil
        let height = Self.baseHeight + (hasToggle ? Self.toggleRowHeight : 0)
        let size = NSSize(width: Self.panelWidth, height: height)
        panel.setContentSize(size)
        surface.frame = NSRect(origin: .zero, size: size)

        captionLabel.stringValue = caption.uppercased()
        captionLabel.frame = NSRect(x: 18, y: height - 26, width: size.width - 36, height: 14)

        // The text field sits above the toggle row when one is present.
        let fieldY = hasToggle ? 16 + Self.toggleRowHeight : 16
        field.frame = NSRect(x: 16, y: fieldY, width: size.width - 32, height: 30)
        field.stringValue = text
        field.placeholderString = placeholder

        if let toggleLabel {
            toggle.title = toggleLabel
            toggle.state = toggleOn ? .on : .off
            toggle.frame = NSRect(x: 17, y: 14, width: size.width - 34, height: 18)
            toggle.sizeToFit()
            toggle.setFrameOrigin(NSPoint(x: 17, y: 14))
            toggle.isHidden = false
        } else {
            toggle.isHidden = true
        }

        if let window {
            let frame = window.frame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.maxY - frame.height * 0.32
            ))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func dismiss() {
        onCommit = nil
        panel.orderOut(nil)
    }

    private func commitCurrent() {
        let commit = onCommit
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let toggleOn = !toggle.isHidden && toggle.state == .on
        dismiss()
        commit?(value, toggleOn)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            commitCurrent()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        default:
            return false
        }
    }

    // Clicking elsewhere cancels, like the palette.
    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }
}
