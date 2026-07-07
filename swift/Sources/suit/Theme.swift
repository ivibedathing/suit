import Cocoa

// The visual design system (ROADMAP Phase 11): every color, metric, and type
// decision from the approved design artifact, in one namespace. Components
// never state their own hex or magic padding — they read tokens from here.
// The app is committed dark (the window pins .darkAqua); these are not
// dynamic system colors on purpose.
enum Theme {
    // MARK: - Chrome

    /// Window/content ground — also the default viewer/diff background.
    static let bg = rgb(0x17191D)
    /// Terminal ground: a step darker than the chrome, so shell output sits
    /// in its own deeper layer.
    static let terminalBg = rgb(0x0E1013)
    /// Bar chrome: tab strip, pane headers, sidebar rail.
    static let barChrome = rgb(0x1F2228)
    /// Raised/active surface — the active tab.
    static let raised = rgb(0x2A2E36)
    /// Hover surface — strip tabs, sidebar rows, hover squares.
    static let hover = rgb(0x262A31)
    /// Hairline borders and dividers.
    static let hairline = rgb(0x34383F)
    /// Overlay/menu surface — the ⌃Tab switcher, palette, composer.
    static let overlay = rgb(0x23262C)

    // MARK: - Text

    static let textPrimary = rgb(0xD7DAE0)
    static let textDim = rgb(0x8B909C)
    /// Line numbers, captions, disabled.
    static let textFaint = rgb(0x4C515B)

    // MARK: - Accent & semantic session colors

    /// Amber — focus borders, visible-tab ticks, switcher selection, drop
    /// indicators. Replaces controlAccentColor everywhere in the chrome.
    static let accent = rgb(0xD99A3D)
    /// The pane focus border: 1pt accent at 70%.
    static var focusBorder: NSColor { accent.withAlphaComponent(0.7) }
    /// Amber-tinted row selection (sidebar lists, search results).
    static var selection: NSColor { accent.withAlphaComponent(0.22) }

    static let sessionBusy = rgb(0xE08A3C)
    static let sessionNeedsInput = rgb(0xE5C453)
    static let sessionDone = rgb(0x57B36B)
    static let failed = rgb(0xD95757)

    /// Global usage readout (5h/7d): green under 50, amber to 80, red past it.
    static func usageLevelColor(_ pct: Double) -> NSColor {
        pct >= 80 ? failed : pct >= 50 ? sessionBusy : sessionDone
    }

    /// Context-window fill %: neutral until 70, amber to 90, red past it.
    static func contextLevelColor(_ pct: Double) -> NSColor {
        pct >= 90 ? failed : pct >= 70 ? sessionBusy : textFaint
    }

    // MARK: - Metrics

    enum Metrics {
        static let stripHeight: CGFloat = 40
        /// Tabs are 34pt, bottom-aligned in the strip (they connect to the content edge).
        static let tabHeight: CGFloat = 34
        /// Top corners only — the tab merges into the content below.
        static let tabRadius: CGFloat = 8
        static let tabGap: CGFloat = 2
        static let tabMaxWidth: CGFloat = 190
        static let tabPinnedWidth: CGFloat = 34
        static let tabIconSize: CGFloat = 14
        static let dotSize: CGFloat = 7
        /// The 2pt amber bar marking a tab visible in a non-focused pane.
        static let visibleTickHeight: CGFloat = 2
        static let visibleTickInset: CGFloat = 10
        /// "+" and ⌄ hover squares.
        static let stripButtonSize: CGFloat = 24

        static let paneHeaderHeight: CGFloat = 26
        static let paneHeaderIconSize: CGFloat = 12
        static let paneCornerRadius: CGFloat = 4
        static let focusBorderWidth: CGFloat = 1

        static let overlayRadius: CGFloat = 10
        static let menuRadius: CGFloat = 8
        static let switcherRowHeight: CGFloat = 30

        /// The one motion value: tab reorder, hover fades. Gate any animation
        /// using it behind accessibilityDisplayShouldReduceMotion.
        static let easeDuration: TimeInterval = 0.12
    }

    // MARK: - Type

    /// Tab titles (italic variant = preview tab).
    static let tabTitleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let paneHeaderFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    /// ctx% in pane headers.
    static let contextFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    /// The strip's usage readout.
    static let usageFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    /// Uppercase letter-spaced captions in overlays.
    static let captionFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
    static let captionKern: CGFloat = 0.8

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(
            calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// Amber-tinted selection for list rows (palette, sidebar lists), replacing
// the emphasized controlAccentColor highlight. isEmphasized stays false so
// AppKit never forces selected labels to white — cell colors stay as set.
class ThemedTableRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none, isSelected else { return }
        Theme.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}
