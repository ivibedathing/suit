import Cocoa

// The shipped palettes: fourteen complete token sets, split out of Theme.swift so
// that file stays about the token *system* and this one is nothing but color.
//
// Every palette states all 26 tokens explicitly rather than deriving the deep
// ones from a base hue. Generated ramps are what make a theme look synthetic —
// the interesting decisions (how far the terminal ground drops below the chrome,
// whether comments lean warm or cool, how saturated a diff wash can get before
// the code inside it stops reading) don't survive being computed.
//
// Three rules hold across the set, and a new palette should keep them:
//
//  1. **Layering, not a grey ramp.** `terminalBg` sits *below* `bg` and usually
//     carries a hue the near-neutral chrome doesn't. That undertone is what lets
//     an accent sit forward instead of sinking into the background.
//  2. **One accent, borrowed everywhere.** Focus borders, tab ticks, selection,
//     and drop indicators are all `accent` at various alphas, so the accent has
//     to hold up as both a 1pt hairline and a 22%-alpha fill.
//  3. **Syntax against `bg`, not against black.** Comments are the token that
//     goes wrong most often: dim enough to recede, light enough to read.
//
// Order below = order in the Themes list: Suit originals, then familiar palettes
// from other editors, then the light ones.
extension Theme.Palette {

    // MARK: - Suit originals

    /// The default. Near-neutral graphite chrome, blue-violet terminal ground,
    /// amber accent — the values the app shipped with, so nothing changes out of
    /// the box. Its syntax and diff tokens are exactly the constants that used to
    /// be hardcoded in SyntaxHighlighter / DiffPane, so the viewer is unchanged
    /// too; the tokens only make them themeable.
    static let suitDark = Theme.Palette(
        name: "Suit Dark",
        bg: Theme.rgb(0x17191D),
        // The terminal ground carries a blue-violet undertone the near-neutral
        // chrome doesn't: it reads as a deeper layer rather than one more grey,
        // and the cool cast is what makes the amber accent (and warm ANSI
        // yellows/reds) sit forward instead of sinking into the background.
        terminalBg: Theme.rgb(0x0A0C15),
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
        failed: Theme.rgb(0xD95757),
        syntaxKeyword: Theme.rgb(0xC778DE),
        syntaxString: Theme.rgb(0x8AC97D),
        syntaxComment: Theme.rgb(0x858585),
        syntaxNumber: Theme.rgb(0xE6A666),
        syntaxType: Theme.rgb(0x6BC7DB),
        syntaxAttribute: Theme.rgb(0xDBBD69),
        syntaxKey: Theme.rgb(0x73B0F0),
        diffAdded: Theme.rgb(0x8CD98C),
        diffRemoved: Theme.rgb(0xF08580),
        diffAddedBg: Theme.rgba(0x338C40, 0.22),
        diffRemovedBg: Theme.rgba(0xB3332E, 0.22)
    )

    /// Cooler and deeper than Suit Dark: navy chrome over a near-black blue, with
    /// a periwinkle accent. The syntax set leans cool to match, with one warm
    /// number/amber note so literals still stand out.
    static let midnight = Theme.Palette(
        name: "Midnight",
        bg: Theme.rgb(0x0F1420), terminalBg: Theme.rgb(0x05081A), barChrome: Theme.rgb(0x151B2A),
        raised: Theme.rgb(0x1E273B), hover: Theme.rgb(0x1A2233), hairline: Theme.rgb(0x2A3448),
        overlay: Theme.rgb(0x18202F),
        textPrimary: Theme.rgb(0xD4DAE6), textDim: Theme.rgb(0x838CA3), textFaint: Theme.rgb(0x464F63),
        accent: Theme.rgb(0x6C9BE6),
        sessionBusy: Theme.rgb(0xE0913C), sessionNeedsInput: Theme.rgb(0xE5C453),
        sessionDone: Theme.rgb(0x5BB37E), failed: Theme.rgb(0xE05C6E),
        syntaxKeyword: Theme.rgb(0xA78BFA), syntaxString: Theme.rgb(0x7FD1A6),
        syntaxComment: Theme.rgb(0x5A6480), syntaxNumber: Theme.rgb(0xE3A76F),
        syntaxType: Theme.rgb(0x67C7E2), syntaxAttribute: Theme.rgb(0xD7C078),
        syntaxKey: Theme.rgb(0x6C9BE6),
        diffAdded: Theme.rgb(0x74D69C), diffRemoved: Theme.rgb(0xEF7C8E),
        diffAddedBg: Theme.rgba(0x2E9E6B, 0.20), diffRemovedBg: Theme.rgba(0xC03A52, 0.20)
    )

