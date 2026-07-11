import Cocoa

// The visual design system: every color, metric, and type
// decision from the approved design artifact, in one namespace. Components
// never state their own hex or magic padding — they read tokens from here.
// The app is committed dark (the window pins .darkAqua); these are not
// dynamic system colors on purpose.
//
// Colors are no longer fixed: every color token is a computed var reading the
// active `Palette` (`Theme.current`), so themes are swappable at runtime while
// call sites (`Theme.bg`, `Theme.accent`, …) stay unchanged. Metrics and fonts
// are out of scope and stay `static let`.
enum Theme {
    /// The active color palette. Every color token below reads from this, so
    /// assigning a new palette re-skins the whole app (post `didChange` and ask
    /// windows to redraw). Defaults to Suit Dark — the values shipped today.
    static var current: Palette = .suitDark

    /// Posted after `current` is swapped so a central observer can repaint.
    static let didChange = Notification.Name("SuitThemeDidChange")

    // MARK: - Chrome

    /// Window/content ground — also the default viewer/diff background.
    static var bg: NSColor { current.bg }
    /// Terminal ground: a step darker than the chrome, so shell output sits
    /// in its own deeper layer.
    static var terminalBg: NSColor { current.terminalBg }
    /// Bar chrome: tab strip, pane headers, sidebar rail.
    static var barChrome: NSColor { current.barChrome }
    /// Raised/active surface — the active tab.
    static var raised: NSColor { current.raised }
    /// Hover surface — strip tabs, sidebar rows, hover squares.
    static var hover: NSColor { current.hover }
    /// Hairline borders and dividers.
    static var hairline: NSColor { current.hairline }
    /// Overlay/menu surface — the ⌃Tab switcher, palette, composer.
    static var overlay: NSColor { current.overlay }

    // MARK: - Text

    static var textPrimary: NSColor { current.textPrimary }
    static var textDim: NSColor { current.textDim }
    /// Line numbers, captions, disabled.
    static var textFaint: NSColor { current.textFaint }

    // MARK: - Accent & semantic session colors

    /// Amber — focus borders, visible-tab ticks, switcher selection, drop
    /// indicators. Replaces controlAccentColor everywhere in the chrome.
    static var accent: NSColor { current.accent }
    /// The pane focus border: 1pt accent at 70%.
    static var focusBorder: NSColor { accent.withAlphaComponent(0.7) }
    /// Amber-tinted row selection (sidebar lists, search results).
    static var selection: NSColor { accent.withAlphaComponent(0.22) }

    static var sessionBusy: NSColor { current.sessionBusy }
    static var sessionNeedsInput: NSColor { current.sessionNeedsInput }
    static var sessionDone: NSColor { current.sessionDone }
    static var failed: NSColor { current.failed }

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

