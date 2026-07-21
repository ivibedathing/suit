import Foundation

// Assertions for the viewer's editing cores — swift/Sources/suit/EditorOps.swift
// (auto-indent, bracket pairs, comment toggling, indent/outdent, ⌘D occurrence
// search, column selection) and swift/Sources/suit/CodeFolding.swift (brace and
// indentation fold regions). Compiled and run by scripts/editor-ops-test.sh.
// Same driver shape as the find-replace / file-edit harnesses.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

func described(_ ranges: [NSRange]) -> [String] {
    ranges.map { "\($0.location)+\($0.length)" }
}

print("== language traits ==")
do {
    check(EditorLanguage.detect(path: "/a/b/Foo.swift") == .swift, "extension picks the language")
    check(EditorLanguage.detect(path: "/a/Makefile") == .shell, "bare Makefile reads as shell")
    check(EditorLanguage.detect(path: "/a/notes.txt") == .plain, "unknown extension falls back to plain")
    check(EditorLanguage.swift.lineComment == "//" && EditorLanguage.python.lineComment == "#",
          "comment tokens per language")
    check(EditorLanguage.json.lineComment == nil, "JSON has no line comment, so ⌘/ can't corrupt it")
    check(EditorLanguage.swift.usesBraces && !EditorLanguage.python.usesBraces,
          "brace vs indentation block style")
}

print("")
print("== auto-indent on Return ==")
do {
    let text = "func a() {\n    let x = 1\n}\n"
    // End of "    let x = 1" (offset 11 is the line start; +13 chars).
    let midBody = EditorOps.newlineIndent(text: text, offset: 24, language: .swift)
    check(midBody.indent == "    " && midBody.closingLine == nil,
          "Return on an indented line keeps that indent")

    let afterOpen = EditorOps.newlineIndent(text: text, offset: 10, language: .swift)
    check(afterOpen.indent == "    " && afterOpen.closingLine == nil,
          "Return after `{` adds one indent step")

    let between = EditorOps.newlineIndent(text: "func a() {}", offset: 10, language: .swift)
    check(between.indent == "    " && between.closingLine == "",
          "Return between `{` and `}` opens a body and pushes the closer down")

    let nested = EditorOps.newlineIndent(text: "  if x {}", offset: 8, language: .swift)
    check(nested.indent == "      " && nested.closingLine == "  ",
          "the pushed-down closer returns to the opening line's indent")

    let python = EditorOps.newlineIndent(text: "def f():\n", offset: 8, language: .python)
    check(python.indent == "    " && python.closingLine == nil,
          "Python indents after a trailing colon")

    let pythonPlain = EditorOps.newlineIndent(text: "    x = 1\n", offset: 9, language: .python)
    check(pythonPlain.indent == "    ", "Python keeps the indent on a plain line")

    let midLine = EditorOps.newlineIndent(text: "if x { foo() }", offset: 6, language: .swift)
    check(midLine.indent == "    ", "only the text left of the caret decides the indent")

    let tabbed = EditorOps.newlineIndent(text: "\t\tlet x = 1", offset: 11, language: .swift)
    check(tabbed.indent == "\t\t", "existing tab indentation is preserved verbatim")
}

print("")
print("== bracket & quote pairs ==")
do {
    check(EditorOps.typingAction(text: "foo", offset: 3, character: "(", language: .swift) == .insertPair("()"),
          "typing `(` at end of line inserts the pair")
    check(EditorOps.typingAction(text: "()", offset: 1, character: ")", language: .swift) == .skipOver,
          "typing the closer under the caret steps over it")
    check(EditorOps.typingAction(text: "foo", offset: 0, character: "(", language: .swift) == .insert("("),
          "no auto-close immediately before a word")
    check(EditorOps.typingAction(text: "", offset: 0, character: "\"", language: .swift) == .insertPair("\"\""),
          "quotes pair too")
    check(EditorOps.typingAction(text: "don", offset: 3, character: "'", language: .swift) == .insert("'"),
          "an apostrophe after a word is a contraction, not an open quote")
    check(EditorOps.typingAction(text: "\"\"", offset: 2, character: "\"", language: .python) == .insert("\""),
          "a third quote is a Python docstring fence, not a pair")
    check(EditorOps.typingAction(text: "x", offset: 1, character: "a", language: .swift) == .insert("a"),
          "ordinary characters pass through untouched")

    check(EditorOps.wrap("foo", with: "(") == "(foo)", "typing `(` over a selection wraps it")
    check(EditorOps.wrap("foo", with: "\"") == "\"foo\"", "quotes wrap a selection")
    check(EditorOps.wrap("foo", with: "x") == nil, "a non-wrapping character replaces as usual")

    check(EditorOps.shouldDeletePair(text: "()", offset: 1), "backspace inside an empty pair deletes both")
    check(!EditorOps.shouldDeletePair(text: "(a)", offset: 2), "backspace with content between deletes one")
    check(EditorOps.shouldDeletePair(text: "\"\"", offset: 1), "same for quotes")
}

