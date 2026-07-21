import Foundation

// The UI-free core behind the file’s symbol outline (⌃⌘O) and the breadcrumb
// above the text. Foundation-only, compiled standalone by
// scripts/editor-nav-test.sh alongside SymbolIndexCore and NavigationHistory.
//
// The input is the same ctags output go-to-definition already builds — so the
// outline costs nothing extra to produce — narrowed to one file and given a
// nesting depth. ctags reports a scope for some languages and not others, so
// depth is derived from the *indentation of the defining line* instead: it is
// available for every language, it never disagrees with what the user sees on
// screen, and being wrong about it is cosmetic (a row indented one step too
// far), not navigational.

struct OutlineEntry: Equatable {
    let name: String
    let kind: String?       // ctags' kind, e.g. "function", "struct", "f"
    let line: Int           // 1-based
    let depth: Int          // 0 at file scope, +1 per enclosing symbol

    // The single glyph the picker and breadcrumb show for this kind. ctags emits
    // both long names and one-letter abbreviations depending on the parser, so
    // both spellings map here.
    var symbol: String {
        switch (kind ?? "").lowercased() {
        case "function", "func", "f", "method", "m", "subroutine": return "ƒ"
        case "class", "c": return "◆"
        case "struct", "s": return "◇"
        case "enum", "g", "e": return "▤"
        case "protocol", "interface", "i": return "◈"
        case "variable", "v", "constant", "const", "property", "p": return "▪"
        case "typedef", "t", "type", "alias": return "≡"
        case "extension": return "⊕"
        default: return "•"
        }
    }
}

enum SymbolOutline {

    // The outline for one file: its definitions in line order, with depth read
    // off each defining line's indentation. `relativePath` is matched against
    // SymbolDefinition.relativePath, which is root-relative — the same string
    // FileIndex and ripgrep use.
    static func entries(
        definitions: [String: [SymbolDefinition]],
        relativePath: String,
        fileText: String
    ) -> [OutlineEntry] {
        let lines = fileText.components(separatedBy: "\n")

        var mine: [SymbolDefinition] = []
        for group in definitions.values {
            for def in group where def.relativePath == relativePath { mine.append(def) }
        }
        mine.sort { $0.lineNumber < $1.lineNumber }

        // Two ctags parsers can report the same name at the same line (e.g. a
        // Swift extension method seen twice); one row is enough.
        var seen = Set<String>()
        var indents: [(entry: SymbolDefinition, indent: Int)] = []
        for def in mine {
            let key = "\(def.lineNumber):\(def.name)"
            guard seen.insert(key).inserted else { continue }
            guard lines.indices.contains(def.lineNumber - 1) else { continue }
            indents.append((def, indentColumn(of: lines[def.lineNumber - 1])))
        }

        // Indent columns → depth: a stack of enclosing indents, popped as soon
        // as a symbol is no more indented than its would-be parent. This maps
        // *any* consistent indent width to 0,1,2… without knowing the width.
        var stack: [Int] = []
        var result: [OutlineEntry] = []
        for (def, indent) in indents {
            while let top = stack.last, indent <= top { stack.removeLast() }
            result.append(OutlineEntry(name: def.name, kind: def.kind, line: def.lineNumber, depth: stack.count))
            stack.append(indent)
        }
        return result
    }

    // The breadcrumb for a caret on `line`: the chain of entries that enclose
    // it, outermost first. An entry encloses the caret when it starts at or
    // above the line and nothing at the same-or-shallower depth intervenes.
    static func breadcrumb(for line: Int, in entries: [OutlineEntry]) -> [OutlineEntry] {
        var chain: [OutlineEntry] = []
        for entry in entries where entry.line <= line {
            while let last = chain.last, last.depth >= entry.depth { chain.removeLast() }
            chain.append(entry)
        }
        return chain
    }

    // Subsequence fuzzy match, the CommandPalette rule, so the outline picker
    // filters the way ⌘K and ⌘P already do. Returns nil for no match; lower
    // scores rank first (a tighter, earlier match wins).
    static func fuzzyScore(_ query: String, _ candidate: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let q = Array(query.lowercased())
        let c = Array(candidate.lowercased())
        var qi = 0
        var first: Int?
        var last = 0
        for (i, char) in c.enumerated() {
            guard qi < q.count else { break }
            if char == q[qi] {
                if first == nil { first = i }
                last = i
                qi += 1
            }
        }
        guard qi == q.count, let first else { return nil }
        return (last - first) * 4 + first
    }

    private static func indentColumn(of line: String) -> Int {
        var column = 0
        for c in line {
            if c == " " { column += 1 } else if c == "\t" { column += 4 } else { break }
        }
        return column
    }
}
