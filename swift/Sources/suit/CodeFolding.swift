import Foundation

// The UI-free core of code folding: turn a buffer into the list of foldable
// regions, and fold state into the set of hidden lines. Foundation-only so
// scripts/code-folding-test.sh compiles it standalone; FileViewerPane+Folding.swift
// is the AppKit half that hides glyphs and draws the gutter chevrons.
//
// Two strategies, picked by EditorLanguage.usesBraces:
//
//   * Braced languages fold on bracket nesting. The scanner is deliberately
//     naive about *context* — it skips strings and comments, but it doesn't
//     parse — because a fold that is occasionally one line off is far better
//     than no folding, and unlike highlighting a wrong fold is visible and
//     instantly undoable.
//   * Indentation languages (Python, YAML) fold on column: a line owns every
//     following line indented deeper than it, blank lines included when they
//     are interior to the block.
//
// A region spans *first line → last line inclusive*, both 1-based to match the
// gutter, and folding hides everything after the first line. That's the
// universal convention: the header stays readable with an ellipsis after it.

struct FoldRegion: Equatable {
    let startLine: Int      // 1-based, stays visible when folded
    let endLine: Int        // 1-based, inclusive, hidden when folded
    let level: Int          // nesting depth, 0 at top level

    // Regions shorter than this aren't worth a chevron: folding a two-line
    // block saves one line and costs a click.
    var isFoldable: Bool { endLine > startLine }
}

enum CodeFolding {

    // MARK: - Region discovery

    static func regions(in text: String, language: EditorLanguage) -> [FoldRegion] {
        language.usesBraces ? bracedRegions(in: text) : indentedRegions(in: text)
    }

    // Bracket nesting, skipping over string literals and comments so a `{` in a
    // string can't open a phantom region that swallows the rest of the file.
    private static func bracedRegions(in text: String) -> [FoldRegion] {
        var regions: [FoldRegion] = []
        var stack: [(line: Int, level: Int)] = []
        var line = 1
        var level = 0

        var inLineComment = false
        var inBlockComment = false
        var quote: Character?
        var escaped = false

        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil

            if c == "\n" {
                line += 1
                inLineComment = false
                // An unterminated string ends at the newline in every language
                // we fold; carrying it over would break the rest of the file.
                if quote != nil, quote != "`" { quote = nil }
                escaped = false
                i += 1
                continue
            }

            if inLineComment { i += 1; continue }

            if inBlockComment {
                if c == "*", next == "/" { inBlockComment = false; i += 2; continue }
                i += 1
                continue
            }

            if let q = quote {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == q { quote = nil }
                i += 1
                continue
            }

            if c == "/", next == "/" { inLineComment = true; i += 2; continue }
            if c == "/", next == "*" { inBlockComment = true; i += 2; continue }
            if c == "#" { inLineComment = true; i += 1; continue }   // shell / Ruby inside a braced file
            if c == "\"" || c == "'" || c == "`" { quote = c; i += 1; continue }

            if c == "{" || c == "[" || c == "(" {
                stack.append((line, level))
                level += 1
            } else if c == "}" || c == "]" || c == ")" {
                if let open = stack.popLast() {
                    level = open.level
                    // A block that opened and closed on one line isn't foldable;
                    // recording it anyway would litter the gutter with chevrons
                    // that do nothing.
                    if line > open.line {
                        regions.append(FoldRegion(startLine: open.line, endLine: line, level: open.level))
                    }
                }
            }
            i += 1
        }

        return normalize(regions)
    }

    // Indentation blocks: a non-blank line owns the following run of lines
    // indented strictly deeper. Trailing blank lines are trimmed off the region
    // so folding a function doesn't eat the blank line separating it from the
    // next one.
    private static func indentedRegions(in text: String) -> [FoldRegion] {
        let lines = text.components(separatedBy: "\n")
        // nil for a blank line — blanks belong to whatever block surrounds them
        // and must not terminate it.
        let indents: [Int?] = lines.map { line in
            line.trimmingCharacters(in: .whitespaces).isEmpty ? nil : indentColumn(of: line)
        }

        var regions: [FoldRegion] = []
        for (i, indent) in indents.enumerated() {
            guard let indent else { continue }
            var last = i
            var j = i + 1
            while j < lines.count {
                guard let next = indents[j] else { j += 1; continue }   // blank — keep scanning
                if next <= indent { break }
                last = j
                j += 1
            }
            if last > i {
                regions.append(FoldRegion(startLine: i + 1, endLine: last + 1, level: indent))
            }
        }
        return normalize(regions)
    }

    // A line's indent column, counting a tab as 4 — only ever compared against
    // other lines in the same file, so the exact width doesn't matter as long
    // as it's consistent.
    private static func indentColumn(of line: String) -> Int {
        var column = 0
        for c in line {
            if c == " " { column += 1 } else if c == "\t" { column += 4 } else { break }
        }
        return column
    }

    // One region per start line (the outermost wins — `func f() {` and a `(`
    // opening on the same line are the same chevron), sorted for the gutter.
    private static func normalize(_ regions: [FoldRegion]) -> [FoldRegion] {
        var widest: [Int: FoldRegion] = [:]
        for region in regions where region.isFoldable {
            if let existing = widest[region.startLine], existing.endLine >= region.endLine { continue }
            widest[region.startLine] = region
        }
        return widest.values.sorted { $0.startLine < $1.startLine }
    }

    // MARK: - Fold state

    // The lines hidden by a set of folded start-lines: everything after each
    // folded region's first line, unioned. Nested folds inside an already-folded
    // region contribute nothing new, which is what makes "fold all" idempotent.
    static func hiddenLines(foldedStarts: Set<Int>, regions: [FoldRegion]) -> IndexSet {
        var hidden = IndexSet()
        for region in regions where foldedStarts.contains(region.startLine) {
            guard region.endLine > region.startLine else { continue }
            hidden.insert(integersIn: (region.startLine + 1)...region.endLine)
        }
        return hidden
    }

    // The region a click on `line`'s chevron toggles.
    static func region(startingAt line: Int, in regions: [FoldRegion]) -> FoldRegion? {
        regions.first { $0.startLine == line }
    }

    // The innermost region containing `line` — what ⌥⌘[ folds when the caret is
    // in the middle of a block rather than on its header.
    static func innermostRegion(containing line: Int, in regions: [FoldRegion]) -> FoldRegion? {
        regions
            .filter { $0.startLine <= line && line <= $0.endLine }
            .max { a, b in a.startLine < b.startLine }
    }

    // Every region at nesting level `level` — Fold Level 1/2 commands.
    static func regions(atLevel level: Int, in regions: [FoldRegion]) -> [FoldRegion] {
        regions.filter { $0.level == level }
    }

    // Folded starts that no longer name a real region — dropped after an edit
    // reshapes the file, so a stale fold can't hide lines forever.
    static func prune(foldedStarts: Set<Int>, regions: [FoldRegion]) -> Set<Int> {
        let valid = Set(regions.map { $0.startLine })
        return foldedStarts.intersection(valid)
    }
}
