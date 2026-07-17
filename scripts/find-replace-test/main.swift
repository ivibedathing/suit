import Foundation

// Assertions for the file viewer's find/replace core (swift/Sources/suit/FindReplace.swift).
// Compiled and run by scripts/find-replace-test.sh — see that script's header.
// Mirrors the file-edit / recipes driver shape: a hand-rolled check(), grouped
// prints, non-zero exit on any failure.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

// Match ranges as "location+length" strings, so a failure prints something legible.
func described(_ ranges: [NSRange]) -> [String] {
    ranges.map { "\($0.location)+\($0.length)" }
}

func query(_ text: String, caseSensitive: Bool = false, wholeWord: Bool = false, regex: Bool = false) -> FindQuery {
    FindQuery(text: text, caseSensitive: caseSensitive, wholeWord: wholeWord, regex: regex)
}

print("== literal matching ==")
do {
    let text = "foo bar foo baz FOO"
    check(described(FindReplace.matchRanges(in: text, query: query("foo")))
            == ["0+3", "8+3", "16+3"],
          "case-insensitive by default: finds all three, FOO included")
    check(described(FindReplace.matchRanges(in: text, query: query("foo", caseSensitive: true)))
            == ["0+3", "8+3"],
          "case-sensitive excludes FOO")
    check(FindReplace.matchRanges(in: text, query: query("")).isEmpty,
          "empty query matches nothing rather than everything")
    check(FindReplace.matchRanges(in: text, query: query("qux")).isEmpty,
          "absent needle yields no matches")
    check(described(FindReplace.matchRanges(in: "aaaa", query: query("aa"))) == ["0+2", "2+2"],
          "overlapping candidates resolve to non-overlapping matches")
}

print("== whole-word ==")
do {
    let text = "foo food foo_bar barfoo foo"
    check(described(FindReplace.matchRanges(in: text, query: query("foo", wholeWord: true)))
            == ["0+3", "24+3"],
          "whole-word rejects food / foo_bar / barfoo, keeps the standalone ones")
    check(described(FindReplace.matchRanges(in: "a foo. bar", query: query("foo", wholeWord: true)))
            == ["2+3"],
          "punctuation counts as a word boundary")
    // \bfoo(\b would never match this; the neighbour check does. This is the whole
    // reason whole-word is a filter rather than a \b-wrapped pattern.
    check(described(FindReplace.matchRanges(in: "call foo() now", query: query("foo(", wholeWord: true)))
            == ["5+4"],
          "a query ending in a symbol still whole-word matches")
    check(described(FindReplace.matchRanges(in: "🎉foo🎉", query: query("foo", wholeWord: true)))
            == ["2+3"],
          "non-BMP neighbours are not word characters (and don't crash the boundary check)")
    check(FindReplace.matchRanges(in: "prefoo", query: query("foo", wholeWord: true)).isEmpty,
          "a match glued to a leading word character is rejected")
}

print("== regex matching ==")
do {
    let text = "cat cot cut"
    check(described(FindReplace.matchRanges(in: text, query: query("c.t", regex: true)))
            == ["0+3", "4+3", "8+3"],
          "regex metacharacters are live in regex mode")
    check(FindReplace.matchRanges(in: text, query: query("c.t")).isEmpty,
          "the same pattern is literal (and absent) in non-regex mode")
    check(described(FindReplace.matchRanges(in: "a1 b2", query: query("[a-z]\\d", regex: true)))
            == ["0+2", "3+2"],
          "character classes work")
    check(FindReplace.matchRanges(in: text, query: query("c(t", regex: true)).isEmpty,
          "a malformed pattern yields no matches instead of throwing")
    check(FindReplace.isValid(query("c(t", regex: true)) == false,
          "isValid reports the malformed pattern so the bar can tint the field")
    check(FindReplace.isValid(query("c(t")) == true,
          "the same text is a perfectly valid literal query")
    check(FindReplace.isValid(query("", regex: true)) == true,
          "an empty regex is not an error state")
    // A zero-length-match pattern must terminate rather than spin.
    check(FindReplace.matchRanges(in: "ab", query: query("x*", regex: true)).isEmpty == false,
          "a pattern that can match empty still returns (no infinite loop)")
}

