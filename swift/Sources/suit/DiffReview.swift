import Foundation

// ROADMAP Phase 16 — diff review comments, batched to Claude. Phase 5 opened
// the review loop (a review set, n/p walk); this closes it. Instead of eyeballing
// a diff and retyping feedback into a session's pane by hand, comment on lines the
// way you would on a GitHub PR, then pipe the whole batch into a chosen Claude
// session as one structured prompt (via Phase 8's SessionControl).
//
// UI-free so it can be tested standalone (composePrompt / Codable round-trip) and
// reused: `DiffPaneContent` owns a draft, and it travels with the diff tab through
// state restoration.

// One comment, anchored to a specific line of the diff. The anchor (file + side +
// line number) survives a re-render or a Refresh, and carries the code line itself
// so the composed prompt and the inspector both read on their own.
struct DiffReviewComment: Codable, Equatable {
    // Which side of the diff the line lives on: a deletion is old-side, an
    // addition or context line is new-side.
    enum Side: String, Codable { case old, new }

    var file: String       // the diff's b/ path (a/ path for a deleted file)
    var side: Side
    var line: Int          // old-side line for deletions, new-side otherwise
    var lineText: String   // the diff line's code — context for the prompt/inspector
    var text: String       // the reviewer's note

    func anchors(file: String, side: Side, line: Int) -> Bool {
        self.file == file && self.side == side && self.line == line
    }
}

// The per-diff-pane review draft: an ordered set of comments (one per anchored
// line) with add/update/remove/clear plus the prompt composition. Not persisted
// itself — the diff tab serializes `comments` into its `SavedTab`.
final class DiffReviewDraft {
    private(set) var comments: [DiffReviewComment]

    init(comments: [DiffReviewComment] = []) { self.comments = comments }

    var isEmpty: Bool { comments.isEmpty }
    var count: Int { comments.count }

    func comment(file: String, side: DiffReviewComment.Side, line: Int) -> DiffReviewComment? {
        comments.first { $0.anchors(file: file, side: side, line: line) }
    }

    // Adds or replaces the note at an anchor (one comment per line); an empty
    // note deletes whatever was there.
    func set(text: String, file: String, side: DiffReviewComment.Side, line: Int, lineText: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = comments.firstIndex(where: { $0.anchors(file: file, side: side, line: line) }) {
            if trimmed.isEmpty {
                comments.remove(at: i)
            } else {
                comments[i].text = trimmed
                comments[i].lineText = lineText
            }
        } else if !trimmed.isEmpty {
            comments.append(DiffReviewComment(file: file, side: side, line: line, lineText: lineText, text: trimmed))
        }
    }

    func remove(_ comment: DiffReviewComment) {
        comments.removeAll { $0 == comment }
    }

    func clear() {
        comments.removeAll()
    }

    // The whole draft as one structured prompt: grouped by file in first-appearance
    // order, each note carrying its line number and the code it's about. This is
    // exactly what gets sent into the session's pty.
    func composePrompt(ref: String) -> String {
        guard !comments.isEmpty else { return "" }
        var out = "Here's my review of \(ref). Please address each comment:\n"
        var fileOrder: [String] = []
        for c in comments where !fileOrder.contains(c.file) { fileOrder.append(c.file) }
        for file in fileOrder {
            out += "\n### \(file)\n"
            for c in comments.filter({ $0.file == file }).sorted(by: { $0.line < $1.line }) {
                let code = c.lineText.trimmingCharacters(in: .whitespaces)
                if code.isEmpty {
                    out += "- Line \(c.line): \(c.text)\n"
                } else {
                    out += "- Line \(c.line) `\(code)`: \(c.text)\n"
                }
            }
        }
        return out
    }
}