print("")
print("== indent / outdent ==")
do {
    let indented = EditorOps.indent(lines: ["a", "  b"], language: .swift)
    check(indented.lines == ["    a", "      b"], "indent adds one step to each line")
    check(indented.firstLineDelta == 4 && indented.totalDelta == 8, "deltas track the inserted units")

    let blank = EditorOps.indent(lines: ["a", "", "b"], language: .swift)
    check(blank.lines == ["    a", "", "    b"], "blank lines gain no trailing whitespace")

    let out = EditorOps.outdent(lines: ["    a", "  b", "c"], language: .swift)
    check(out.lines == ["a", "b", "c"], "outdent removes up to one step, never more than exists")
    check(out.firstLineDelta == -4 && out.totalDelta == -6, "outdent deltas are negative")

    let tab = EditorOps.outdent(lines: ["\ta"], language: .swift)
    check(tab.lines == ["a"], "a leading tab is one outdent step")

    let two = EditorOps.indent(lines: ["a"], language: .yaml)
    check(two.lines == ["  a"], "YAML indents by two")
}

print("")
print("== comment toggling ==")
do {
    let on = EditorOps.toggleComment(lines: ["let a = 1", "let b = 2"], language: .swift)
    check(on?.lines == ["// let a = 1", "// let b = 2"], "an uncommented block gains markers")

    let off = EditorOps.toggleComment(lines: ["// let a = 1", "// let b = 2"], language: .swift)
    check(off?.lines == ["let a = 1", "let b = 2"], "a fully-commented block loses them")

    let mixed = EditorOps.toggleComment(lines: ["// let a = 1", "let b = 2"], language: .swift)
    check(mixed?.lines == ["// // let a = 1", "// let b = 2"],
          "a half-commented block comments the rest rather than flip-flopping")

    let shaped = EditorOps.toggleComment(lines: ["  if x {", "      body()", "  }"], language: .swift)
    check(shaped?.lines == ["  // if x {", "  //     body()", "  // }"],
          "markers go at the block's shallowest indent, so the shape survives")

    let blanks = EditorOps.toggleComment(lines: ["a", "", "b"], language: .python)
    check(blanks?.lines == ["# a", "", "# b"], "blank lines are left alone")

    check(EditorOps.toggleComment(lines: ["{}"], language: .json) == nil,
          "a language with no line comment refuses rather than inventing one")
    check(EditorOps.toggleComment(lines: ["", "  "], language: .swift) == nil,
          "an all-blank selection is a no-op")

    let roundTrip = EditorOps.toggleComment(lines: ["    deep()"], language: .swift)
    let back = EditorOps.toggleComment(lines: roundTrip!.lines, language: .swift)
    check(back?.lines == ["    deep()"], "comment then uncomment restores the line exactly")
}

print("")
print("== multi-cursor occurrence search ==")
do {
    let text = "foo bar foo baz foo"
    check(EditorOps.wordRange(in: text, at: 1) == NSRange(location: 0, length: 3),
          "the word under the caret is found")
    check(EditorOps.wordRange(in: text, at: 3) == NSRange(location: 0, length: 3),
          "a caret at a word's trailing edge still resolves it")
    check(EditorOps.wordRange(in: " ", at: 0) == nil, "whitespace is not a word")

    let first = NSRange(location: 0, length: 3)
    check(EditorOps.nextOccurrence(of: "foo", in: text, from: 3, excluding: [first])
            == NSRange(location: 8, length: 3),
          "⌘D walks forward to the next occurrence")
    check(EditorOps.nextOccurrence(of: "foo", in: text, from: 19,
                                   excluding: [first, NSRange(location: 8, length: 3)])
            == NSRange(location: 16, length: 3),
          "the search wraps to the top")
    let all = [first, NSRange(location: 8, length: 3), NSRange(location: 16, length: 3)]
    check(EditorOps.nextOccurrence(of: "foo", in: text, from: 0, excluding: all) == nil,
          "nil once every occurrence already carries a cursor")

    check(described(EditorOps.allOccurrences(of: "foo", in: text)) == ["0+3", "8+3", "16+3"],
          "select-all-occurrences finds them all")
    check(EditorOps.allOccurrences(of: "", in: text).isEmpty,
          "an empty needle matches nothing rather than everything")
    check(described(EditorOps.allOccurrences(of: "aa", in: "aaaa")) == ["0+2", "2+2"],
          "overlapping candidates advance past the whole match")
}

