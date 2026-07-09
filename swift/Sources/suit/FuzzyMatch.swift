import Foundation

// The app's one fuzzy matcher, shared by the command palette (Cmd-K commands,
// Cmd-P files), the definition picker, and the ⌃R command-history overlay
// (ROADMAP Phase 43). Kept in a Foundation-only file so the standalone logic
// harnesses can compile the pieces that rank against it (command-history-test)
// without pulling in AppKit.
//
// Case-insensitive subsequence match. Consecutive matches and word-start
// matches score higher, so "spv" prefers "Split Vertically" over incidental
// letter scatter. Word starts include path/identifier separators so the same
// scorer works for file paths ("pane" hits Pane.swift's basename hard).
// Returns nil when the query isn't a subsequence at all; an empty query
// matches everything equally.
func fuzzyScore(query: String, candidate: String) -> Int? {
    if query.isEmpty { return 0 }
    let q = Array(query.lowercased())
    let c = Array(candidate.lowercased())
    var score = 0
    var qi = 0
    var lastMatch = -2
    for (i, ch) in c.enumerated() {
        guard qi < q.count else { break }
        guard ch == q[qi] else { continue }
        score += 1
        if i == lastMatch + 1 { score += 2 }
        if i == 0 || " /_-.".contains(c[i - 1]) { score += 3 }
        lastMatch = i
        qi += 1
    }
    return qi == q.count ? score : nil
}
