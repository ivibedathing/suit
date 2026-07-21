import Foundation

// Back/forward jump history for symbol navigation — the thing that makes
// go-to-definition a *conversation* with the code rather than a one-way trip.
// Foundation-only so scripts/editor-nav-test.sh can assert the stack semantics;
// TerminalWindowController owns one instance per window and records a location
// before every navigating jump.
//
// The model is the browser's, not a plain undo stack: a cursor into a list.
// Going back moves the cursor without discarding anything, so forward still
// works; navigating somewhere *new* while the cursor is mid-list truncates the
// forward tail, because that branch of history is no longer reachable.

struct NavLocation: Equatable {
    let path: String
    let line: Int

    // Two locations on the same line of the same file are the same destination;
    // used to keep a repeated jump from stacking duplicates.
    static func == (lhs: NavLocation, rhs: NavLocation) -> Bool {
        lhs.path == rhs.path && lhs.line == rhs.line
    }
}

final class NavigationHistory {
    // Bounded so a long session can't grow it without limit; 100 is far past
    // what anyone retraces by hand.
    static let capacity = 100

    private(set) var entries: [NavLocation] = []
    // Index of the *current* location, or -1 when the history is empty.
    private(set) var cursor = -1

    var canGoBack: Bool { cursor > 0 }
    var canGoForward: Bool { cursor >= 0 && cursor < entries.count - 1 }
    var current: NavLocation? { entries.indices.contains(cursor) ? entries[cursor] : nil }

    // Record arriving somewhere. A jump to where we already are is ignored, so
    // clicking the same definition twice doesn't need two ⌃- to undo.
    func record(_ location: NavLocation) {
        if let current, current == location { return }
        // Navigating anew from mid-history drops the forward tail.
        if cursor < entries.count - 1 {
            entries.removeSubrange((cursor + 1)...)
        }
        entries.append(location)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        cursor = entries.count - 1
    }

    // Move the cursor and return where to go, or nil at the end of the list.
    func back() -> NavLocation? {
        guard canGoBack else { return nil }
        cursor -= 1
        return entries[cursor]
    }

    func forward() -> NavLocation? {
        guard canGoForward else { return nil }
        cursor += 1
        return entries[cursor]
    }

    // Replace the current entry's line without creating a new history step —
    // how the window keeps "where I was in this file" fresh as the caret moves,
    // so going back lands where you actually left rather than where you entered.
    func updateCurrentLine(_ line: Int) {
        guard entries.indices.contains(cursor) else { return }
        entries[cursor] = NavLocation(path: entries[cursor].path, line: line)
    }

    func clear() {
        entries = []
        cursor = -1
    }
}