    /// Warm espresso: brown-black grounds, ember-orange accent, an olive/rose
    /// syntax set. One cool token (`syntaxType`, a muted teal) keeps a wall of
    /// warm code from turning into mud — the same trick in reverse from Midnight.
    static let ember = Theme.Palette(
        name: "Ember",
        bg: Theme.rgb(0x1A1412), terminalBg: Theme.rgb(0x0E0908), barChrome: Theme.rgb(0x221A17),
        raised: Theme.rgb(0x2E241F), hover: Theme.rgb(0x291F1B), hairline: Theme.rgb(0x3B2C26),
        overlay: Theme.rgb(0x261D19),
        textPrimary: Theme.rgb(0xE6DAD2), textDim: Theme.rgb(0xA08D82), textFaint: Theme.rgb(0x6B5A52),
        accent: Theme.rgb(0xE08542),
        sessionBusy: Theme.rgb(0xE3762F), sessionNeedsInput: Theme.rgb(0xE8B84B),
        sessionDone: Theme.rgb(0x8FB85F), failed: Theme.rgb(0xDC5B4A),
        syntaxKeyword: Theme.rgb(0xE5799B), syntaxString: Theme.rgb(0xB9C46A),
        syntaxComment: Theme.rgb(0x826C61), syntaxNumber: Theme.rgb(0xE9A45C),
        syntaxType: Theme.rgb(0x79BAA9), syntaxAttribute: Theme.rgb(0xD7B37A),
        syntaxKey: Theme.rgb(0xE8927A),
        diffAdded: Theme.rgb(0xA8C972), diffRemoved: Theme.rgb(0xE8836F),
        diffAddedBg: Theme.rgba(0x6E9A3A, 0.20), diffRemovedBg: Theme.rgba(0xB4472F, 0.20)
    )

    /// Graphite chrome with a verdigris accent — the quietest theme in the set.
    /// Everything is desaturated except the accent and the diff pair, which is
    /// the point: status color is the only thing that shouts.
    static let verdigris = Theme.Palette(
        name: "Verdigris",
        bg: Theme.rgb(0x14181A), terminalBg: Theme.rgb(0x080C0E), barChrome: Theme.rgb(0x1B2124),
        raised: Theme.rgb(0x262E32), hover: Theme.rgb(0x212829), hairline: Theme.rgb(0x2F393D),
        overlay: Theme.rgb(0x1F2629),
        textPrimary: Theme.rgb(0xD2DBDC), textDim: Theme.rgb(0x879497), textFaint: Theme.rgb(0x4A5559),
        accent: Theme.rgb(0x4FB3A5),
        sessionBusy: Theme.rgb(0xD99150), sessionNeedsInput: Theme.rgb(0xDCC65C),
        sessionDone: Theme.rgb(0x52B88C), failed: Theme.rgb(0xD4626A),
        syntaxKeyword: Theme.rgb(0xA3A0E8), syntaxString: Theme.rgb(0x8FCFA0),
        syntaxComment: Theme.rgb(0x5C6A6E), syntaxNumber: Theme.rgb(0xDCA96E),
        syntaxType: Theme.rgb(0x63C4C0), syntaxAttribute: Theme.rgb(0xCFC178),
        syntaxKey: Theme.rgb(0x6FAFD2),
        diffAdded: Theme.rgb(0x78CC9C), diffRemoved: Theme.rgb(0xE07C86),
        diffAddedBg: Theme.rgba(0x2F9E6E, 0.20), diffRemovedBg: Theme.rgba(0xB0424C, 0.20)
    )

