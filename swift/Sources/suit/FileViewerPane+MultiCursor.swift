import Cocoa

// Multi-selection editing for the viewer: ⌃⌘E add-next-occurrence, ⌃⌘G
// select-all-occurrences, and ⌥-drag for a rectangular (column) selection. The
// range math is pure and harness-tested in EditorOps.swift; this is the AppKit
// half that turns a set of ranges into one undoable edit.
//
// **This is multi-*selection*, not multi-*cursor*, and the difference is forced
// on us by AppKit.** The set lives in NSTextView's `selectedRanges`, which keeps
// several *non-empty* ranges alive across the edits we make — but silently
// collapses a set made only of *zero-length* ranges down to one. Verified on
// macOS 27: setting three bare carets returns one. So:
//
//   * Operations that act on whole selections — ⌘/ comment, ⌃⌘] indent, wrapping
//     a selection in brackets, delete — apply to every range, as one undo step,
//     via editAtAllCursors below. These work.
//   * Free-form typing across several sites does not exist, and can't be faked:
//     a batch replace handles the first keystroke, but the zero-length carets it
//     leaves collapse, so the rest of the word would go to one place. Typing
//     over a multi-selection beeps rather than corrupting (see +SmartTyping).
//   * ⌥-click extra carets were removed for the same reason — they never existed.
//
// Doing it properly means owning the caret set here and drawing the carets
// ourselves instead of delegating to selectedRanges. That's a real project, not
// a patch, and it needs interactive testing to land safely.
extension FileViewerPaneContent {

    // Every cursor, document order. selectedRanges is documented non-empty, but
    // it comes back as [NSValue] and the sort matters to every caller, so this
    // is the single place that unwraps it.
    var cursorRanges: [NSRange] {
        textView.selectedRanges.map { $0.rangeValue }.sorted { $0.location < $1.location }
    }

    var hasMultipleCursors: Bool { textView.selectedRanges.count > 1 }

    func setCursorRanges(_ ranges: [NSRange]) {
        guard !ranges.isEmpty else { return }
        textView.setSelectedRanges(ranges.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
        textView.needsDisplay = true
    }

    // Collapse back to a single caret — Esc, and anything that would be
    // ambiguous with several cursors live.
    func collapseToSingleCursor() {
        guard hasMultipleCursors else { return }
        let primary = textView.selectedRange()
        textView.setSelectedRanges([NSValue(range: primary)], affinity: .downstream, stillSelecting: false)
        textView.needsDisplay = true
    }

    // MARK: - The shared edit pipeline

    // Apply one edit per cursor as a single undoable change, then put a cursor
    // back at each edited site.
    //
    // `replacement` is asked about each cursor and returns what to replace, or
    // nil to leave that cursor alone. The replaced `range` defaults to the
    // cursor's own but doesn't have to be it — backspacing an empty bracket pair
    // deletes a character on either side of a zero-length caret — and
    // `caretOffset` is where the caret lands inside the inserted text, which is
    // what puts it between the halves of an auto-closed pair.
    //
    // Ranges are applied low-to-high with a running offset rather than
    // high-to-low: the arithmetic is the same either way, but this order lets the
    // caret positions be computed in the same pass, in final-document
    // coordinates, instead of being fixed up afterwards.
    typealias CursorEdit = (range: NSRange, text: String, caretOffset: Int)

    @discardableResult
    func editAtAllCursors(_ replacement: (NSRange) -> CursorEdit?) -> Bool {
        guard isEditableFile, textView.isEditable, let storage = textView.textStorage else { return false }

        let length = (textView.string as NSString).length
        var edits: [CursorEdit] = []
        for cursor in cursorRanges {
            guard let result = replacement(cursor) else { continue }
            // A malformed range from a caller is a crash inside beginEditing,
            // with no clue where it came from — refuse the whole batch instead.
            guard result.range.location >= 0, NSMaxRange(result.range) <= length else { return false }
            // Overlapping edits would make the running offset meaningless.
            if let previous = edits.last, result.range.location < NSMaxRange(previous.range) { return false }
            edits.append(result)
        }
        guard !edits.isEmpty else { return false }

        // One shouldChangeText for the whole batch is what makes it one undo
        // step; NSTextView coalesces the ranges into a single undo grouping.
        guard textView.shouldChangeText(
            inRanges: edits.map { NSValue(range: $0.range) },
            replacementStrings: edits.map { $0.text }
        ) else { return false }

        // Typing attributes carry the document font/colour; replacing with a
        // bare String would drop them and leave the new text unstyled until the
        // next re-highlight.
        let attributes = textView.typingAttributes

        storage.beginEditing()
        var carets: [NSRange] = []
        var delta = 0
        for edit in edits {
            let target = NSRange(location: edit.range.location + delta, length: edit.range.length)
            storage.replaceCharacters(in: target, with: NSAttributedString(string: edit.text, attributes: attributes))
            carets.append(NSRange(location: target.location + edit.caretOffset, length: 0))
            delta += (edit.text as NSString).length - edit.range.length
        }
        storage.endEditing()
        textView.didChangeText()

        setCursorRanges(carets)
        return true
    }

    // MARK: - ⌘D — add the next occurrence

    func selectNextOccurrence() {
        let text = textView.string
        let ranges = cursorRanges
        guard let last = ranges.last else { return }

        // Nothing selected yet: the first ⌘D selects the word under the caret,
        // exactly as in VS Code, so the gesture is "press it once to pick the
        // thing, again for each extra site".
        if last.length == 0 {
            guard let word = EditorOps.wordRange(in: text, at: last.location) else { NSSound.beep(); return }
            setCursorRanges([word])
            textView.scrollRangeToVisible(word)
            return
        }

        let needle = (text as NSString).substring(with: last)
        guard let next = EditorOps.nextOccurrence(
            of: needle, in: text, from: NSMaxRange(last), excluding: ranges
        ) else { NSSound.beep(); return }

        setCursorRanges(ranges + [next])
        textView.scrollRangeToVisible(next)
    }

    // ⌃⌘G — every occurrence at once.
    func selectAllOccurrences() {
        let text = textView.string
        let ranges = cursorRanges
        guard let last = ranges.last else { return }

        let needle: String
        if last.length > 0 {
            needle = (text as NSString).substring(with: last)
        } else if let word = EditorOps.wordRange(in: text, at: last.location) {
            needle = (text as NSString).substring(with: word)
        } else {
            NSSound.beep()
            return
        }

        let all = EditorOps.allOccurrences(of: needle, in: text)
        guard !all.isEmpty else { NSSound.beep(); return }
        setCursorRanges(all)
        if let first = all.first { textView.scrollRangeToVisible(first) }
    }

    // MARK: - ⌥-drag

    // ⌥-drag: a rectangular selection between the drag's anchor and the current
    // point, recomputed live as the mouse moves. This survives where extra
    // carets don't, because a column selection is made of *non-empty* ranges.
    func setColumnSelection(from anchor: Int, to head: Int) {
        let ranges = EditorOps.columnRanges(text: textView.string, from: anchor, to: head)
        guard !ranges.isEmpty else { return }
        setCursorRanges(ranges)
    }
}
