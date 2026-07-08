import Foundation

// Standalone assertions for the Phase 41 saved-layouts core (Layouts.swift),
// compiled with StateRestoration.swift + DiffReview.swift by
// scripts/layouts-test.sh. Covers the catalog operations (save/overwrite/
// rename/delete/sort), the LayoutStore's disk round-trip against a scratch
// $HOME, and the restore-time pruning that collapses a pane whose file is gone.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

// A JSON string of a SavedWindow, for order-independent structural comparison
// (SavedWindow isn't Equatable — encoding gives a stable canonical form).
func json(_ window: SavedWindow) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: (try? encoder.encode(window)) ?? Data(), as: UTF8.self)
}

let frame = NSRect(x: 10, y: 20, width: 800, height: 600)

// A known layout: a vertical split with a terminal on the left and, on the
// right, a horizontal split of two viewer tabs. Tab 3 (viewer of fileB) is the
// one we'll later delete to prove the collapse.
func knownWindow(fileA: String, fileB: String) -> SavedWindow {
    let tabs = [
        SavedTab(kind: .terminal, cwd: "/tmp/proj"),
        SavedTab(kind: .viewer, filePath: fileA, firstVisibleLine: 5),
        SavedTab(kind: .viewer, filePath: fileB, firstVisibleLine: 12),
    ]
    let tree: SavedNode = .split(
        vertical: true, fraction: 0.4,
        first: .pane(tabIndex: 0, fontSize: nil),
        second: .split(
            vertical: false, fraction: 0.5,
            first: .pane(tabIndex: 1, fontSize: 14),
            second: .pane(tabIndex: 2, fontSize: nil)
        )
    )
    return SavedWindow(frame: frame, tabs: tabs, tree: tree, mru: [2, 1, 0], activeTabIndex: 1)
}

// MARK: - Catalog operations

print("== catalog ==")
do {
    let w = knownWindow(fileA: "/tmp/a.txt", fileB: "/tmp/b.txt")
    var layouts: [SavedLayout] = []
    layouts = LayoutCatalog.upsert(layouts, name: "review", window: w, at: 100)
    check(layouts.count == 1, "upsert appends a new layout")
    check(layouts.first?.name == "review", "name stored verbatim")

    // Overwrite: same name (different casing) replaces, doesn't duplicate.
    let w2 = knownWindow(fileA: "/tmp/c.txt", fileB: "/tmp/d.txt")
    layouts = LayoutCatalog.upsert(layouts, name: "Review", window: w2, at: 200)
    check(layouts.count == 1, "same-name (case-insensitive) upsert overwrites")
    check(layouts.first?.savedAt == 200, "overwrite replaces the window + timestamp")
    check(json(layouts.first!.window) == json(w2), "overwritten window is the new one")

    // A second, distinct layout.
    layouts = LayoutCatalog.upsert(layouts, name: "debug", window: w, at: 300)
    check(layouts.count == 2, "distinct name appends")

    // Empty name rejected.
    let before = layouts.count
    layouts = LayoutCatalog.upsert(layouts, name: "   ", window: w, at: 400)
    check(layouts.count == before, "empty/whitespace name is rejected")

    // Sorting is alphabetical, case-insensitive.
    let names = LayoutCatalog.sorted(layouts).map(\.name)
    check(names == ["debug", "Review"], "sorted() is alphabetical: \(names)")

    // Rename.
    layouts = LayoutCatalog.rename(layouts, from: "debug", to: "staging")
    check(LayoutCatalog.named("staging", in: layouts) != nil, "rename moves to the new name")
    check(LayoutCatalog.named("debug", in: layouts) == nil, "old name gone after rename")
    // Rename onto an existing different name is a no-op.
    layouts = LayoutCatalog.rename(layouts, from: "staging", to: "Review")
    check(LayoutCatalog.named("staging", in: layouts) != nil, "rename onto an occupied name is refused")

    // Delete.
    layouts = LayoutCatalog.remove(layouts, name: "review")
    check(layouts.count == 1, "remove drops the layout")
    check(LayoutCatalog.named("Review", in: layouts) == nil, "removed name gone (case-insensitive)")
}