    /// Deep plum chrome with a violet accent: the most saturated dark here.
    /// Plum grounds flatten fast, so the layers are spaced a little wider than
    /// in the neutral themes and the hairline is the brightest of the set.
    static let amethyst = Theme.Palette(
        name: "Amethyst",
        bg: Theme.rgb(0x17131F), terminalBg: Theme.rgb(0x0C0814), barChrome: Theme.rgb(0x1E1829),
        raised: Theme.rgb(0x292036), hover: Theme.rgb(0x241D30), hairline: Theme.rgb(0x362B46),
        overlay: Theme.rgb(0x221B2E),
        textPrimary: Theme.rgb(0xE0D8EC), textDim: Theme.rgb(0x9689AB), textFaint: Theme.rgb(0x5B5070),
        accent: Theme.rgb(0xB084F0),
        sessionBusy: Theme.rgb(0xDD8C4C), sessionNeedsInput: Theme.rgb(0xE0C25A),
        sessionDone: Theme.rgb(0x62BE8C), failed: Theme.rgb(0xE0607F),
        syntaxKeyword: Theme.rgb(0xC79BF5), syntaxString: Theme.rgb(0x9BD6A5),
        syntaxComment: Theme.rgb(0x6A5D80), syntaxNumber: Theme.rgb(0xE8A870),
        syntaxType: Theme.rgb(0x7FC6E8), syntaxAttribute: Theme.rgb(0xD7BE72),
        syntaxKey: Theme.rgb(0x7FAEF0),
        diffAdded: Theme.rgb(0x86D6A0), diffRemoved: Theme.rgb(0xEC7C96),
        diffAddedBg: Theme.rgba(0x3AA870, 0.20), diffRemovedBg: Theme.rgba(0xB83E62, 0.20)
    )

    /// True black for OLED displays, and the highest-contrast theme in the set
    /// for bright rooms. `terminalBg` can't go below `bg` here — both are #000000
    /// — so the layering comes from the chrome above them instead, and the
    /// hairline does more work than usual since there are no soft edges.
    static let obsidian = Theme.Palette(
        name: "Obsidian",
        bg: Theme.rgb(0x000000), terminalBg: Theme.rgb(0x000000), barChrome: Theme.rgb(0x0A0A0C),
        raised: Theme.rgb(0x1A1A1E), hover: Theme.rgb(0x121216), hairline: Theme.rgb(0x2E2E34),
        overlay: Theme.rgb(0x101014),
        textPrimary: Theme.rgb(0xF2F3F5), textDim: Theme.rgb(0xA8ACB4), textFaint: Theme.rgb(0x6A6E76),
        accent: Theme.rgb(0x62D2FF),
        sessionBusy: Theme.rgb(0xFFA23D), sessionNeedsInput: Theme.rgb(0xFFD84D),
        sessionDone: Theme.rgb(0x4CE08A), failed: Theme.rgb(0xFF6161),
        syntaxKeyword: Theme.rgb(0xE28BFF), syntaxString: Theme.rgb(0x86E07A),
        syntaxComment: Theme.rgb(0x7E848C), syntaxNumber: Theme.rgb(0xFFB86B),
        syntaxType: Theme.rgb(0x6FE0E0), syntaxAttribute: Theme.rgb(0xFFDD77),
        syntaxKey: Theme.rgb(0x79B8FF),
        diffAdded: Theme.rgb(0x7BE895), diffRemoved: Theme.rgb(0xFF8080),
        diffAddedBg: Theme.rgba(0x1FBF60, 0.22), diffRemovedBg: Theme.rgba(0xE0303A, 0.22)
    )

    // MARK: - Familiar palettes
    //
    // Suit-shaped readings of palettes people already know. The published hues
    // are used as-is (that's the whole point of picking one), but each needs
    // chrome tokens the original never defined — Suit has a tab strip, a raised
    // active tab, a hover state, and a terminal ground below the editor ground,
    // where a plain editor theme has a background and a "current line".

    /// Nord: arctic blue-greys, `nord8` frost as the accent.
    static let nord = Theme.Palette(
        name: "Nord",
        bg: Theme.rgb(0x2E3440), terminalBg: Theme.rgb(0x272B35), barChrome: Theme.rgb(0x333A47),
        raised: Theme.rgb(0x3B4252), hover: Theme.rgb(0x373E4B), hairline: Theme.rgb(0x454E60),
        overlay: Theme.rgb(0x363E4C),
        textPrimary: Theme.rgb(0xD8DEE9), textDim: Theme.rgb(0x9AA5B8), textFaint: Theme.rgb(0x6B7688),
        accent: Theme.rgb(0x88C0D0),
        sessionBusy: Theme.rgb(0xD08770), sessionNeedsInput: Theme.rgb(0xEBCB8B),
        sessionDone: Theme.rgb(0xA3BE8C), failed: Theme.rgb(0xBF616A),
        syntaxKeyword: Theme.rgb(0x81A1C1), syntaxString: Theme.rgb(0xA3BE8C),
        syntaxComment: Theme.rgb(0x616E88), syntaxNumber: Theme.rgb(0xB48EAD),
        syntaxType: Theme.rgb(0x8FBCBB), syntaxAttribute: Theme.rgb(0xEBCB8B),
        syntaxKey: Theme.rgb(0x88C0D0),
        diffAdded: Theme.rgb(0xA3BE8C), diffRemoved: Theme.rgb(0xBF616A),
        diffAddedBg: Theme.rgba(0xA3BE8C, 0.18), diffRemovedBg: Theme.rgba(0xBF616A, 0.20)
    )

