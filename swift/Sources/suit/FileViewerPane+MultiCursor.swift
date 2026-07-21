import Cocoa

// Multi-cursor editing for the viewer: ⌘D add-next-occurrence, ⌃⌘G select-all-
// occurrences, ⌥-click to drop an extra caret, and ⌥-drag for a rectangular
// (column) selection. The range math is pure and harness-tested in
// EditorOps.swift; this is the AppKit half that turns a set of ranges into one
// undoable edit and paints the extra carets.
//
// The cursor set is *not* stored here. NSTextView already has a first-class
// notion of discontiguous selection (`selectedRanges`), it renders every
// non-empty range highlighted for free, and — crucially — it keeps the ranges
// alive across the text storage edits we make. A parallel array would have to be
// re-derived after every edit, and would be wrong for exactly one frame every
// time. What NSTextView does *not* do is type into more than the first range,
// which is what editAtAllCursors below supplies.
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

    // MARK: - ⌥-click / ⌥-drag

    // ⌥-click toggles a caret at `offset`: clicking an existing one removes it,
    // so a mis-drop costs one click rather than a restart. The last cursor is
    // never removable — a text view with no selection has nowhere to type.
    func toggleCaret(atOffset offset: Int) {
        var ranges = cursorRanges
        if let hit = ranges.firstIndex(where: { NSLocationInRange(offset, $0) || $0.location == offset }) {
            guard ranges.count > 1 else { return }
            ranges.remove(at: hit)
        } else {
            ranges.append(NSRange(location: offset, length: 0))
        }
        setCursorRanges(ranges.sorted { $0.location < $1.location })
    }

    // ⌥-drag: a rectangular selection between the drag's anchor and the current
    // point, recomputed live as the mouse moves.
    func setColumnSelection(from anchor: Int, to head: Int) {
        let ranges = EditorOps.columnRanges(text: textView.string, from: anchor, to: head)
        guard !ranges.isEmpty else { return }
        setCursorRanges(ranges)
    }

    // MARK: - Extra-caret painting

    // The caret rects for every zero-length cursor beyond the primary one.
    // NSTextView blinks exactly one insertion point, so the others are drawn by
    // ViewerTextView from this list. They're drawn solid rather than blinking:
    // several carets blinking out of phase reads as flicker, and a static bar is
    // how every other editor renders the non-primary ones.
    func extraCaretRects() -> [NSRect] {
        guard hasMultipleCursors else { return [] }
        let primary = textView.selectedRange()
        return cursorRanges
            .filter { $0.length == 0 && $0.location != primary.location }
            .compactMap { caretRect(atOffset: $0.location) }
    }

    private func caretRect(atOffset offset: Int) -> NSRect? {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return nil }
        let length = (textView.string as NSString).length
        guard offset >= 0, offset <= length else { return nil }

        layoutManager.ensureLayout(for: container)
        let inset = textView.textContainerInset

        // Past the last glyph (end of a document ending in a newline) there is no
        // glyph to locate — TextKit keeps a dedicated rect for that position.
        let glyph = layoutManager.glyphIndexForCharacter(at: offset)
        if glyph >= layoutManager.numberOfGlyphs {
            let extra = layoutManager.extraLineFragmentRect
            guard extra != .zero else { return nil }
            return NSRect(x: extra.minX + inset.width, y: extra.minY + inset.height,
                          width: 1, height: extra.height)
        }

        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let location = layoutManager.location(forGlyphAt: glyph)
        return NSRect(x: fragment.minX + location.x + inset.width,
                      y: fragment.minY + inset.height,
                      width: 1, height: fragment.height)
    }
}
