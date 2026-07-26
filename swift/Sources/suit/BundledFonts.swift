import CoreText
import Foundation

// Hack ships *inside* Suit, so the app looks the same on a machine where the
// user has never installed a coding font. Four TTFs (Regular/Bold/Italic/
// BoldItalic, v3.003, MIT + Bitstream Vera) live in Resources/fonts/ and are
// registered into this process at launch, before the AppDelegate is built.
//
// Why register in code rather than declare `ATSApplicationFontsPath` in
// Info.plist: the plist key only works for a real .app bundle, and the inner
// dev loop from CLAUDE.md (`swiftc … -o /tmp/suit-shell-$TASK`) produces a bare
// executable with no bundle at all. Rendering the design reference goes through
// that same bare binary — so a plist-only registration would silently draw the
// committed reference PNG in SF Mono while the shipped app drew Hack. One code
// path that works in both is worth the dozen lines.
//
// Deliberately Foundation + CoreText only (no AppKit, no app types) so
// scripts/bundled-fonts-test.sh can compile it standalone.
enum BundledFonts {
    // The PostScript name — what NSFont(name:) wants, not the family name.
    // Verified against the registered descriptors: family "Hack", PostScript
    // names Hack-Regular / Hack-Bold / Hack-Italic / Hack-BoldItalic. The three
    // non-regular faces matter because SwiftTerm's FontSet derives bold and
    // italic from the base font via NSFontManager traits.
    static let regularName = "Hack-Regular"
    static let familyName = "Hack"
    static let fileNames = ["Hack-Regular", "Hack-Bold", "Hack-Italic", "Hack-BoldItalic"]

    // The font name Suit persisted for everyone who never opened the font
    // picker, across the versions that predate this file. `.AppleSystemUIFont…`
    // is what NSFont.monospacedSystemFont resolves to today (it was SwiftTerm's
    // FontSet.defaultFont, and therefore ours); the rest are the same "I took
    // whatever the app gave me" answer from older macOS or an older default.
    // A persisted name outside this set is a real choice and is never touched.
    static let inheritedDefaultNames: Set<String> = [
        ".AppleSystemUIFontMonospaced-Regular",
        ".SFNSMono-Regular",
        "SFMono-Regular",
        "Menlo-Regular",
        "Menlo Regular",
    ]

    // Which font name the app should start with. Pure so the migration rule is
    // testable: the interesting case is an *existing* install, where
    // `fontName` was already written to UserDefaults long before Hack shipped.
    //
    // - No persisted name (fresh install) → Hack.
    // - A persisted name the user never chose, and we haven't migrated yet →
    //   Hack, once. `migrated` then latches true, so a user who deliberately
    //   switches back to SF Mono afterwards keeps it.
    // - Anything else → exactly what was persisted.
    static func resolvedFontName(persisted: String?, migrated: Bool) -> String {
        guard let persisted, !persisted.isEmpty else { return regularName }
        if !migrated && inheritedDefaultNames.contains(persisted) { return regularName }
        return persisted
    }

    // The TTFs, wherever this binary can find them: the app bundle's
    // Resources/fonts when running as Suit.app, else the checkout the binary
    // was compiled from. `#filePath` points at this source file, so the second
    // branch resolves swift/Sources/suit/ → the repo root → Resources/fonts,
    // which is what keeps the dev loop and design renders on the shipped font.
    static func fontURLs(resourceURL: URL?) -> [URL] {
        let candidates = [
            resourceURL?.appendingPathComponent("fonts"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // suit/
                .deletingLastPathComponent()   // Sources/
                .deletingLastPathComponent()   // swift/
                .deletingLastPathComponent()   // repo root
                .appendingPathComponent("Resources/fonts"),
        ].compactMap { $0 }

        for dir in candidates {
            let urls = fileNames.map { dir.appendingPathComponent("\($0).ttf") }
            if urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) { return urls }
        }
        return []
    }

    // Whether `regularName` resolves in this process. Asked *after* registering
    // rather than trusting a return code: CTFontCreateWithName never fails, it
    // substitutes — so the only honest test is whether the font that came back
    // is the one we asked for. It also makes an already-installed system-wide
    // Hack a success rather than a duplicate-registration error.
    static var isAvailable: Bool {
        let font = CTFontCreateWithName(regularName as CFString, 12, nil)
        return (CTFontCopyPostScriptName(font) as String) == regularName
    }

    // Registers the bundled faces for this process. Failure is survivable —
    // callers fall back to the system monospaced font — so this reports rather
    // than throws.
    @discardableResult
    static func register(resourceURL: URL?) -> Bool {
        if isAvailable { return true }
        let urls = fontURLs(resourceURL: resourceURL)
        guard !urls.isEmpty else { return false }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, false, nil)
        return isAvailable
    }

    // The one call sites should use: `static let` makes it run exactly once,
    // lazily and thread-safely, no matter how many entry points ask. There is
    // more than one — main.swift for the app, and AppDelegate's own
    // initializer for the harnesses that build a delegate directly without
    // main.swift (design/reference/main.swift renders the committed reference
    // PNG that way, and would otherwise draw in a font the app never ships).
    @discardableResult
    static func ensureRegistered() -> Bool { registered }

    private static let registered: Bool = register(resourceURL: Bundle.main.resourceURL)
}