    /// Dracula: the classic purple-and-pink dark.
    static let dracula = Theme.Palette(
        name: "Dracula",
        bg: Theme.rgb(0x282A36), terminalBg: Theme.rgb(0x21222C), barChrome: Theme.rgb(0x2E3040),
        raised: Theme.rgb(0x3A3D51), hover: Theme.rgb(0x333648), hairline: Theme.rgb(0x474A5E),
        overlay: Theme.rgb(0x343747),
        textPrimary: Theme.rgb(0xF8F8F2), textDim: Theme.rgb(0xABB2CF), textFaint: Theme.rgb(0x6272A4),
        accent: Theme.rgb(0xBD93F9),
        sessionBusy: Theme.rgb(0xFFB86C), sessionNeedsInput: Theme.rgb(0xF1FA8C),
        sessionDone: Theme.rgb(0x50FA7B), failed: Theme.rgb(0xFF5555),
        syntaxKeyword: Theme.rgb(0xFF79C6), syntaxString: Theme.rgb(0xF1FA8C),
        syntaxComment: Theme.rgb(0x6272A4), syntaxNumber: Theme.rgb(0xBD93F9),
        syntaxType: Theme.rgb(0x8BE9FD), syntaxAttribute: Theme.rgb(0x50FA7B),
        syntaxKey: Theme.rgb(0x8BE9FD),
        diffAdded: Theme.rgb(0x50FA7B), diffRemoved: Theme.rgb(0xFF5555),
        diffAddedBg: Theme.rgba(0x50FA7B, 0.16), diffRemovedBg: Theme.rgba(0xFF5555, 0.18)
    )

    /// Solarized Dark: Ethan Schoonover's fixed sixteen, teal-navy grounds.
    /// Its text ramp is deliberately low-contrast — `base1`/`base0`/`base01` —
    /// which is the palette's signature, not an oversight.
    static let solarizedDark = Theme.Palette(
        name: "Solarized Dark",
        bg: Theme.rgb(0x002B36), terminalBg: Theme.rgb(0x00212B), barChrome: Theme.rgb(0x073642),
        raised: Theme.rgb(0x0E4451), hover: Theme.rgb(0x0A3D49), hairline: Theme.rgb(0x1A5462),
        overlay: Theme.rgb(0x08404E),
        textPrimary: Theme.rgb(0x93A1A1), textDim: Theme.rgb(0x839496), textFaint: Theme.rgb(0x586E75),
        accent: Theme.rgb(0x268BD2),
        sessionBusy: Theme.rgb(0xCB4B16), sessionNeedsInput: Theme.rgb(0xB58900),
        sessionDone: Theme.rgb(0x859900), failed: Theme.rgb(0xDC322F),
        syntaxKeyword: Theme.rgb(0x859900), syntaxString: Theme.rgb(0x2AA198),
        syntaxComment: Theme.rgb(0x586E75), syntaxNumber: Theme.rgb(0xD33682),
        syntaxType: Theme.rgb(0xB58900), syntaxAttribute: Theme.rgb(0x6C71C4),
        syntaxKey: Theme.rgb(0x268BD2),
        diffAdded: Theme.rgb(0x859900), diffRemoved: Theme.rgb(0xDC322F),
        diffAddedBg: Theme.rgba(0x859900, 0.20), diffRemovedBg: Theme.rgba(0xDC322F, 0.20)
    )

    /// Gruvbox (dark, medium): retro warm browns with high-saturation accents.
    static let gruvbox = Theme.Palette(
        name: "Gruvbox",
        bg: Theme.rgb(0x282828), terminalBg: Theme.rgb(0x1D2021), barChrome: Theme.rgb(0x32302F),
        raised: Theme.rgb(0x3C3836), hover: Theme.rgb(0x37332F), hairline: Theme.rgb(0x504945),
        overlay: Theme.rgb(0x35322E),
        textPrimary: Theme.rgb(0xEBDBB2), textDim: Theme.rgb(0xBDAE93), textFaint: Theme.rgb(0x7C6F64),
        accent: Theme.rgb(0xFE8019),
        sessionBusy: Theme.rgb(0xD65D0E), sessionNeedsInput: Theme.rgb(0xFABD2F),
        sessionDone: Theme.rgb(0xB8BB26), failed: Theme.rgb(0xFB4934),
        syntaxKeyword: Theme.rgb(0xFB4934), syntaxString: Theme.rgb(0xB8BB26),
        syntaxComment: Theme.rgb(0x928374), syntaxNumber: Theme.rgb(0xD3869B),
        syntaxType: Theme.rgb(0xFABD2F), syntaxAttribute: Theme.rgb(0x8EC07C),
        syntaxKey: Theme.rgb(0x83A598),
        diffAdded: Theme.rgb(0xB8BB26), diffRemoved: Theme.rgb(0xFB4934),
        diffAddedBg: Theme.rgba(0xB8BB26, 0.16), diffRemovedBg: Theme.rgba(0xFB4934, 0.18)
    )

