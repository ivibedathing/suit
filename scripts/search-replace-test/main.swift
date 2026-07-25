import Foundation

// Assertions for the sidebar Search tab's project-wide replace core
// (swift/Sources/suit/SearchReplace.swift, over swift/Sources/suit/FindReplace.swift).
// Compiled and run by scripts/search-replace-test.sh — see that script's header.
// Mirrors the find-replace / editor-ops driver shape: a hand-rolled check(),
// grouped prints, non-zero exit on any failure.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

func query(_ text: String, caseSensitive: Bool = false, regex: Bool = false) -> FindQuery {
    SearchReplace.query(pattern: text, isRegex: regex, caseSensitive: caseSensitive)
}

print("== query mapping ==")
do {
    let mapped = SearchReplace.query(pattern: "foo", isRegex: true, caseSensitive: true, wholeWord: true)
    check(mapped.text == "foo" && mapped.regex && mapped.caseSensitive && mapped.wholeWord,
          "pattern, regex, case and whole-word flags all carry over from the search bar")
    check(!SearchReplace.query(pattern: "foo", isRegex: false, caseSensitive: false).wholeWord,
          "whole-word defaults off, so a caller that predates the ab toggle can't turn rg -w on")

    let words = SearchReplace.replaceAll(inFileText: "foo foobar\n",
                                         query: SearchReplace.query(pattern: "foo", isRegex: false,
                                                                    caseSensitive: false, wholeWord: true),
                                         template: "baz")
    check(words.text == "baz foobar\n" && words.count == 1,
          "the whole-word query replaces exactly what rg -w listed, leaving foobar alone")
}

print("== line-wise replacement ==")
do {
    let text = "alpha foo\nbar\nfoo foo\n"
    let result = SearchReplace.replaceAll(inFileText: text, query: query("foo"), template: "baz")
    check(result.count == 3, "counts every match on every line (got \(result.count))")
    check(result.text == "alpha baz\nbar\nbaz baz\n", "rewrites in place, line structure intact")

    let none = SearchReplace.replaceAll(inFileText: text, query: query("qux"), template: "baz")
    check(none.count == 0 && none.text == text,
          "no match returns the text unchanged, so a caller can skip the write")

    let empty = SearchReplace.replaceAll(inFileText: "keep foo keep\n", query: query("foo "), template: "")
    check(empty.text == "keep keep\n" && empty.count == 1, "an empty template deletes the match")
}

print("== line anchors match per line, like rg ==")
do {
    // The whole point of going line by line: rg runs without --multiline, so a
    // ^/$ anchored pattern must anchor to each line the results listed, not to
    // the ends of the file.
    let text = "foo one\nfoo two\nnot foo\n"
    let result = SearchReplace.replaceAll(inFileText: text, query: query("^foo", regex: true), template: "BAR")
    check(result.count == 2, "^foo hits both leading occurrences, not just the file's first (got \(result.count))")
    check(result.text == "BAR one\nBAR two\nnot foo\n", "the trailing 'not foo' is left alone")

    let dollar = SearchReplace.replaceAll(inFileText: "a x\nb x\n", query: query("x$", regex: true), template: "y")
    check(dollar.text == "a y\nb y\n" && dollar.count == 2, "x$ anchors to each line's end")
}

print("== CRLF files keep their line endings ==")
do {
    let text = "foo\r\nbar foo\r\n"
    let result = SearchReplace.replaceAll(inFileText: text, query: query("foo$", regex: true), template: "baz")
    check(result.count == 2, "the \\r doesn't hide the end of the line from a $ anchor (got \(result.count))")
    check(result.text == "baz\r\nbar baz\r\n", "the carriage returns survive the rewrite")
}

print("== regex capture templates ==")
do {
    let text = "let a = 1\nlet b = 2\n"
    let result = SearchReplace.replaceAll(inFileText: text,
                                         query: query("let (\\w+) = (\\d+)", regex: true),
                                         template: "var $1 = $2")
    check(result.text == "var a = 1\nvar b = 2\n", "capture groups interpolate, as in the ⌘F bar")

    let literal = SearchReplace.replaceAll(inFileText: "x\n", query: query("x"), template: "$1")
    check(literal.text == "$1\n", "in literal mode the template is inserted verbatim")
}

