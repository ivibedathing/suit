import Cocoa

// The AppKit half of syntax highlighting: token kind → color, and nothing else.
// The language table and the scanner live in SyntaxLanguages.swift, which is
// Foundation-only so scripts/syntax-highlight-test.sh can compile it standalone.

extension SyntaxTokenKind {
    // One theme token per kind (Theme.syntax*), read live at attribute time so a
    // theme switch recolors code everywhere it is rendered — the file viewer, the
    // minimap, markdown code blocks, and the definition peek. Foreground-only, so
    // the pane's translucency/background settings show through untouched.
    var color: NSColor {
        switch self {
        case .keyword: return Theme.syntaxKeyword
        case .string: return Theme.syntaxString
        case .comment: return Theme.syntaxComment
        case .number: return Theme.syntaxNumber
        case .type: return Theme.syntaxType
        case .attribute: return Theme.syntaxAttribute
        case .key: return Theme.syntaxKey
        }
    }
}
