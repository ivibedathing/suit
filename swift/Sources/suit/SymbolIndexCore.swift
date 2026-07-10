import Foundation

// The UI-free core of go-to-definition / find-references,
// the RoadmapParser/FeedbackRouting pattern: Foundation-only, no app deps, so
// scripts/symbol-index-test can compile it standalone and assert the parsing
// and lookup rules. The app-side SymbolIndex.swift wraps this with the ctags
// process, per-root caching and FileIndex refresh; the references pane feeds an
// rg word search of `referenceRegex`.

// One symbol definition the index knows about: where it lives (root-relative,
// so it lines up with FileIndex/ripgrep paths) and what kind of thing it is.
struct SymbolDefinition: Equatable {
    let name: String
    let relativePath: String
    let lineNumber: Int
    // ctags' kind (e.g. "function", "struct", "f", "s") when present — shown in
    // the multi-definition picker so "the User struct" reads apart from "the
    // user() function".
    let kind: String?
}

enum SymbolIndexCore {
    // MARK: - ctags output parsing

    // One line of `ctags -f - --fields=+n` classic tag output → a definition,
    // or nil for pseudo-tags (`!_TAG_…`) and malformed lines. The classic tag
    // format is tab-separated: name, file, {exCmd};", then extension fields.
    // ctags escapes tabs/newlines inside search-pattern exCmds, so a plain tab
    // split is safe; we pull `line:N` and the bare kind field out of the
    // extension columns (order-independent — kind is the first `:`-less field).
    static func parseTagLine<S: StringProtocol>(_ line: S) -> SymbolDefinition? {
        guard !line.hasPrefix("!_TAG_") else { return nil }
        let columns = line.components(separatedBy: "\t")
        guard columns.count >= 3 else { return nil }
        let name = columns[0]
        let path = columns[1]
        guard !name.isEmpty, !path.isEmpty else { return nil }

        var lineNumber: Int?
        var kind: String?
        // Everything past the exCmd (columns[2]) is an extension field. `line:N`
        // is our line number; the one field with no `key:value` colon is the
        // kind. A bare-number exCmd (--excmd=number) is a fallback line source.
        for column in columns.dropFirst(3) {
            if column.hasPrefix("line:"), let n = Int(column.dropFirst(5)) {
                lineNumber = n
            } else if !column.contains(":"), kind == nil, !column.isEmpty {
                kind = column
            } else if column.hasPrefix("kind:") {
                kind = String(column.dropFirst(5))
            }
        }
        // The exCmd itself is a bare line number when ctags ran with
        // --excmd=number and no `line:` field was emitted.
        if lineNumber == nil {
            let exCmd = columns[2].hasSuffix(";\"") ? String(columns[2].dropLast(2)) : columns[2]
            lineNumber = Int(exCmd)
        }
        guard let lineNumber, lineNumber > 0 else { return nil }
        return SymbolDefinition(name: name, relativePath: path, lineNumber: lineNumber, kind: kind)
    }

    // Parse a whole tags dump into definitions grouped by name — the shape the
    // index serves lookups from.
    static func parseTags<S: StringProtocol>(_ output: S) -> [String: [SymbolDefinition]] {
        var byName: [String: [SymbolDefinition]] = [:]
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let def = parseTagLine(rawLine) else { continue }
            byName[def.name, default: []].append(def)
        }
        for (name, defs) in byName {
            byName[name] = dedupeSorted(defs)
        }
        return byName
    }

    // Stable order (path, then line) with exact duplicates removed — a symbol
    // defined once but reported by two ctags passes shouldn't double up.
    static func dedupeSorted(_ defs: [SymbolDefinition]) -> [SymbolDefinition] {
        var seen = Set<String>()
        var result: [SymbolDefinition] = []
        for def in defs.sorted(by: {
            $0.relativePath == $1.relativePath ? $0.lineNumber < $1.lineNumber
                                               : $0.relativePath < $1.relativePath
        }) {
            let key = "\(def.relativePath):\(def.lineNumber):\(def.name)"
            if seen.insert(key).inserted { result.append(def) }
        }
        return result
    }

    // MARK: - Identifier under the caret

    // True for the characters that make up a source identifier: ASCII letters,
    // digits and underscore. Symbols in every language we index are ASCII, so a
    // UTF-16 scan over these is exact and avoids grapheme bookkeeping.
    static func isIdentifierUnit(_ u: UInt16) -> Bool {
        (u >= 0x30 && u <= 0x39) ||   // 0-9
        (u >= 0x41 && u <= 0x5A) ||   // A-Z
        (u >= 0x61 && u <= 0x7A) ||   // a-z
        u == 0x5F                     // _
    }

    // The identifier straddling a UTF-16 offset in a line of text, or nil when
    // the offset isn't on (or immediately after) one. This is what Cmd-click and
    // the caret-based "Go to Definition" resolve: the click's character index
    // maps to a line + column, and this pulls the whole word out. A purely
    // numeric run is not a symbol, so it returns nil.
    static func identifier(in line: String, atUTF16Offset offset: Int) -> String? {
        let units = Array(line.utf16)
        guard !units.isEmpty, offset >= 0, offset <= units.count else { return nil }

        // Prefer the char under the caret; fall back to the one just before it
        // so a click at the trailing edge of a word still resolves.
        var anchor = offset
        if anchor >= units.count || !isIdentifierUnit(units[anchor]) {
            if anchor > 0, isIdentifierUnit(units[anchor - 1]) {
                anchor -= 1
            } else {
                return nil
            }
        }

        var start = anchor
        while start > 0, isIdentifierUnit(units[start - 1]) { start -= 1 }
        var end = anchor
        while end < units.count, isIdentifierUnit(units[end]) { end += 1 }
        guard start < end else { return nil }

        let slice = Array(units[start..<end])
        // Numbers aren't symbols.
        if slice.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) { return nil }
        return String(utf16CodeUnits: slice, count: slice.count)
    }

    // MARK: - Lookup + reference search

    // Exact-name definitions from a prebuilt index, in display order.
    static func definitions(named name: String, in byName: [String: [SymbolDefinition]]) -> [SymbolDefinition] {
        byName[name] ?? []
    }

    // The ripgrep regex the references pane runs: whole-word matches of the
    // identifier. Identifiers are word characters, so `\b…\b` is exact; we still
    // escape defensively in case a caller passes something with metacharacters.
    static func referenceRegex(for identifier: String) -> String {
        let escaped = identifier.map { char -> String in
            "\\.^$|?*+()[]{}".contains(char) ? "\\\(char)" : String(char)
        }.joined()
        return "\\b\(escaped)\\b"
    }
}
