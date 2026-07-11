import Foundation
import Cocoa

// Standalone assertions for the shareable-themes core (Theme.swift +
// ThemeStore.swift), compiled by scripts/test-themes.sh against a scratch
// $HOME. Covers the .suittheme (de)serialization (partial decode with per-token
// fallback, unknown-key tolerance, export->import round-trip), the hex parser
// edge cases, and the ThemeStore catalog operations (duplicate produces an
// independent editable copy; delete removes only user themes). All logic here
// depends only on Theme.swift + ThemeStore.swift + system frameworks — no app.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

// Compare two palettes by their canonical "#RRGGBB" token set (Palette isn't
// Equatable, and NSColor equality is color-space sensitive).
func colors(_ p: Theme.Palette) -> [String] {
    [p.bg, p.terminalBg, p.barChrome, p.raised, p.hover, p.hairline, p.overlay,
     p.textPrimary, p.textDim, p.textFaint,
     p.accent, p.sessionBusy, p.sessionNeedsInput, p.sessionDone, p.failed]
        .map(Theme.Palette.hex)
}
func sameColors(_ a: Theme.Palette, _ b: Theme.Palette) -> Bool { colors(a) == colors(b) }

let d = Theme.Palette.suitDark

// MARK: - Hex parsing edge cases

print("== hex parsing ==")
do {
    check(Theme.Palette.colorFromHex("#1A2B3C") != nil, "leading # parses")
    check(Theme.Palette.colorFromHex("1A2B3C") != nil, "missing # parses")
    check(Theme.Palette.colorFromHex("  #ffffff  ") != nil, "surrounding whitespace tolerated")
    // Case-insensitive: upper and lower hex give the same color.
    check(Theme.Palette.hex(Theme.Palette.colorFromHex("aabbcc")!) ==
          Theme.Palette.hex(Theme.Palette.colorFromHex("AABBCC")!),
          "hex is case-insensitive")
    // Round-trip a known value.
    if let c = Theme.Palette.colorFromHex("#D99A3D") {
        check(Theme.Palette.hex(c) == "#D99A3D", "parse->hex round-trips a known value")
    } else { check(false, "known value parsed") }
    // Invalid forms return nil.
    check(Theme.Palette.colorFromHex("#12345") == nil, "wrong length (5) rejected")
    check(Theme.Palette.colorFromHex("#1234567") == nil, "wrong length (7) rejected")
    check(Theme.Palette.colorFromHex("") == nil, "empty string rejected")
    check(Theme.Palette.colorFromHex("#ZZZZZZ") == nil, "non-hex chars rejected")
    check(Theme.Palette.colorFromHex("#12 34 56") == nil, "internal spaces rejected")
}

// MARK: - Partial-theme decode with per-token fallback

print("== partial decode + fallback ==")
do {
    // A theme file that sets only a couple of tokens and includes an invalid
    // hex for one of them. Everything unset (or invalid) must fall back to the
    // Suit Dark default for that specific token.
    let json = """
    {
      "name": "Partial",
      "author": "tester",
      "schema": 1,
      "colors": {
        "accent": "#123456",
        "bg": "not-a-color"
      }
    }
    """
    let file = try! JSONDecoder().decode(ThemeFile.self, from: Data(json.utf8))
    check(file.palette.name == "Partial", "top-level name wins")
    check(file.author == "tester", "author decoded")
    check(file.schema == 1, "schema decoded")
    check(Theme.Palette.hex(file.palette.accent) == "#123456", "set token (accent) applied")
    check(Theme.Palette.hex(file.palette.bg) == Theme.Palette.hex(d.bg),
          "invalid-hex token (bg) falls back to default")
    check(Theme.Palette.hex(file.palette.terminalBg) == Theme.Palette.hex(d.terminalBg),
          "absent token (terminalBg) falls back to default")
    check(Theme.Palette.hex(file.palette.failed) == Theme.Palette.hex(d.failed),
          "absent token (failed) falls back to default")
}

// MARK: - Unknown-key tolerance

print("== unknown-key tolerance ==")
do {
    // Unknown top-level keys AND unknown color keys are ignored; known tokens
    // still decode.
    let json = """
    {
      "name": "Future",
      "author": "tester",
      "schema": 99,
      "wallpaper": "cosmic",
      "colors": {
        "accent": "#ABCDEF",
        "cursorGlow": "#FF00FF",
        "bloomRadius": 42
      }
    }
    """
    let file = try! JSONDecoder().decode(ThemeFile.self, from: Data(json.utf8))
    check(file.palette.name == "Future", "decodes despite unknown top-level key")
    check(file.schema == 99, "forward schema value preserved")
    check(Theme.Palette.hex(file.palette.accent) == "#ABCDEF", "known color survives unknown siblings")
    check(Theme.Palette.hex(file.palette.bg) == Theme.Palette.hex(d.bg), "unset token still defaults")
}

// MARK: - ThemeStore: launch selection defaults to a built-in

