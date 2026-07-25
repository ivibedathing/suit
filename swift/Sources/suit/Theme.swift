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

    /// `didChange` userInfo key holding the palette that was active *before* the
    /// swap. Observers need it to tell "this surface still carries the old
    /// theme's ground, so re-ground it" from "the user picked this color on
    /// purpose, leave it alone" — a distinction the new palette alone can't make.
    static let previousPaletteKey = "previousPalette"

    /// The pre-swap palette out of a `didChange` notification, if it carried one.
    static func previousPalette(from note: Notification) -> Palette? {
        note.userInfo?[previousPaletteKey] as? Palette
    }

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

    /// Global usage readout (5h/7d): a continuous ramp from the done green at
    /// 0, through the busy amber at the halfway mark, to the failed red at the
    /// cap. A gradient rather than thresholds because the number is watched for
    /// *drift* — three buckets look unchanged for 30 points and then jump,
    /// which hides exactly the approach you want to see coming. Interpolating
    /// the palette's own session tokens keeps the ramp theme-aware, and
    /// pivoting through amber avoids the muddy brown a direct green→red blend
    /// crosses.
    static func usageLevelColor(_ pct: Double) -> NSColor {
        let level = min(max(pct, 0), 100)
        return level <= 50
            ? blend(sessionDone, toward: sessionBusy, fraction: level / 50)
            : blend(sessionBusy, toward: failed, fraction: (level - 50) / 50)
    }

    /// `NSColor.blended` returns nil for colors it can't bring into a common
    /// space, so both ends are pinned to device RGB first and the start color
    /// is the fallback.
    private static func blend(_ from: NSColor, toward to: NSColor, fraction: Double) -> NSColor {
        let start = from.usingColorSpace(.deviceRGB) ?? from
        let end = to.usingColorSpace(.deviceRGB) ?? to
        return start.blended(withFraction: CGFloat(fraction), of: end) ?? from
    }

    /// Context-window fill %: neutral until 70, amber to 90, red past it.
    static func contextLevelColor(_ pct: Double) -> NSColor {
        pct >= 90 ? failed : pct >= 70 ? sessionBusy : textFaint
    }

    // MARK: - Syntax
    //
    // Code color, one token per `SyntaxTokenKind` (see SyntaxHighlighter.swift,
    // which is now nothing but the mapping). Foreground-only, so a pane's
    // background/translucency shows through untouched — and because the file
    // viewer, the markdown code blocks, the definition peek, and the minimap all
    // render through the same kinds, a theme recolors every one of them at once.

    static var syntaxKeyword: NSColor { current.syntaxKeyword }
    static var syntaxString: NSColor { current.syntaxString }
    static var syntaxComment: NSColor { current.syntaxComment }
    static var syntaxNumber: NSColor { current.syntaxNumber }
    static var syntaxType: NSColor { current.syntaxType }
    static var syntaxAttribute: NSColor { current.syntaxAttribute }
    static var syntaxKey: NSColor { current.syntaxKey }

    /// The six commit-graph lane colors, borrowed from tokens rather than owned:
    /// a graph drawn in fixed hex looked wrong the moment a light theme landed.
    /// Ordered so adjacent lanes stay distinguishable.
    static var graphLanes: [NSColor] {
        [accent, sessionDone, syntaxKey, syntaxKeyword, syntaxType, sessionBusy]
    }

    // MARK: - Diff
    //
    // Added/removed line color, foreground plus the row wash behind it. The two
    // background tokens carry alpha on purpose (`#RRGGBBAA`) — they composite
    // over whatever the pane's background is, including a custom or translucent
    // one, instead of punching an opaque band through it.

    static var diffAdded: NSColor { current.diffAdded }
    static var diffRemoved: NSColor { current.diffRemoved }
    static var diffAddedBg: NSColor { current.diffAddedBg }
    static var diffRemovedBg: NSColor { current.diffRemovedBg }
    /// `@@` hunk headers — the one structural color in a diff, so it reuses the
    /// type token rather than adding a near-duplicate to every palette.
    static var diffHeader: NSColor { syntaxType }
    /// `diff --git` / `index` / `+++` preamble lines, and "No changes."
    static var diffMeta: NSColor { textDim }
    /// The side-by-side filler behind a line that exists on only one side.
    static var diffFiller: NSColor { hairline.withAlphaComponent(0.28) }

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

    /// 0xRRGGBB → NSColor. Internal (not fileprivate) so color tables outside
    /// this file — the pane background presets in `Pane.swift` — can state their
    /// values as hex too, rather than re-deriving the same three divisions.
    static func rgb(_ hex: Int) -> NSColor {
        rgba(hex, 1)
    }

    /// 0xRRGGBB + alpha → NSColor. Only the diff row washes use this: they have
    /// to composite over the pane background, so their alpha is part of the token
    /// (and survives a round-trip through the palette's `#RRGGBBAA` encoding).
    static func rgba(_ hex: Int, _ alpha: CGFloat) -> NSColor {
        NSColor(
            calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
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

        // Syntax (one per SyntaxTokenKind)
        var syntaxKeyword: NSColor
        var syntaxString: NSColor
        var syntaxComment: NSColor
        var syntaxNumber: NSColor
        var syntaxType: NSColor
        var syntaxAttribute: NSColor
        var syntaxKey: NSColor

        // Diff (the two backgrounds are translucent washes — see Theme.diffAddedBg)
        var diffAdded: NSColor
        var diffRemoved: NSColor
        var diffAddedBg: NSColor
        var diffRemovedBg: NSColor

        // MARK: Codable ("#RRGGBB[AA]" strings, per-token fallback to suitDark)
        //
        // `init(from:)` lives in an extension below so the struct body declares
        // no initializer and Swift keeps synthesizing the memberwise
        // `init(name:bg:…)` the built-ins are constructed with.

        enum CodingKeys: String, CodingKey {
            case name, bg, terminalBg, barChrome, raised, hover, hairline, overlay
            case textPrimary, textDim, textFaint
            case accent, sessionBusy, sessionNeedsInput, sessionDone, failed
            case syntaxKeyword, syntaxString, syntaxComment, syntaxNumber
            case syntaxType, syntaxAttribute, syntaxKey
            case diffAdded, diffRemoved, diffAddedBg, diffRemovedBg
        }

        /// Encode every color token from the one table (`colorTokens`), so a token
        /// added to the palette can't be half-wired: it serializes, decodes, and
        /// appears in the editor from a single declaration.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            for token in Palette.colorTokens {
                try c.encode(Palette.hex(self[keyPath: token.keyPath]), forKey: token.key)
            }
        }

        /// Parse "#RRGGBB" / "RRGGBB" / "#RRGGBBAA" (case-insensitive, optional
        /// leading '#'). The 8-digit form carries alpha, which the diff row washes
        /// need; anything that isn't exactly six or eight hex digits returns nil.
        static func colorFromHex(_ raw: String) -> NSColor? {
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("#") { s.removeFirst() }
            guard s.count == 6 || s.count == 8, let v = Int(s, radix: 16) else { return nil }
            if s.count == 6 { return Theme.rgb(v) }
            return Theme.rgba(v >> 8, CGFloat(v & 0xFF) / 255)
        }

        /// Serialize a color as an uppercase "#RRGGBB" string — or "#RRGGBBAA"
        /// when it is translucent, so the wash tokens round-trip their alpha
        /// while every opaque token keeps the shorter, familiar form. Colors are
        /// normalized through genericRGB first so a color coming from a color
        /// well (device RGB) or a built-in (calibrated RGB) yields stable
        /// components; the built-in tokens round-trip byte-identical.
        static func hex(_ color: NSColor) -> String {
            let c = color.usingColorSpace(.genericRGB) ?? color
            let r = Int((c.redComponent * 255).rounded())
            let g = Int((c.greenComponent * 255).rounded())
            let b = Int((c.blueComponent * 255).rounded())
            let a = Int((c.alphaComponent * 255).rounded())
            if a >= 255 { return String(format: "#%02X%02X%02X", r, g, b) }
            return String(format: "#%02X%02X%02X%02X", r, g, b, a)
        }
    }
}