print("== stepping between matches ==")
do {
    let ranges = [NSRange(location: 0, length: 3),
                  NSRange(location: 10, length: 3),
                  NSRange(location: 20, length: 3)]
    check(FindReplace.initialIndex(for: ranges, caret: 0) == 0,
          "caret at the top selects the first match")
    check(FindReplace.initialIndex(for: ranges, caret: 5) == 1,
          "caret mid-document selects the next match below it, not the first")
    check(FindReplace.initialIndex(for: ranges, caret: 10) == 1,
          "caret exactly on a match selects that match")
    check(FindReplace.initialIndex(for: ranges, caret: 999) == 0,
          "caret past the last match wraps to the top")
    check(FindReplace.initialIndex(for: [], caret: 0) == nil,
          "no matches means no current index")

    check(FindReplace.step(from: 0, count: 3, forward: true) == 1, "forward steps")
    check(FindReplace.step(from: 2, count: 3, forward: true) == 0, "forward wraps past the end")
    check(FindReplace.step(from: 0, count: 3, forward: false) == 2, "backward wraps past the start")
    check(FindReplace.step(from: 1, count: 3, forward: false) == 0, "backward steps")
    check(FindReplace.step(from: 0, count: 0, forward: true) == nil, "stepping with no matches is nil")
    check(FindReplace.step(from: 0, count: 1, forward: true) == 0, "a lone match steps to itself")
}

print("== replacement text ==")
do {
    let text = "foo bar"
    let literal = query("foo")
    check(FindReplace.replacementText(in: text, matchRange: NSRange(location: 0, length: 3),
                                      query: literal, template: "qux") == "qux",
          "literal replacement is verbatim")
    check(FindReplace.replacementText(in: text, matchRange: NSRange(location: 0, length: 3),
                                      query: literal, template: "$1") == "$1",
          "a $1 template is literal characters in non-regex mode")

    let captured = query("(\\w+) (\\w+)", regex: true)
    check(FindReplace.replacementText(in: text, matchRange: NSRange(location: 0, length: 7),
                                      query: captured, template: "$2 $1") == "bar foo",
          "regex mode interpolates capture groups")
}

print("== replaceAll ==")
do {
    let result = FindReplace.replaceAll(in: "foo bar foo", query: query("foo"), template: "qux")
    check(result.text == "qux bar qux", "every match replaced")
    check(result.count == 2, "count reports how many were replaced")

    let none = FindReplace.replaceAll(in: "hello", query: query("zzz"), template: "x")
    check(none.text == "hello", "no matches returns the text unchanged")
    check(none.count == 0, "no matches reports zero")

    // Replacement length differing from match length must not corrupt later offsets.
    let grow = FindReplace.replaceAll(in: "a a a", query: query("a"), template: "LONGER")
    check(grow.text == "LONGER LONGER LONGER", "a longer replacement keeps later matches aligned")
    let shrink = FindReplace.replaceAll(in: "aaa aaa", query: query("aaa"), template: "x")
    check(shrink.text == "x x", "a shorter replacement keeps later matches aligned")

    // The replacement containing the needle must not be re-scanned.
    let recursive = FindReplace.replaceAll(in: "foo", query: query("foo"), template: "foofoo")
    check(recursive.text == "foofoo", "a replacement containing the needle is not re-replaced")
    check(recursive.count == 1, "and counts once")

    let wholeWord = FindReplace.replaceAll(in: "foo food", query: query("foo", wholeWord: true), template: "x")
    check(wholeWord.text == "x food", "replaceAll honours whole-word")

    let caseSensitive = FindReplace.replaceAll(in: "foo FOO", query: query("foo", caseSensitive: true), template: "x")
    check(caseSensitive.text == "x FOO", "replaceAll honours case sensitivity")

    let groups = FindReplace.replaceAll(in: "a=1 b=2", query: query("(\\w)=(\\d)", regex: true), template: "$2=$1")
    check(groups.text == "1=a 2=b", "replaceAll interpolates capture groups per match")

    let empty = FindReplace.replaceAll(in: "foo", query: query(""), template: "x")
    check(empty.text == "foo" && empty.count == 0, "an empty query replaces nothing")

    let deletion = FindReplace.replaceAll(in: "a-b-c", query: query("-"), template: "")
    check(deletion.text == "abc" && deletion.count == 2, "an empty template deletes matches")
}

print("")
if failures == 0 {
    print("All find-replace assertions passed.")
} else {
    print("\(failures) find-replace assertion(s) FAILED.")
}
exit(failures == 0 ? 0 : 1)