print("== case sensitivity ==")
do {
    let text = "Foo foo FOO\n"
    check(SearchReplace.replaceAll(inFileText: text, query: query("foo"), template: "z").count == 3,
          "case-insensitive by default, matching rg without --case-sensitive")
    check(SearchReplace.replaceAll(inFileText: text, query: query("foo", caseSensitive: true), template: "z").text
            == "Foo z FOO\n",
          "case-sensitive touches only the exact spelling")
}

print("== preserve case (the AB toggle) ==")
do {
    let text = "widget Widget WIDGET widgetise\n"
    let plain = SearchReplace.replaceAll(inFileText: text, query: query("widget"), template: "gadget")
    check(plain.text == "gadget gadget gadget gadgetise\n",
          "off, every match takes the template exactly as typed")

    let kept = SearchReplace.replaceAll(inFileText: text, query: query("widget"),
                                        template: "gadget", preserveCase: true)
    check(kept.text == "gadget Gadget GADGET gadgetise\n",
          "on, each match's own capitalization is carried onto the replacement (got \(kept.text.trimmingCharacters(in: .newlines)))")
    check(kept.count == 4, "preserve-case doesn't change how many matches are replaced")

    check(SearchReplace.preservingCase("onKeyDown", matching: "handler") == "onKeyDown",
          "a lowercase match leaves a deliberately-cased template alone rather than flattening it")
    check(SearchReplace.preservingCase("bar", matching: "F") == "Bar",
          "a lone uppercase letter reads as Titlecase, not as ALLCAPS")
    check(SearchReplace.preservingCase("bar", matching: "42") == "bar",
          "a match with no letters has no case to preserve")
    check(SearchReplace.preservingCase("", matching: "FOO") == "",
          "an empty template (a delete) survives the transform")

    // Regex mode expands the template first, so the case transform lands on the
    // finished text rather than on "$1".
    let captured = SearchReplace.replaceAll(inFileText: "Alpha beta\n",
                                            query: query("(alpha)", regex: true),
                                            template: "x$1", preserveCase: true)
    check(captured.text == "XAlpha beta\n",
          "capture groups interpolate before the case transform (got \(captured.text.trimmingCharacters(in: .newlines)))")
}

print("== the replace gate ==")
do {
    check(SearchReplace.gate(pattern: "", fileCount: 2, matchCount: 4,
                             isSearching: false, truncated: false) == .noPattern,
          "no pattern, nothing to replace")
    check(SearchReplace.gate(pattern: "foo", fileCount: 2, matchCount: 4,
                             isSearching: true, truncated: false) == .stillSearching,
          "refuses mid-search: rg is still streaming the file list")
    check(SearchReplace.gate(pattern: "foo", fileCount: 2, matchCount: 4,
                             isSearching: false, truncated: true) == .truncated,
          "refuses a capped result set rather than silently under-replacing")
    check(SearchReplace.gate(pattern: "foo", fileCount: 0, matchCount: 0,
                             isSearching: false, truncated: false) == .noMatches,
          "no matches, nothing to replace")
    check(SearchReplace.gate(pattern: "foo", fileCount: 2, matchCount: 4,
                             isSearching: false, truncated: false) == .ready(files: 2, replacements: 4),
          "a settled, uncapped, non-empty result set is ready")
    check(SearchReplace.Gate.ready(files: 1, replacements: 1).refusal == nil,
          "ready carries no refusal to show")
    check(SearchReplace.Gate.truncated.refusal?.contains("narrow the search") == true,
          "the truncated refusal says what to do about it")
}

print("== the single-file gate (a result row's replace button) ==")
do {
    check(SearchReplace.fileGate(pattern: "", matchCount: 3, isSearching: false) == .noPattern,
          "no pattern, nothing to replace")
    check(SearchReplace.fileGate(pattern: "foo", matchCount: 3, isSearching: true) == .stillSearching,
          "refuses mid-search: the row's own match count is still moving")
    check(SearchReplace.fileGate(pattern: "foo", matchCount: 0, isSearching: false) == .noMatches,
          "a row with no matches left has nothing to replace")
    check(SearchReplace.fileGate(pattern: "foo", matchCount: 3, isSearching: false)
            == .ready(files: 1, replacements: 3),
          "one settled file is ready — and, unlike Replace All, a capped result set doesn't stop it: "
            + "the pass rewrites the whole file either way")
}