// MARK: - LayoutStore disk round-trip (scratch $HOME set by the wrapper)

print("== store round-trip ==")
do {
    let store = LayoutStore.shared
    // Start clean (the scratch home is fresh, but be defensive).
    for l in store.layouts { store.remove(name: l.name) }
    check(store.isEmpty, "store starts empty")

    let w = knownWindow(fileA: "/tmp/a.txt", fileB: "/tmp/b.txt")
    store.save(name: "review", window: w)
    check(store.exists(name: "review"), "saved layout exists")

    // A fresh read from disk must reproduce the saved window exactly.
    store.reload()
    check(store.layouts.count == 1, "one layout after reload")
    if let restored = store.layout(named: "review") {
        check(json(restored.window) == json(w), "window round-trips through disk unchanged")
        check(restored.window.mru == [2, 1, 0], "mru survives")
        check(restored.window.activeTabIndex == 1, "active tab survives")
    } else {
        check(false, "layout missing after reload")
    }

    // Overwrite persists.
    let w2 = knownWindow(fileA: "/tmp/x.txt", fileB: "/tmp/y.txt")
    store.save(name: "review", window: w2)
    store.reload()
    check(store.layouts.count == 1, "overwrite doesn't duplicate on disk")
    check(json(store.layout(named: "review")!.window) == json(w2), "disk holds the overwritten window")

    store.remove(name: "review")
    store.reload()
    check(store.isEmpty, "delete persists")
}

// MARK: - Restore-time pruning (deleted file collapses its pane)

print("== pruning ==")
do {
    // fileA exists, fileB is deleted; the terminal always restores.
    let existing = Set(["/tmp/a.txt"])
    let w = knownWindow(fileA: "/tmp/a.txt", fileB: "/tmp/b.txt")
    let pruned = LayoutRestore.pruned(w) { existing.contains($0) }

    check(pruned.tabs.count == 2, "the missing-file tab is dropped (\(pruned.tabs.count) left)")
    check(pruned.tabs.map(\.kind) == [.terminal, .viewer], "surviving tabs are terminal + fileA viewer")
    check(pruned.tabs[1].filePath == "/tmp/a.txt", "surviving viewer is fileA")

    // The right split had two viewer panes; one collapses, so that split
    // dissolves into a single pane. Expected tree: split(term | pane(fileA)).
    if case let .split(vertical, _, first, second) = pruned.tree {
        check(vertical, "outer split kept")
        if case let .pane(idx0, _) = first {
            check(idx0 == 0, "left pane still the terminal (index 0)")
        } else { check(false, "left is a pane") }
        // The right side collapsed from a split to the single surviving pane,
        // reindexed to 1 (fileA is now the 2nd tab).
        if case let .pane(idx1, font) = second {
            check(idx1 == 1, "right side collapsed to the fileA pane, reindexed to 1")
            check(font == 14, "the surviving pane keeps its per-pane font override")
        } else { check(false, "right side collapsed to a single pane, got \(String(describing: second))") }
    } else {
        check(false, "outer split preserved, got \(String(describing: pruned.tree))")
    }

    // mru/active reindex; the entry for the dropped tab (old index 2) falls out.
    check(pruned.mru == [1, 0], "mru reindexed, dropped-tab entry removed: \(String(describing: pruned.mru))")
    check(pruned.activeTabIndex == 1, "active tab (old 1 = fileA) reindexed to 1")

    // All files gone: only the terminal survives, tree collapses to its pane.
    let allGone = LayoutRestore.pruned(w) { _ in false }
    check(allGone.tabs.count == 1 && allGone.tabs[0].kind == .terminal, "only the terminal survives when all files are gone")
    if case .pane(let i, _) = allGone.tree { check(i == 0, "tree collapses to the terminal pane") }
    else { check(false, "tree collapses to a single pane") }
}

if failures == 0 {
    print("\nALL PASS")
    exit(0)
} else {
    print("\n\(failures) FAILURE(S)")
    exit(1)
}