print("")
print("== column selection ==")
do {
    //           0123456789
    let text = "abcdef\nghijkl\nmn\n"
    // Line 0 col 2 → line 1 col 4.
    let box = EditorOps.columnRanges(text: text, from: 2, to: 11)
    check(described(box) == ["2+2", "9+2"], "a box selects the same columns on each line")

    // Line 0 col 4 → line 2 col 1, i.e. columns 1–4 — but line 2 ("mn") is only
    // 2 columns wide, so its slice stops there.
    let ragged = EditorOps.columnRanges(text: text, from: 4, to: 15)
    check(described(ragged) == ["1+3", "8+3", "15+1"],
          "a short line clamps the box to its own length")

    let upward = EditorOps.columnRanges(text: text, from: 11, to: 2)
    check(described(upward) == ["2+2", "9+2"], "dragging upward gives the same box")

    let zeroWidth = EditorOps.columnRanges(text: text, from: 2, to: 9)
    check(described(zeroWidth) == ["2+0", "9+0"], "a zero-width box is a stack of bare cursors")
}

print("")
print("== fold regions: braced ==")
do {
    let swift = """
    func a() {
        if x {
            body()
        }
    }
    func b() { return }
    """
    let regions = CodeFolding.regions(in: swift, language: .swift)
    check(regions.map { "\($0.startLine)-\($0.endLine)@\($0.level)" } == ["1-5@0", "2-4@1"],
          "nested braces give nested regions, one-line blocks give none")

    let stringy = """
    func a() {
        let s = "{ not a block"
        // } not a block either
    }
    """
    let skipped = CodeFolding.regions(in: stringy, language: .swift)
    check(skipped.map { "\($0.startLine)-\($0.endLine)" } == ["1-4"],
          "braces inside strings and comments don't open regions")

    let block = "func a() {\n/* } */\n}"
    check(CodeFolding.regions(in: block, language: .c).map { "\($0.startLine)-\($0.endLine)" } == ["1-3"],
          "block comments are skipped too")

    let sameLine = "let a = [1, 2, 3]\nlet b = foo(bar)"
    check(CodeFolding.regions(in: sameLine, language: .swift).isEmpty,
          "brackets opening and closing on one line are not foldable")
}

print("")
print("== fold regions: indentation ==")
do {
    let python = """
    def a():
        x = 1

        y = 2
    def b():
        pass
    """
    let regions = CodeFolding.regions(in: python, language: .python)
    check(regions.map { "\($0.startLine)-\($0.endLine)" } == ["1-4", "5-6"],
          "an indented block ends at the next line of equal-or-shallower indent")
    check(regions.first?.endLine == 4, "an interior blank line does not terminate the block")
}

print("")
print("== fold state ==")
do {
    let regions = [
        FoldRegion(startLine: 1, endLine: 10, level: 0),
        FoldRegion(startLine: 3, endLine: 6, level: 1),
    ]
    check(CodeFolding.hiddenLines(foldedStarts: [3], regions: regions) == IndexSet(4...6),
          "folding an inner region hides its body only, header included in neither end")
    check(CodeFolding.hiddenLines(foldedStarts: [1, 3], regions: regions).count == 9,
          "an inner fold inside an outer one adds nothing new")
    check(CodeFolding.innermostRegion(containing: 4, in: regions)?.startLine == 3,
          "the innermost containing region wins")
    check(CodeFolding.innermostRegion(containing: 8, in: regions)?.startLine == 1,
          "outside the inner region, the outer one is used")
    check(CodeFolding.innermostRegion(containing: 20, in: regions) == nil,
          "a line in no region folds nothing")
    check(CodeFolding.regions(atLevel: 1, in: regions).count == 1, "regions filter by nesting level")
    check(CodeFolding.prune(foldedStarts: [3, 99], regions: regions) == [3],
          "folds whose region vanished after an edit are dropped")
}

print("")
if failures == 0 {
    print("All editor-ops assertions passed.")
} else {
    print("\(failures) editor-ops assertion(s) FAILED.")
}
exit(failures == 0 ? 0 : 1)
