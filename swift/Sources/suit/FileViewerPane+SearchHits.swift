import Cocoa

// The viewer's half of the sidebar Search tab's highlighting: while a project
// pattern is live, every occurrence of it in this file is washed in the
// search-hit yellow and ticked on the minimap. Clicking a result scrolls you to
// one match; this is what answers "and where are the others" without re-reading
// the results list. The pure decisions (which ranges, which lines, the caps) are
// SearchHighlight.swift; the pattern is pushed in by the window controller,
// which mirrors it onto every open viewer.
//
// Two things this file exists to keep straight:
//
//  1. The wash and the ⌘F bar share one .backgroundColor temporary-attribute
//     layer, so nothing here paints directly — it goes through
//     repaintHighlightLayer() in FileViewerPane+Find.swift, which paints both.
//  2. Ranges computed against one buffer are lethal against another (an
//     out-of-bounds temporary attribute raises, it doesn't fail soft). Every
//     read goes through `currentSearchHits()`, which re-derives whenever
//     `loadGeneration` has moved — the same guard the find bar uses, and the
//     reason typing into a file while a search is up stays safe.
extension FileViewerPaneContent {

    // Called by the window controller: the Search tab's pattern, or nil when the
    // field was emptied. A pattern that hasn't changed is not re-derived — every
    // open viewer gets this on every search, and most of them didn't move.
    func setSearchHitQuery(_ query: FindQuery?) {
        let wanted = (query?.isEmpty ?? true) ? nil : query
        guard wanted != searchHitQuery else { return }
        searchHitQuery = wanted
        searchHitGeneration = -1
        refreshSearchHits()
    }

    // Re-derive against the current buffer and repaint both surfaces. Cheap
    // enough to call on load and on a settled edit; it is one pass over the text.
    func refreshSearchHits() {
        searchHitGeneration = -1
        _ = currentSearchHits()
        repaintHighlightLayer()
        updateMinimapMarkers()
    }

    // The hit ranges for the current buffer, recomputed if anything has touched
    // the text since they were last built. Never read `searchHitRanges` directly.
    @discardableResult
    func currentSearchHits() -> [NSRange] {
        guard searchHitGeneration != loadGeneration else { return searchHitRanges }
        let plan = searchHitQuery.map {
            SearchHighlight.plan(text: textView.string, query: $0, lineStarts: lineStarts)
        } ?? SearchHighlight.Plan()
        searchHitRanges = plan.ranges
        searchHitLines = plan.markerLines
        searchHitGeneration = loadGeneration
        return searchHitRanges
    }

    // The lines carrying hits, for the minimap. Goes through the same recompute
    // as the ranges: updateMinimapMarkers() is also called for git status and
    // bookmark changes, which can land long after the buffer last moved.
    func currentSearchHitLines() -> [Int] {
        currentSearchHits()
        return searchHitLines
    }

    // Typing shifts every range after the caret, so the wash and the ticks both
    // have to follow the edit rather than point into the pre-edit text. Called
    // from textDidChange beside findBarDidSeeEdit, and a no-op when no project
    // search is running.
    func searchHitsDidSeeEdit() {
        guard searchHitQuery != nil else { return }
        refreshSearchHits()
    }
}