    /// Tokyo Night: deep indigo grounds, soft pastel syntax.
    static let tokyoNight = Theme.Palette(
        name: "Tokyo Night",
        bg: Theme.rgb(0x1A1B26), terminalBg: Theme.rgb(0x16161E), barChrome: Theme.rgb(0x1F2335),
        raised: Theme.rgb(0x292E42), hover: Theme.rgb(0x24283B), hairline: Theme.rgb(0x343A55),
        overlay: Theme.rgb(0x222436),
        textPrimary: Theme.rgb(0xC0CAF5), textDim: Theme.rgb(0x9AA5CE), textFaint: Theme.rgb(0x565F89),
        accent: Theme.rgb(0x7AA2F7),
        sessionBusy: Theme.rgb(0xFF9E64), sessionNeedsInput: Theme.rgb(0xE0AF68),
        sessionDone: Theme.rgb(0x9ECE6A), failed: Theme.rgb(0xF7768E),
        syntaxKeyword: Theme.rgb(0xBB9AF7), syntaxString: Theme.rgb(0x9ECE6A),
        syntaxComment: Theme.rgb(0x565F89), syntaxNumber: Theme.rgb(0xFF9E64),
        syntaxType: Theme.rgb(0x2AC3DE), syntaxAttribute: Theme.rgb(0xE0AF68),
        syntaxKey: Theme.rgb(0x7DCFFF),
        diffAdded: Theme.rgb(0x9ECE6A), diffRemoved: Theme.rgb(0xF7768E),
        diffAddedBg: Theme.rgba(0x9ECE6A, 0.16), diffRemovedBg: Theme.rgba(0xF7768E, 0.16)
    )

    /// Catppuccin Mocha: lavender-tinted charcoal with the pastel "mauve" accent.
    /// Catppuccin grounds sidebars in `mantle` (*darker* than the editor), so
    /// here `terminalBg` takes `crust` and the bar chrome sits just above `base`.
    static let catppuccinMocha = Theme.Palette(
        name: "Catppuccin Mocha",
        bg: Theme.rgb(0x1E1E2E), terminalBg: Theme.rgb(0x11111B), barChrome: Theme.rgb(0x232336),
        raised: Theme.rgb(0x313244), hover: Theme.rgb(0x2A2A3E), hairline: Theme.rgb(0x45475A),
        overlay: Theme.rgb(0x26263A),
        textPrimary: Theme.rgb(0xCDD6F4), textDim: Theme.rgb(0xA6ADC8), textFaint: Theme.rgb(0x6C7086),
        accent: Theme.rgb(0xCBA6F7),
        sessionBusy: Theme.rgb(0xFAB387), sessionNeedsInput: Theme.rgb(0xF9E2AF),
        sessionDone: Theme.rgb(0xA6E3A1), failed: Theme.rgb(0xF38BA8),
        syntaxKeyword: Theme.rgb(0xCBA6F7), syntaxString: Theme.rgb(0xA6E3A1),
        syntaxComment: Theme.rgb(0x7F849C), syntaxNumber: Theme.rgb(0xFAB387),
        syntaxType: Theme.rgb(0xF9E2AF), syntaxAttribute: Theme.rgb(0x94E2D5),
        syntaxKey: Theme.rgb(0x89B4FA),
        diffAdded: Theme.rgb(0xA6E3A1), diffRemoved: Theme.rgb(0xF38BA8),
        diffAddedBg: Theme.rgba(0xA6E3A1, 0.14), diffRemovedBg: Theme.rgba(0xF38BA8, 0.14)
    )