// MARK: - Decodable (per-token fallback to suitDark)

extension Theme.Palette {
    /// Start from Suit Dark and overwrite only the tokens the file actually
    /// carries. That *is* the per-token fallback: a partial theme (or one written
    /// by an older Suit that predates the syntax and diff tokens) decodes to a
    /// complete, coherent palette instead of a half-black one, and an unparseable
    /// hex leaves its token at the default rather than failing the whole file.
    init(from decoder: Decoder) throws {
        self = Self.suitDark
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let decodedName = try? c.decode(String.self, forKey: .name) { name = decodedName }
        for token in Self.colorTokens {
            guard let raw = try? c.decode(String.self, forKey: token.key),
                  let parsed = Self.colorFromHex(raw) else { continue }
            self[keyPath: token.keyPath] = parsed
        }
    }
}

// MARK: - Token map

extension Theme.Palette {
    /// One color token: its on-disk key, the editor group it belongs to, a
    /// human-readable label, and a writable key path into the palette. This table
    /// is the palette's single source of truth — Codable walks it, and the
    /// Settings theme editor builds one grouped color well per entry — so adding
    /// a token here is all it takes to make it serializable *and* editable.
    /// `name` and derived colors (focusBorder / selection / diff header) are
    /// intentionally absent: the former is metadata, the latter derive from other
    /// tokens so a theme can't contradict itself.
    struct TokenSpec {
        let key: CodingKeys
        let group: String
        let label: String
        let keyPath: WritableKeyPath<Theme.Palette, NSColor>
    }