    fileprivate static func rgb(_ hex: Int) -> NSColor {
        NSColor(
            calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Palette

extension Theme {
    /// A full set of Suit's color tokens — the in-memory theme and (via its
    /// `Codable` conformance) the on-disk color set. Colors (de)serialize as
    /// "#RRGGBB" strings. Every field is optional on decode with a fallback to
    /// the Suit Dark default for that token, so partial or older theme files
    /// still load (the FavoritesStore forward-compat trick).
    struct Palette: Codable {
        /// Stable human-readable name (also the on-disk selection id for built-ins).
        var name: String

        // Chrome
        var bg: NSColor
        var terminalBg: NSColor
        var barChrome: NSColor
        var raised: NSColor
        var hover: NSColor
        var hairline: NSColor
        var overlay: NSColor

        // Text
        var textPrimary: NSColor
        var textDim: NSColor
        var textFaint: NSColor

        // Accent & semantic
        var accent: NSColor
        var sessionBusy: NSColor
        var sessionNeedsInput: NSColor
        var sessionDone: NSColor
        var failed: NSColor

        init(
            name: String,
            bg: NSColor,
            terminalBg: NSColor,
            barChrome: NSColor,
            raised: NSColor,
            hover: NSColor,
            hairline: NSColor,
            overlay: NSColor,
            textPrimary: NSColor,
            textDim: NSColor,
            textFaint: NSColor,
            accent: NSColor,
            sessionBusy: NSColor,
            sessionNeedsInput: NSColor,
            sessionDone: NSColor,
            failed: NSColor
        ) {
            self.name = name
            self.bg = bg
            self.terminalBg = terminalBg
            self.barChrome = barChrome
            self.raised = raised
            self.hover = hover
            self.hairline = hairline
            self.overlay = overlay
            self.textPrimary = textPrimary
            self.textDim = textDim
            self.textFaint = textFaint
            self.accent = accent
            self.sessionBusy = sessionBusy
            self.sessionNeedsInput = sessionNeedsInput
            self.sessionDone = sessionDone
            self.failed = failed
        }

        // MARK: Codable ("#RRGGBB" strings, per-token fallback to suitDark)

        private enum CodingKeys: String, CodingKey {
            case name, bg, terminalBg, barChrome, raised, hover, hairline, overlay
            case textPrimary, textDim, textFaint
            case accent, sessionBusy, sessionNeedsInput, sessionDone, failed
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Palette.suitDark
            name = (try? c.decode(String.self, forKey: .name)) ?? d.name
            bg = Palette.color(c, .bg, d.bg)
            terminalBg = Palette.color(c, .terminalBg, d.terminalBg)
            barChrome = Palette.color(c, .barChrome, d.barChrome)
            raised = Palette.color(c, .raised, d.raised)
            hover = Palette.color(c, .hover, d.hover)
            hairline = Palette.color(c, .hairline, d.hairline)
            overlay = Palette.color(c, .overlay, d.overlay)
            textPrimary = Palette.color(c, .textPrimary, d.textPrimary)
            textDim = Palette.color(c, .textDim, d.textDim)
            textFaint = Palette.color(c, .textFaint, d.textFaint)
            accent = Palette.color(c, .accent, d.accent)
            sessionBusy = Palette.color(c, .sessionBusy, d.sessionBusy)
            sessionNeedsInput = Palette.color(c, .sessionNeedsInput, d.sessionNeedsInput)
            sessionDone = Palette.color(c, .sessionDone, d.sessionDone)
            failed = Palette.color(c, .failed, d.failed)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(Palette.hex(bg), forKey: .bg)
            try c.encode(Palette.hex(terminalBg), forKey: .terminalBg)
            try c.encode(Palette.hex(barChrome), forKey: .barChrome)
            try c.encode(Palette.hex(raised), forKey: .raised)
            try c.encode(Palette.hex(hover), forKey: .hover)
            try c.encode(Palette.hex(hairline), forKey: .hairline)
            try c.encode(Palette.hex(overlay), forKey: .overlay)
            try c.encode(Palette.hex(textPrimary), forKey: .textPrimary)
            try c.encode(Palette.hex(textDim), forKey: .textDim)
            try c.encode(Palette.hex(textFaint), forKey: .textFaint)
            try c.encode(Palette.hex(accent), forKey: .accent)
            try c.encode(Palette.hex(sessionBusy), forKey: .sessionBusy)
            try c.encode(Palette.hex(sessionNeedsInput), forKey: .sessionNeedsInput)
            try c.encode(Palette.hex(sessionDone), forKey: .sessionDone)
            try c.encode(Palette.hex(failed), forKey: .failed)
        }

        /// Decode one color key, falling back to `fallback` on missing/invalid hex.
        private static func color(
            _ c: KeyedDecodingContainer<CodingKeys>,
            _ key: CodingKeys,
            _ fallback: NSColor
        ) -> NSColor {
            guard let raw = try? c.decode(String.self, forKey: key),
                  let parsed = colorFromHex(raw) else { return fallback }
            return parsed
        }

        /// Parse "#RRGGBB" / "RRGGBB" (case-insensitive, optional leading '#').
        /// Returns nil on anything that isn't exactly six hex digits.
        static func colorFromHex(_ raw: String) -> NSColor? {
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("#") { s.removeFirst() }
            guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
            return Theme.rgb(v)
        }

        /// Serialize a color as an uppercase "#RRGGBB" string. Colors are
        /// normalized through genericRGB first so a color coming from a color
        /// well (device RGB) or a built-in (calibrated RGB) yields stable
        /// components; the built-in tokens round-trip byte-identical.
        static func hex(_ color: NSColor) -> String {
            let c = color.usingColorSpace(.genericRGB) ?? color
            let r = Int((c.redComponent * 255).rounded())
            let g = Int((c.greenComponent * 255).rounded())
            let b = Int((c.blueComponent * 255).rounded())
            return String(format: "#%02X%02X%02X", r, g, b)
        }
    }
}

// MARK: - Editable token map

extension Theme.Palette {
    /// The editable color tokens in display order: a human-readable label paired
    /// with a writable key path into the palette. The Settings theme editor
    /// builds one color well per entry and commits edits generically, so adding
    /// a token to the palette is the only change needed to expose it in the UI.
    /// `name` and derived colors (focusBorder / selection) are intentionally
    /// absent — the former is metadata, the latter derive from `accent`.
    static var editableTokens: [(label: String, keyPath: WritableKeyPath<Theme.Palette, NSColor>)] {
        [
            ("Background", \.bg),
            ("Terminal", \.terminalBg),
            ("Bar Chrome", \.barChrome),
            ("Raised", \.raised),
            ("Hover", \.hover),
            ("Hairline", \.hairline),
            ("Overlay", \.overlay),
            ("Text", \.textPrimary),
            ("Text Dim", \.textDim),
            ("Text Faint", \.textFaint),
            ("Accent", \.accent),
            ("Session Busy", \.sessionBusy),
            ("Needs Input", \.sessionNeedsInput),
            ("Session Done", \.sessionDone),
            ("Failed", \.failed),
        ]
    }

    /// The tokens in `editableTokens` order, for the preview swatch strip.
    var orderedTokenColors: [NSColor] {
        Theme.Palette.editableTokens.map { self[keyPath: $0.keyPath] }
    }
}

// MARK: - Built-in palettes

extension Theme.Palette {
    /// Today's exact token values — the default, so nothing changes out of the box.
    static let suitDark = Theme.Palette(
        name: "Suit Dark",
        bg: Theme.rgb(0x17191D),
        terminalBg: Theme.rgb(0x0E1013),
        barChrome: Theme.rgb(0x1F2228),
        raised: Theme.rgb(0x2A2E36),
        hover: Theme.rgb(0x262A31),
        hairline: Theme.rgb(0x34383F),
        overlay: Theme.rgb(0x23262C),
        textPrimary: Theme.rgb(0xD7DAE0),
        textDim: Theme.rgb(0x8B909C),
        textFaint: Theme.rgb(0x4C515B),
        accent: Theme.rgb(0xD99A3D),
        sessionBusy: Theme.rgb(0xE08A3C),
        sessionNeedsInput: Theme.rgb(0xE5C453),
        sessionDone: Theme.rgb(0x57B36B),
        failed: Theme.rgb(0xD95757)
    )

    /// A cooler, deeper dark with a blue accent.
    static let midnight = Theme.Palette(
        name: "Midnight",
        bg: Theme.rgb(0x0F1420),
        terminalBg: Theme.rgb(0x080B12),
        barChrome: Theme.rgb(0x151B2A),
        raised: Theme.rgb(0x1E273B),
        hover: Theme.rgb(0x1A2233),
        hairline: Theme.rgb(0x2A3448),
        overlay: Theme.rgb(0x18202F),
        textPrimary: Theme.rgb(0xD4DAE6),
        textDim: Theme.rgb(0x838CA3),
        textFaint: Theme.rgb(0x464F63),
        accent: Theme.rgb(0x6C9BE6),
        sessionBusy: Theme.rgb(0xE0913C),
        sessionNeedsInput: Theme.rgb(0xE5C453),
        sessionDone: Theme.rgb(0x5BB37E),
        failed: Theme.rgb(0xE05C6E)
    )

    /// A light palette — proves layout survives a bright theme.
    static let suitLight = Theme.Palette(
        name: "Suit Light",
        bg: Theme.rgb(0xF5F6F8),
        terminalBg: Theme.rgb(0xFBFBFC),
        barChrome: Theme.rgb(0xEBEDF1),
        raised: Theme.rgb(0xFFFFFF),
        hover: Theme.rgb(0xE2E5EA),
        hairline: Theme.rgb(0xD2D6DD),
        overlay: Theme.rgb(0xFFFFFF),
        textPrimary: Theme.rgb(0x1D2026),
        textDim: Theme.rgb(0x5B6270),
        textFaint: Theme.rgb(0x9AA1AE),
        accent: Theme.rgb(0xC07A1F),
        sessionBusy: Theme.rgb(0xC2701E),
        sessionNeedsInput: Theme.rgb(0xB8971C),
        sessionDone: Theme.rgb(0x2F8F4E),
        failed: Theme.rgb(0xC43A3A)
    )

    /// All built-in palettes, in display order. Built-ins always exist and
    /// cannot be edited or deleted (duplicate to get an editable copy).
    static let builtIns: [Theme.Palette] = [suitDark, midnight, suitLight]
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
