import Foundation

// Assertions for the project-search highlight plan
// (swift/Sources/suit/SearchHighlight.swift) — what the viewer washes and what
// the minimap ticks when the sidebar's Search tab has a live pattern. Compiled
// and run by scripts/search-highlight-test.sh; same hand-rolled check() shape as
// the find-replace / editor-ops drivers.

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

func query(_ text: String, caseSensitive: Bool = false, regex: Bool = false) -> FindQuery {
    FindQuery(text: text, caseSensitive: caseSensitive, wholeWord: false, regex: regex)
}

// The viewer hands in its own lineStarts; EditorOps builds them the same way.
func plan(_ text: String, _ q: FindQuery) -> SearchHighlight.Plan {
    SearchHighlight.plan(text: text, query: q, lineStarts: EditorOps.lineStarts(of: text))
}

print("== ranges and marker lines ==")
do {
    let text = "alpha beta\nbeta gamma\ndelta\nbeta beta\n"
    let result = plan(text, query("beta"))
    check(described(result.ranges) == ["6+4", "11+4", "28+4", "33+4"],
          "every occurrence is washed, in document order")
    check(result.markerLines == [1, 2, 4],
          "one marker per line carrying a hit — line 4's two hits collapse to one tick")
    check(result.total == 4, "total counts matches, not marked lines")
    check(!result.isEmpty, "a plan with matches is not empty")
}

print("== nothing to paint ==")
do {
    let text = "alpha\nbeta\n"
    check(plan(text, query("")).isEmpty, "an empty pattern highlights nothing")
    check(plan(text, query("gamma")).isEmpty, "an absent pattern highlights nothing")
    check(plan(text, query("gamma")).markerLines.isEmpty, "and leaves the minimap alone")
    check(plan("", query("beta")).isEmpty, "an empty buffer highlights nothing")
    // A half-typed regex is a normal state while typing, not an error: the wash
    // just stays clear until the pattern compiles again.
    check(plan(text, query("bet(", regex: true)).isEmpty, "a malformed regex highlights nothing")
}

print("== the query's options are honored ==")
do {
    let text = "Beta\nbeta\n"
    check(plan(text, query("beta")).total == 2, "case-insensitive by default, as rg is without -s")
    check(plan(text, query("beta", caseSensitive: true)).markerLines == [2],
          "case-sensitive marks only the matching line")
    check(plan("ab\nacb\n", query("a.b", regex: true)).markerLines == [2],
          "regex mode matches through the pattern, not literally")
    check(plan("ab\nacb\n", query("a.b")).total == 0,
          "literal mode takes the dot literally")
}

print("== line mapping ==")
do {
    // No trailing newline, and a hit that spans into the next line: the marker
    // follows the match's *start*, which is the line the reader is sent to.
    let text = "one\ntwo\nthree"
    check(plan(text, query("three")).markerLines == [3], "the last line without a trailing newline")
    check(plan(text, query("e\ntwo", regex: false)).markerLines == [1],
          "a match spanning a newline marks the line it starts on")
    check(plan("\n\nhit\n", query("hit")).markerLines == [3], "leading blank lines still count")
}

print("== caps ==")
do {
    // One hit per line, far past both caps: the wash and the ticks are bounded
    // while the count stays honest — that is what lets the caps be invisible.
    let lines = SearchHighlight.maxPaintedRanges + 500
    let text = String(repeating: "hit\n", count: lines)
    let result = plan(text, query("hit"))
    check(result.total == lines, "total reports every match, uncapped")
    check(result.ranges.count == SearchHighlight.maxPaintedRanges,
          "painted ranges stop at the cap")
    check(result.markerLines.count == min(lines, SearchHighlight.maxMarkerLines),
          "marker lines stop at their own cap")
    check(result.ranges.first?.location == 0 && result.markerLines.first == 1,
          "the cap keeps the head of the document, not an arbitrary window")
}

print(failures == 0 ? "\nAll search-highlight checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
