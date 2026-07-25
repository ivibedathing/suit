import Cocoa

// The AppKit half of syntax highlighting: token kind → color, and nothing else.
// The language table and the scanner live in SyntaxLanguages.swift, which is
// Foundation-only so scripts/syntax-highlight-test.sh can compile it standalone.

extension SyntaxTokenKind {
    // A palette tuned for the app's dark terminal backgrounds. Foreground-only,
    // so the pane's translucency/background settings show through untouched.
    var color: NSColor {
        switch self {
        case .keyword: return NSColor(calibratedRed: 0.78, green: 0.47, blue: 0.87, alpha: 1)
        case .string: return NSColor(calibratedRed: 0.54, green: 0.79, blue: 0.49, alpha: 1)
        case .comment: return NSColor(calibratedWhite: 0.52, alpha: 1)
        case .number: return NSColor(calibratedRed: 0.90, green: 0.65, blue: 0.40, alpha: 1)
        case .type: return NSColor(calibratedRed: 0.42, green: 0.78, blue: 0.86, alpha: 1)
        case .attribute: return NSColor(calibratedRed: 0.86, green: 0.74, blue: 0.41, alpha: 1)
        case .key: return NSColor(calibratedRed: 0.45, green: 0.69, blue: 0.94, alpha: 1)
        }
    }
}
