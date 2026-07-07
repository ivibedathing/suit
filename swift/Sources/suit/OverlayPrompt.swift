import Cocoa

// A single-field prompt on the overlay surface (Phase 15): the artifact's
// panel language (flat #23262C, radius 10, hairline border, mono caption)
// instead of a stock NSAlert with an accessory field. Used for rename-tab
// and new-Claude-task; Enter commits, Esc cancels.
final class OverlayPromptController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    static let shared = OverlayPromptController()

    private final class PromptPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private static let panelSize = NSSize(width: 420, height: 92)

    private let panel: PromptPanel
    private let captionLabel = NSTextField(labelWithString: "")
    private let field = NSTextField(frame: .zero)
    private var onCommit: ((String) -> Void)?

    override init() {
        panel = PromptPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
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

        let surface = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
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
        captionLabel.frame = NSRect(x: 18, y: Self.panelSize.height - 26, width: Self.panelSize.width - 36, height: 14)
        surface.addSubview(captionLabel)

        field.frame = NSRect(x: 16, y: 16, width: Self.panelSize.width - 32, height: 30)
        field.font = .systemFont(ofSize: 18, weight: .light)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = Theme.textPrimary
        field.delegate = self
        surface.addSubview(field)
    }

    // Shows the prompt centered over `window`'s top third. `caption` renders
    // as the uppercase mono overlay caption.
    func ask(caption: String, text: String = "", placeholder: String = "",
             over window: NSWindow?, onCommit: @escaping (String) -> Void) {
        self.onCommit = onCommit
        captionLabel.stringValue = caption.uppercased()
        field.stringValue = text
        field.placeholderString = placeholder

        if let window {
            let frame = window.frame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - Self.panelSize.width / 2,
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

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            let commit = onCommit
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            dismiss()
            commit?(value)
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