print("== applying across files ==")
do {
    var disk = [
        "/root/a.swift": "foo\nfoo\n",
        "/root/b.swift": "bar\n",
        "/root/c.swift": "foo bar foo\n",
    ]
    var writes: [String] = []
    let outcome = SearchReplace.apply(
        root: "/root",
        relativePaths: ["a.swift", "b.swift", "c.swift"],
        query: query("foo"),
        template: "qux",
        read: {
            guard let text = disk[$0] else { throw NSError(domain: "test", code: 1) }
            return text
        },
        write: { path, text in
            writes.append(path)
            disk[path] = text
        }
    )
    check(outcome.replacements == 4, "counts every replacement across every file (got \(outcome.replacements))")
    check(outcome.filesChanged == ["a.swift", "c.swift"], "reports only the files it rewrote")
    check(writes == ["/root/a.swift", "/root/c.swift"],
          "b.swift is never written: rewriting it byte-identical would dirty it for nothing")
    check(disk["/root/a.swift"] == "qux\nqux\n" && disk["/root/c.swift"] == "qux bar qux\n",
          "the new text lands on disk")
    check(outcome.skipped == [SearchReplace.Skip(relativePath: "b.swift", reason: "no longer matches")],
          "a file that stopped matching is reported, not silently dropped")
}

print("== apply reports IO failures instead of hiding them ==")
do {
    let outcome = SearchReplace.apply(
        root: "/root",
        relativePaths: ["binary.bin", "readonly.swift"],
        query: query("foo"),
        template: "bar",
        read: { path in
            if path.hasSuffix("binary.bin") { throw NSError(domain: "test", code: 1) }
            return "foo\n"
        },
        write: { path, _ in
            if path.hasSuffix("readonly.swift") { throw NSError(domain: "test", code: 13) }
        }
    )
    check(outcome.filesChanged.isEmpty && outcome.replacements == 0, "nothing counted as changed")
    check(outcome.skipped.map(\.reason) == ["unreadable as UTF-8 text", "write failed"],
          "an unreadable file and a failed write are both surfaced with their reason")
}

print("== absolute paths pass through ==")
do {
    check(SearchReplace.absolutePath(root: "/root", relativePath: "a/b.swift") == "/root/a/b.swift",
          "an rg-relative path is joined to the search root")
    check(SearchReplace.absolutePath(root: "/root", relativePath: "/elsewhere/b.swift") == "/elsewhere/b.swift",
          "an already-absolute path is left alone")
}

print("== prose ==")
do {
    let one = SearchReplace.confirmation(files: 1, replacements: 1, template: "bar", scopeLabel: "suit")
    check(one.message == "Replace 1 match in 1 file?", "singular counts read as singular")
    check(one.detail.contains("suit") && one.detail.contains("“bar”"),
          "the detail names the scope and the replacement")

    let many = SearchReplace.confirmation(files: 3, replacements: 12, template: "", scopeLabel: "suit")
    check(many.message == "Replace 12 matches in 3 files?", "plural counts read as plural")
    check(many.detail.contains("deleting them"), "an empty template is described as a delete, not as “with ””")

    var outcome = SearchReplace.Outcome()
    outcome.filesChanged = ["a.swift", "b.swift"]
    outcome.replacements = 5
    check(SearchReplace.summary(outcome) == "Replaced 5 matches in 2 files", "the clean summary")
    outcome.skipped = [SearchReplace.Skip(relativePath: "c.swift", reason: "no longer matches")]
    check(SearchReplace.summary(outcome)
            == "Replaced 5 matches in 2 files — skipped c.swift (no longer matches)",
          "a single skip is named")
    outcome.skipped.append(SearchReplace.Skip(relativePath: "d.swift", reason: "write failed"))
    check(SearchReplace.summary(outcome) == "Replaced 5 matches in 2 files — skipped 2 files",
          "several skips are counted rather than listed into a status line that can't hold them")
    check(SearchReplace.summary(SearchReplace.Outcome()) == "Nothing to replace",
          "an empty pass says so")
}

print(failures == 0 ? "\nAll search-replace assertions passed" : "\n\(failures) assertion(s) failed")
exit(failures == 0 ? 0 : 1)