    static let colorTokens: [TokenSpec] = [
        TokenSpec(key: .bg, group: "Chrome", label: "Background", keyPath: \.bg),
        TokenSpec(key: .terminalBg, group: "Chrome", label: "Terminal", keyPath: \.terminalBg),
        TokenSpec(key: .barChrome, group: "Chrome", label: "Bar Chrome", keyPath: \.barChrome),
        TokenSpec(key: .raised, group: "Chrome", label: "Raised", keyPath: \.raised),
        TokenSpec(key: .hover, group: "Chrome", label: "Hover", keyPath: \.hover),
        TokenSpec(key: .hairline, group: "Chrome", label: "Hairline", keyPath: \.hairline),
        TokenSpec(key: .overlay, group: "Chrome", label: "Overlay", keyPath: \.overlay),
        TokenSpec(key: .textPrimary, group: "Text", label: "Text", keyPath: \.textPrimary),
        TokenSpec(key: .textDim, group: "Text", label: "Text Dim", keyPath: \.textDim),
        TokenSpec(key: .textFaint, group: "Text", label: "Text Faint", keyPath: \.textFaint),
        TokenSpec(key: .accent, group: "Accent & Status", label: "Accent", keyPath: \.accent),
        TokenSpec(key: .sessionBusy, group: "Accent & Status", label: "Session Busy", keyPath: \.sessionBusy),
        TokenSpec(key: .sessionNeedsInput, group: "Accent & Status", label: "Needs Input", keyPath: \.sessionNeedsInput),
        TokenSpec(key: .sessionDone, group: "Accent & Status", label: "Session Done", keyPath: \.sessionDone),
        TokenSpec(key: .failed, group: "Accent & Status", label: "Failed", keyPath: \.failed),
        TokenSpec(key: .syntaxKeyword, group: "Syntax", label: "Keyword", keyPath: \.syntaxKeyword),
        TokenSpec(key: .syntaxString, group: "Syntax", label: "String", keyPath: \.syntaxString),
        TokenSpec(key: .syntaxComment, group: "Syntax", label: "Comment", keyPath: \.syntaxComment),
        TokenSpec(key: .syntaxNumber, group: "Syntax", label: "Number", keyPath: \.syntaxNumber),
        TokenSpec(key: .syntaxType, group: "Syntax", label: "Type", keyPath: \.syntaxType),
        TokenSpec(key: .syntaxAttribute, group: "Syntax", label: "Attribute", keyPath: \.syntaxAttribute),
        TokenSpec(key: .syntaxKey, group: "Syntax", label: "Key / Prop", keyPath: \.syntaxKey),
        TokenSpec(key: .diffAdded, group: "Diff", label: "Added", keyPath: \.diffAdded),
        TokenSpec(key: .diffRemoved, group: "Diff", label: "Removed", keyPath: \.diffRemoved),
        TokenSpec(key: .diffAddedBg, group: "Diff", label: "Added Wash", keyPath: \.diffAddedBg),
        TokenSpec(key: .diffRemovedBg, group: "Diff", label: "Removed Wash", keyPath: \.diffRemovedBg),
    ]

    /// The editable tokens, in editor display order — the same table Codable
    /// walks, so the two can never disagree about what a theme contains.
    static var editableTokens: [TokenSpec] { colorTokens }

    /// `colorTokens` cut into consecutive runs of the same `group`, for the
    /// editor's grouped layout. Derived by scanning the table in order (rather
    /// than bucketing by name) so the flat token order and the grouped order are
    /// the same sequence — the Settings wells are index-aligned with
    /// `editableTokens`, and a regrouping that reordered them would silently
    /// point every well at the wrong token.
    static var tokenGroups: [(name: String, tokens: [TokenSpec])] {
        var groups: [(name: String, tokens: [TokenSpec])] = []
        for token in colorTokens {
            if groups.last?.name == token.group {
                groups[groups.count - 1].tokens.append(token)
            } else {
                groups.append((name: token.group, tokens: [token]))
            }
        }
        return groups
    }

    /// The tokens in `colorTokens` order, for the preview's swatch strip.
    var orderedTokenColors: [NSColor] {
        Theme.Palette.colorTokens.map { self[keyPath: $0.keyPath] }
    }
}

// The built-in palettes themselves live in Theme+Palettes.swift — one file of
// color, so this one stays about the token *system*.

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
