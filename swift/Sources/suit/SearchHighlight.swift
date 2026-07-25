import Foundation

// What a viewer paints for the sidebar's Search tab: every occurrence of the
// project pattern inside the file that is actually open, plus the lines that
// earn a minimap tick. Foundation-only so a harness can drive it (the
// FindReplace / EditorOps pattern); the Cocoa half is
// FileViewerPane+SearchHits.swift, which owns the attributes and the minimap.
//
// The matching itself is deliberately *not* re-implemented here — it is
// FindReplace's, driven by the same FindQuery the ⌘F bar uses, so a project
// pattern and a typed find agree about what a match is. rg answered "which
// files and which lines"; this answers "where exactly in this buffer", which rg
// never told us (its byte offsets are per line, and the buffer may already have
// been edited since the search ran).
//
// Two caps, both load-bearing:
//
//  * `maxPaintedRanges` bounds the highlight wash. Painting is one
//    addTemporaryAttribute per range on the main thread, and a one-letter
//    pattern in a megabyte file matches often enough to beachball.
//  * `maxMarkerLines` bounds the minimap ticks. Past a few hundred the strip is
//    a solid block, which tells the reader nothing while costing a fill each.
//
// `total` stays uncapped so a caller can still say how many there really are.
enum SearchHighlight {
    static let maxPaintedRanges = 2_000
    static let maxMarkerLines = 2_000

    struct Plan: Equatable {
        // Ranges to wash, in document order, capped.
        var ranges: [NSRange] = []
        // 1-based lines carrying at least one hit, deduped and capped — the
        // minimap draws one tick per line however many hits share it.
        var markerLines: [Int] = []
        // Every match, cap or no cap.
        var total = 0

        var isEmpty: Bool { total == 0 }
    }

    // `lineStarts` is the viewer's own (UTF-16 offsets of each line start), so
    // the marker lines line up with the gutter and the fold column without a
    // second pass over the text.
    static func plan(text: String, query: FindQuery, lineStarts: [Int]) -> Plan {
        guard !query.isEmpty else { return Plan() }
        let matches = FindReplace.matchRanges(in: text, query: query)
        guard !matches.isEmpty else { return Plan() }

        // Matches arrive in document order, so a hit on the same line as the
        // previous one is the only duplicate possible — no set needed.
        var lines: [Int] = []
        var lastLine = 0
        for match in matches {
            guard lines.count < maxMarkerLines else { break }
            let line = EditorOps.lineIndex(forOffset: match.location, lineStarts: lineStarts) + 1
            guard line != lastLine else { continue }
            lines.append(line)
            lastLine = line
        }

        return Plan(ranges: Array(matches.prefix(maxPaintedRanges)),
                    markerLines: lines,
                    total: matches.count)
    }
}