    // MARK: - Light
    //
    // Light themes invert the layering rule: `terminalBg` is the *brightest*
    // surface, because on light backgrounds depth reads as "closer to paper", and
    // the accent has to darken rather than brighten to stay legible. The syntax
    // sets are picked for contrast against a near-white ground — the same hues
    // used in the dark themes wash out completely here.

    /// Suit Light: the neutral light theme, warmed slightly and re-contrasted.
    /// Its syntax colors are darkened versions of Suit Dark's, not the same hues.
    static let suitLight = Theme.Palette(
        name: "Suit Light",
        bg: Theme.rgb(0xF4F5F8), terminalBg: Theme.rgb(0xFFFFFF), barChrome: Theme.rgb(0xE9EBF0),
        raised: Theme.rgb(0xFFFFFF), hover: Theme.rgb(0xDFE3EA), hairline: Theme.rgb(0xCFD4DE),
        overlay: Theme.rgb(0xFFFFFF),
        textPrimary: Theme.rgb(0x1B1F27), textDim: Theme.rgb(0x565E6E), textFaint: Theme.rgb(0x8F97A6),
        accent: Theme.rgb(0xB87118),
        sessionBusy: Theme.rgb(0xC06A16), sessionNeedsInput: Theme.rgb(0xA8870F),
        sessionDone: Theme.rgb(0x26804A), failed: Theme.rgb(0xC0392F),
        syntaxKeyword: Theme.rgb(0x8B32B0), syntaxString: Theme.rgb(0x227A3D),
        syntaxComment: Theme.rgb(0x8A9098), syntaxNumber: Theme.rgb(0xB3541E),
        syntaxType: Theme.rgb(0x0F6E86), syntaxAttribute: Theme.rgb(0x8A6A0A),
        syntaxKey: Theme.rgb(0x1B5FB8),
        diffAdded: Theme.rgb(0x1F7A3C), diffRemoved: Theme.rgb(0xB03030),
        diffAddedBg: Theme.rgba(0x2FA05A, 0.16), diffRemovedBg: Theme.rgba(0xD04040, 0.14)
    )

    /// Paper: a warm sepia light theme for daylight — cream grounds, sienna
    /// accent, and a syntax set mixed toward earth tones so nothing on the page
    /// reads as screen-blue.
    static let paper = Theme.Palette(
        name: "Paper",
        bg: Theme.rgb(0xF4EFE6), terminalBg: Theme.rgb(0xFCF8F1), barChrome: Theme.rgb(0xEAE3D7),
        raised: Theme.rgb(0xFFFCF6), hover: Theme.rgb(0xE2DACB), hairline: Theme.rgb(0xD6CCBA),
        overlay: Theme.rgb(0xFFFCF6),
        textPrimary: Theme.rgb(0x2A241C), textDim: Theme.rgb(0x6A6055), textFaint: Theme.rgb(0x9C9182),
        accent: Theme.rgb(0xA5652A),
        sessionBusy: Theme.rgb(0xB26A1E), sessionNeedsInput: Theme.rgb(0x94781A),
        sessionDone: Theme.rgb(0x45743A), failed: Theme.rgb(0xA83A32),
        syntaxKeyword: Theme.rgb(0x9B3A6E), syntaxString: Theme.rgb(0x4A7038),
        syntaxComment: Theme.rgb(0x9A8F7F), syntaxNumber: Theme.rgb(0xA85A20),
        syntaxType: Theme.rgb(0x256B72), syntaxAttribute: Theme.rgb(0x86601A),
        syntaxKey: Theme.rgb(0x2E5EA0),
        diffAdded: Theme.rgb(0x3F7A35), diffRemoved: Theme.rgb(0xA63A2E),
        diffAddedBg: Theme.rgba(0x5C9A3A, 0.18), diffRemovedBg: Theme.rgba(0xC0503A, 0.14)
    )

    /// All built-in palettes, in display order. Built-ins always exist and
    /// cannot be edited or deleted (duplicate to get an editable copy).
    static let builtIns: [Theme.Palette] = [
        suitDark, midnight, ember, verdigris, amethyst, obsidian,
        nord, dracula, solarizedDark, gruvbox, tokyoNight, catppuccinMocha,
        suitLight, paper,
    ]

    /// Whether this palette is a light theme, judged from the perceived
    /// brightness of its window ground. Used for the one-word "dark"/"light"
    /// hint in the theme lists — cheaper for a reader to scan than the swatch,
    /// and it works for imported themes that carry no such metadata.
    var isLight: Bool {
        let c = bg.usingColorSpace(.genericRGB) ?? bg
        let luma = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return luma > 0.5
    }
}