print("== store launch/default ==")
let store = ThemeStore.shared
do {
    store.applySelectedThemeAtLaunch()
    check(store.selected.isBuiltIn, "fresh $HOME: selection defaults to a built-in")
    check(sameColors(Theme.current, store.selected.palette), "Theme.current matches the selection")
    check(store.allThemes.count == Theme.Palette.builtIns.count,
          "fresh store lists exactly the built-ins")
    check(store.allThemes.allSatisfy { $0.isBuiltIn }, "all built-ins, no user themes yet")
}

// MARK: - apply persists selection

print("== apply + persist ==")
do {
    let midnightId = ThemeStore.slug("Midnight")
    check(store.apply(id: midnightId), "apply(Midnight) succeeds")
    check(store.selectedId == midnightId, "selectedId updated")
    check(sameColors(Theme.current, Theme.Palette.midnight), "Theme.current is Midnight")
    check(!store.apply(id: "no-such-theme"), "apply(unknown) is a no-op returning false")
    check(store.selectedId == midnightId, "unknown apply left selection unchanged")
}

// MARK: - duplicate produces an independent editable copy

print("== duplicate ==")
do {
    let before = store.allThemes.count
    guard let dup = store.duplicate(id: ThemeStore.slug("Suit Dark")) else {
        check(false, "duplicate returned a theme"); exit(1)
    }
    check(!dup.isBuiltIn, "duplicate is a user theme (editable)")
    check(dup.id != ThemeStore.slug("Suit Dark"), "duplicate has a distinct id")
    check(dup.palette.name == "Suit Dark Copy", "duplicate is named '<name> Copy'")
    check(sameColors(dup.palette, Theme.Palette.suitDark), "duplicate starts with the source's colors")
    check(store.allThemes.count == before + 1, "duplicate added one theme to the catalog")

    // Editing the copy must NOT change the built-in it came from.
    var edited = dup
    edited.palette.accent = Theme.Palette.colorFromHex("#00FF00")!
    edited.palette.name = "My Green"
    store.update(edited)
    let reloadedDup = store.theme(id: dup.id)
    check(reloadedDup != nil, "edited user theme still present after update")
    check(Theme.Palette.hex(reloadedDup!.palette.accent) == "#00FF00", "edit persisted to disk")
    check(reloadedDup!.palette.name == "My Green", "rename persisted (id stays stable)")
    // The built-in is untouched.
    let builtIn = store.theme(id: ThemeStore.slug("Suit Dark"))!
    check(sameColors(builtIn.palette, Theme.Palette.suitDark),
          "source built-in unchanged after editing the copy")
    check(builtIn.isBuiltIn, "source is still a built-in")
}

// MARK: - built-ins are immutable via update/delete

print("== built-in immutability ==")
do {
    let suitDarkId = ThemeStore.slug("Suit Dark")
    var tampered = store.theme(id: suitDarkId)!
    tampered.palette.accent = Theme.Palette.colorFromHex("#000000")!
    store.update(tampered)  // built-in -> ignored
    check(sameColors(store.theme(id: suitDarkId)!.palette, Theme.Palette.suitDark),
          "update() on a built-in is ignored")
    let countBefore = store.allThemes.count
    store.delete(id: suitDarkId)  // built-in -> ignored
    check(store.allThemes.count == countBefore, "delete() on a built-in is ignored")
    check(store.theme(id: suitDarkId) != nil, "built-in still present")
}

// MARK: - export -> import round-trip equality

print("== export/import round-trip ==")
do {
    // Export a user theme (the edited green copy) and re-import it; the palette
    // must survive byte-for-byte across the .suittheme file.
    let green = store.allThemes.first { !$0.isBuiltIn }!
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("roundtrip-\(UUID().uuidString).suittheme")
    check(store.exportTheme(id: green.id, to: tmp), "exportTheme writes the file")

    guard let imported = store.importTheme(from: tmp) else {
        check(false, "importTheme decoded the file"); exit(1)
    }
    check(!imported.isBuiltIn, "imported theme is a user theme")
    check(imported.id != green.id, "import gets a fresh, unique id (no overwrite)")
    check(sameColors(imported.palette, green.palette), "colors survive export->import unchanged")
    check(imported.palette.name == green.palette.name, "name survives export->import")
    check(imported.author == green.author, "author survives export->import")
    try? FileManager.default.removeItem(at: tmp)
}

// MARK: - delete removes only user themes

print("== delete user theme ==")
do {
    let userThemes = store.allThemes.filter { !$0.isBuiltIn }
    check(!userThemes.isEmpty, "there are user themes to delete")
    let victim = userThemes[0]
    let before = store.allThemes.count
    store.delete(id: victim.id)
    check(store.theme(id: victim.id) == nil, "deleted user theme is gone")
    check(store.allThemes.count == before - 1, "catalog shrank by exactly one")
    check(store.allThemes.contains { $0.isBuiltIn }, "built-ins remain after deleting a user theme")

    // Deleting the *selected* user theme falls back to a built-in.
    if let another = store.allThemes.first(where: { !$0.isBuiltIn }) {
        store.apply(id: another.id)
        check(store.selectedId == another.id, "selected the user theme")
        store.delete(id: another.id)
        check(store.selected.isBuiltIn, "deleting the selected theme falls back to a built-in")
    }
}

if failures == 0 {
    print("\nALL PASS")
    exit(0)
} else {
    print("\n\(failures) FAILURE(S)")
    exit(1)
}
