import Foundation

// Assertions for the symbol-navigation cores —
// swift/Sources/suit/SymbolOutline.swift (the ⇧⌘O outline, its nesting depth,
// the breadcrumb chain, fuzzy ranking) and swift/Sources/suit/NavigationHistory.swift
// (browser-style back/forward over jump targets). Compiled and run by
// scripts/editor-nav-test.sh against the real SymbolIndexCore types.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

func def(_ name: String, _ path: String, _ line: Int, _ kind: String? = nil) -> SymbolDefinition {
    SymbolDefinition(name: name, relativePath: path, lineNumber: line, kind: kind)
}

func grouped(_ defs: [SymbolDefinition]) -> [String: [SymbolDefinition]] {
    var byName: [String: [SymbolDefinition]] = [:]
    for d in defs { byName[d.name, default: []].append(d) }
    return byName
}

let source = """
class Store {
    var items = []

    func add() {
        let x = 1
    }

    func remove() {
    }
}

func free() {
}
"""

print("== outline entries ==")
do {
    let defs = grouped([
        def("Store", "a.swift", 1, "class"),
        def("items", "a.swift", 2, "property"),
        def("add", "a.swift", 4, "function"),
        def("x", "a.swift", 5, "variable"),
        def("remove", "a.swift", 8, "function"),
        def("free", "a.swift", 12, "function"),
        def("elsewhere", "b.swift", 3, "function"),
    ])
    let entries = SymbolOutline.entries(definitions: defs, relativePath: "a.swift", fileText: source)

    check(entries.map { $0.name } == ["Store", "items", "add", "x", "remove", "free"],
          "only this file's symbols, in line order")
    check(entries.map { $0.depth } == [0, 1, 1, 2, 1, 0],
          "depth follows the defining line's indentation, at any indent width")
    check(entries.first { $0.name == "add" }?.symbol == "ƒ", "kinds map to glyphs")
    check(entries.first { $0.name == "Store" }?.symbol == "◆", "long and short ctags kinds both map")

    let outOfRange = SymbolOutline.entries(
        definitions: grouped([def("ghost", "a.swift", 999, "function")]),
        relativePath: "a.swift", fileText: source)
    check(outOfRange.isEmpty, "a definition past the end of the file is dropped, not crashed on")

    let duped = SymbolOutline.entries(
        definitions: grouped([def("add", "a.swift", 4, "function"), def("add", "a.swift", 4, "method")]),
        relativePath: "a.swift", fileText: source)
    check(duped.count == 1, "the same name at the same line collapses to one row")
}

print("")
print("== breadcrumb ==")
do {
    let defs = grouped([
        def("Store", "a.swift", 1, "class"),
        def("add", "a.swift", 4, "function"),
        def("free", "a.swift", 12, "function"),
    ])
    let entries = SymbolOutline.entries(definitions: defs, relativePath: "a.swift", fileText: source)

    check(SymbolOutline.breadcrumb(for: 5, in: entries).map { $0.name } == ["Store", "add"],
          "a caret in a method reads Class › method")
    check(SymbolOutline.breadcrumb(for: 2, in: entries).map { $0.name } == ["Store"],
          "a caret in the class body but outside a method stops at the class")
    check(SymbolOutline.breadcrumb(for: 12, in: entries).map { $0.name } == ["free"],
          "a top-level function replaces the chain rather than nesting under the class")
    check(SymbolOutline.breadcrumb(for: 1, in: entries).map { $0.name } == ["Store"],
          "the declaring line itself is inside its own symbol")
}

print("")
print("== fuzzy ranking ==")
do {
    check(SymbolOutline.fuzzyScore("ad", "add") != nil, "a subsequence matches")
    check(SymbolOutline.fuzzyScore("ad", "remove") == nil, "a non-subsequence does not")
    check(SymbolOutline.fuzzyScore("", "anything") == 0, "an empty query matches everything equally")
    let tight = SymbolOutline.fuzzyScore("ad", "add")!
    let loose = SymbolOutline.fuzzyScore("ad", "aXXXd")!
    check(tight < loose, "a tighter match ranks ahead of a scattered one")
    check(SymbolOutline.fuzzyScore("ST", "Store") != nil, "matching is case-insensitive")
}

print("")
print("== navigation history ==")
do {
    let history = NavigationHistory()
    check(!history.canGoBack && !history.canGoForward, "an empty history goes nowhere")

    history.record(NavLocation(path: "a.swift", line: 10))
    check(!history.canGoBack, "one entry is the current location, not something to go back to")

    history.record(NavLocation(path: "b.swift", line: 20))
    history.record(NavLocation(path: "c.swift", line: 30))
    check(history.canGoBack && !history.canGoForward, "at the head, only back is available")

    check(history.back() == NavLocation(path: "b.swift", line: 20), "back steps one entry")
    check(history.canGoForward, "going back makes forward available")
    check(history.back() == NavLocation(path: "a.swift", line: 10), "back again")
    check(history.back() == nil, "back at the tail returns nil rather than wrapping")
    check(history.forward() == NavLocation(path: "b.swift", line: 20), "forward retraces")

    // Navigating anew from the middle drops the forward tail.
    history.record(NavLocation(path: "d.swift", line: 40))
    check(!history.canGoForward, "a new jump mid-history truncates the forward branch")
    check(history.back() == NavLocation(path: "b.swift", line: 20), "…and lands back where we branched")

    let dupes = NavigationHistory()
    dupes.record(NavLocation(path: "a.swift", line: 1))
    dupes.record(NavLocation(path: "a.swift", line: 1))
    check(dupes.entries.count == 1, "jumping to where we already are records nothing")

    let updating = NavigationHistory()
    updating.record(NavLocation(path: "a.swift", line: 1))
    updating.record(NavLocation(path: "b.swift", line: 5))
    updating.updateCurrentLine(42)
    check(updating.current == NavLocation(path: "b.swift", line: 42),
          "the current entry tracks the caret without creating a history step")
    check(updating.entries.count == 2, "…and without growing the list")

    let bounded = NavigationHistory()
    for i in 0..<(NavigationHistory.capacity + 20) {
        bounded.record(NavLocation(path: "f.swift", line: i))
    }
    check(bounded.entries.count == NavigationHistory.capacity, "history is capped")
    check(bounded.current == NavLocation(path: "f.swift", line: NavigationHistory.capacity + 19),
          "the cap drops the oldest entries, not the newest")
}

print("")
if failures == 0 {
    print("All editor-nav assertions passed.")
} else {
    print("\(failures) editor-nav assertion(s) FAILED.")
}
exit(failures == 0 ? 0 : 1)
