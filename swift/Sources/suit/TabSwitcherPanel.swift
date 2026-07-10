import Cocoa

// The ⌃Tab switcher (browser/IDE-style): an overlay listing the window's tabs
// in most-recently-used order. Triggered by the ⌃Tab menu item; while the
// panel is up, further ⌃Tab/⌃⇧Tab presses advance the selection (the menu
// action routes back here) and releasing ⌃ commits. A quick ⌃Tab tap — control
// already up by the time the panel would show — switches instantly instead.
final class TabSwitcherController {
    private var panel: NSPanel?
    private var rows: [SwitcherRowView] = []
    private var tabs: [Tab] = []
    private var selectedIndex = 0
    private var onPick: ((Tab) -> Void)?
    private var flagsMonitor: Any?

    var isVisible: Bool { panel != nil }

    // A tab in the visible list just closed (clean exit auto-close, cross-
    // window move): the rows are stale and a commit on the dead row would
    // silently do nothing — drop the panel rather than lie.
    func tabClosed(_ tab: Tab) {
        guard isVisible, tabs.contains(where: { $0 === tab }) else { return }
        dismiss()
    }

    // Called on every ⌃Tab/⌃⇧Tab: opens the panel (or advances it).
    func cycle(tabs mruTabs: [Tab], forward: Bool, over window: NSWindow?, onPick: @escaping (Tab) -> Void) {
        if isVisible {
            advance(forward ? 1 : -1)
            return
        }
        guard mruTabs.count > 1 else { return }
        tabs = mruTabs
        self.onPick = onPick
        selectedIndex = forward ? 1 : mruTabs.count - 1

        // Control already released (a quick tap): switch instantly, no panel.
        if !NSEvent.modifierFlags.contains(.control) {
            commit()
            return
        }

        show(over: window)
        // Commit the moment ⌃ is released, cancel on Esc — global-within-app
        // monitor, since the panel never becomes key (focus stays in the pane).
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self, self.isVisible else { return event }
            if event.type == .flagsChanged, !event.modifierFlags.contains(.control) {
                self.commit()
                return nil
            }
            if event.type == .keyDown, event.keyCode == 53 { // Esc
                self.dismiss()
                return nil
            }
            return event
        }
    }

    private func advance(_ delta: Int) {
        guard !tabs.isEmpty else { return }
        selectedIndex = ((selectedIndex + delta) % tabs.count + tabs.count) % tabs.count
        updateSelection()
    }

    private func commit() {
        let picked = tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil
        let pick = onPick
        dismiss()
        if let picked { pick?(picked) }
    }

    private func dismiss() {
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
        rows = []
        tabs = []
        onPick = nil
    }

    private func show(over window: NSWindow?) {
        let rowHeight = Theme.Metrics.switcherRowHeight
        let width: CGFloat = 340
        let height = CGFloat(tabs.count) * rowHeight + 36

        // Flat overlay surface — the committed-dark design replaced
        // the HUD vibrancy with the Theme overlay fill.
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.overlay.cgColor
        content.layer?.cornerRadius = Theme.Metrics.overlayRadius
        content.layer?.borderWidth = 1
        content.layer?.borderColor = Theme.hairline.cgColor

        let caption = NSTextField(labelWithString: "")
        caption.attributedStringValue = NSAttributedString(
            string: "⌃TAB — MOST RECENT FIRST",
            attributes: [
                .font: Theme.captionFont,
                .foregroundColor: Theme.textFaint,
                .kern: Theme.captionKern,
            ]
        )
        caption.frame = NSRect(x: 14, y: height - 26, width: width - 28, height: 14)
        content.addSubview(caption)

        rows = []
        for (i, tab) in tabs.enumerated() {
            let row = SwitcherRowView(frame: NSRect(
                x: 6, y: height - 34 - CGFloat(i + 1) * rowHeight + 2,
                width: width - 12, height: rowHeight - 2
            ))
            row.configure(tab: tab)
            content.addSubview(row)
            rows.append(row)
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.contentView = content
        panel.isReleasedWhenClosed = false

        if let window {
            let frame = window.frame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - width / 2,
                y: frame.midY - height / 2
            ))
        } else {
            panel.center()
        }
        self.panel = panel
        updateSelection()
        panel.orderFrontRegardless()
    }

    private func updateSelection() {
        for (i, row) in rows.enumerated() {
            row.setSelected(i == selectedIndex)
        }
    }
}

// One row of the switcher: icon, title, and where the tab currently lives.
private final class SwitcherRowView: NSView {
    private let iconView = NSImageView(frame: .zero)
    private let label = NSTextField(labelWithString: "")
    private let whereLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6

        iconView.imageScaling = .scaleProportionallyDown
        iconView.frame = NSRect(x: 10, y: (frameRect.height - 13) / 2, width: 13, height: 13)
        addSubview(iconView)

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 30, y: (frameRect.height - 15) / 2, width: frameRect.width - 110, height: 15)
        addSubview(label)

        whereLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        whereLabel.alignment = .right
        whereLabel.frame = NSRect(x: frameRect.width - 80, y: (frameRect.height - 12) / 2, width: 70, height: 12)
        addSubview(whereLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(tab: Tab) {
        iconView.image = NSImage(systemSymbolName: tab.kind.symbolName, accessibilityDescription: nil)
        label.stringValue = tab.title
        whereLabel.stringValue = tab.pane == nil ? "background" : "visible"
    }

    // Amber selection with dark text, per the design artifact.
    func setSelected(_ selected: Bool) {
        layer?.backgroundColor = selected ? Theme.accent.cgColor : nil
        label.textColor = selected ? Theme.bg : Theme.textPrimary
        iconView.contentTintColor = selected ? Theme.bg : Theme.textDim
        whereLabel.textColor = selected ? Theme.bg.withAlphaComponent(0.7) : Theme.textFaint
    }
}
