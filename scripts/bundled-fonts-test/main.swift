import CoreText
import Foundation

// Assertions for BundledFonts: the one-shot migration rule that decides which
// font name an existing install starts with, and the discovery + registration
// of the four bundled Hack faces. Compiled by scripts/bundled-fonts-test.sh
// against swift/Sources/suit/BundledFonts.swift alone — no app, no AppKit.

var failures = 0

func check(_ label: String, _ condition: Bool) {
    if condition {
        print("ok: \(label)")
    } else {
        print("FAIL: \(label)")
        failures += 1
    }
}

func equal(_ label: String, _ actual: String, _ expected: String) {
    check("\(label) (got \(actual), want \(expected))", actual == expected)
}

// --- resolvedFontName: fresh install -----------------------------------
// Nothing persisted at all, migrated flag either way: Hack is the default.
equal("no persisted font -> Hack",
      BundledFonts.resolvedFontName(persisted: nil, migrated: false), "Hack-Regular")
equal("no persisted font, already migrated -> Hack",
      BundledFonts.resolvedFontName(persisted: nil, migrated: true), "Hack-Regular")
equal("empty persisted font -> Hack",
      BundledFonts.resolvedFontName(persisted: "", migrated: false), "Hack-Regular")

// --- resolvedFontName: existing install, never picked a font -----------
// Every name in the inherited set is "whatever the app gave me", so the first
// post-Hack launch replaces it. This is the case that matters: saveSettings
// has been writing fontName on every change since long before Hack shipped,
// so the key exists for everyone and its mere presence proves nothing.
for name in BundledFonts.inheritedDefaultNames {
    equal("inherited default \(name) migrates once",
          BundledFonts.resolvedFontName(persisted: name, migrated: false), "Hack-Regular")
    equal("inherited default \(name) is kept after migrating",
          BundledFonts.resolvedFontName(persisted: name, migrated: true), name)
}

// --- resolvedFontName: a real choice is never touched ------------------
for name in ["JetBrainsMono-Regular", "Monaco", "Courier", "Hack-Bold", "Menlo-Bold"] {
    equal("chosen font \(name) survives migration",
          BundledFonts.resolvedFontName(persisted: name, migrated: false), name)
    equal("chosen font \(name) survives after migration",
          BundledFonts.resolvedFontName(persisted: name, migrated: true), name)
}

// A user who deliberately switches back to SF Mono keeps it, because the flag
// has latched by then — the exact regression the flag exists to prevent.
equal("deliberate switch back to SF Mono is not re-migrated",
      BundledFonts.resolvedFontName(persisted: ".AppleSystemUIFontMonospaced-Regular", migrated: true),
      ".AppleSystemUIFontMonospaced-Regular")

// --- fontURLs ----------------------------------------------------------
// No bundle resource dir (the bare `swiftc` dev binary) still finds the four
// faces via the #filePath fallback into the checkout this file came from.
let devURLs = BundledFonts.fontURLs(resourceURL: nil)
check("dev fallback finds 4 faces (got \(devURLs.count))", devURLs.count == 4)
check("dev fallback resolves Regular",
      devURLs.contains { $0.lastPathComponent == "Hack-Regular.ttf" })
check("dev fallback files all exist",
      devURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

// A resource dir without a fonts/ subdir falls through to the same fallback
// rather than returning half a font set.
let empty = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("suit-fonts-absent")
check("missing bundle fonts dir falls back, never returns a partial set",
      BundledFonts.fontURLs(resourceURL: empty).count == 4)

// A bundle whose Resources/fonts is populated wins over the checkout.
let staged = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("suit-fonts-test-\(ProcessInfo.processInfo.processIdentifier)")
let stagedFonts = staged.appendingPathComponent("fonts")
try? FileManager.default.createDirectory(at: stagedFonts, withIntermediateDirectories: true)
for name in BundledFonts.fileNames {
    try? Data().write(to: stagedFonts.appendingPathComponent("\(name).ttf"))
}
let bundleURLs = BundledFonts.fontURLs(resourceURL: staged)
check("bundle Resources/fonts wins over the checkout",
      bundleURLs.allSatisfy { $0.path.hasPrefix(stagedFonts.path) })
try? FileManager.default.removeItem(at: staged)

// --- register ----------------------------------------------------------
// The real payoff: after registering, "Hack-Regular" resolves to Hack and not
// to a silent CoreText substitution, and the bold/italic faces are there for
// SwiftTerm's FontSet to derive from.
check("register() succeeds", BundledFonts.register(resourceURL: nil))
check("Hack-Regular is available after register()", BundledFonts.isAvailable)
for face in BundledFonts.fileNames {
    let font = CTFontCreateWithName(face as CFString, 12, nil)
    equal("\(face) resolves to itself", CTFontCopyPostScriptName(font) as String, face)
}
let hack = CTFontCreateWithName(BundledFonts.regularName as CFString, 12, nil)
equal("family name", CTFontCopyFamilyName(hack) as String, BundledFonts.familyName)
check("Hack is monospaced",
      CTFontGetSymbolicTraits(hack).contains(.traitMonoSpace))

// register() is idempotent — main.swift runs it once, but a second call (or a
// user with Hack installed system-wide) must not turn into a failure.
check("register() is idempotent", BundledFonts.register(resourceURL: nil))

// ensureRegistered() is what the app actually calls, from two entry points.
check("ensureRegistered() succeeds", BundledFonts.ensureRegistered())
check("ensureRegistered() is idempotent", BundledFonts.ensureRegistered())

if failures > 0 {
    print("\n\(failures) assertion(s) failed")
    exit(1)
}
print("\nall bundled-font assertions passed")
