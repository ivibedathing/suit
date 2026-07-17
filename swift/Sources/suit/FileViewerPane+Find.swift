import Cocoa

// The ⌘F find/replace bar's wiring for the file viewer. Split out of
// FileViewerPane.swift like the editing/highlighting/blame halves; the pure
// matching and replacement decisions live in FindReplace.swift (harness-tested)
// and the widget chrome in FindBarView.swift. The stored state (findBar,
// findMatches, findMatchIndex, findMatchGeneration) is on the primary declaration.
//
// Two things here are load-bearing and easy to get wrong:
//
//  1. Match ranges go stale the instant the buffer changes, and painting or
//     scrolling to an out-of-bounds NSRange raises an ObjC exception rather than
//     failing softly. Every read goes through `currentFindMatches()`, which
//     recomputes whenever `loadGeneration` has moved — that covers all four
//     buffer swaps (load, time-travel render, disk adoption, and live typing),
//     since each already bumps the generation.
//  2. Highlights are *temporary* attributes on the layout manager, never document
//     attributes: applySyntaxAttributes() strips foreground colour across the whole
//     document on every re-highlight, and a document-level background would dirty
//     the buffer. Temporary attributes survive both.
extension FileViewerPaneContent {

    // MARK: - Menu entry points

    // Everything the Find menu sends (⌘F / ⌘G / ⇧⌘G / ⌘E) arrives here from
    // ViewerTextView.performFindPanelAction.
    func performFind(_ action: NSFindPanelAction) {
        switch action {
        case .showFindPanel:
            openFindBar(showReplace: false)
        case .next:
            stepFind(forward: true)
        case .previous:
            stepFind(forward: false)
        case .setFindString:
            useSelectionForFind()
        case .replace:
            replaceCurrentMatch()
        case .replaceAll:
            replaceAllMatches()
        default:
            break
        }
    }

    // ⌥⌘F — same bar, replace row already open.
    func showFindAndReplace() {
        openFindBar(showReplace: true)
    }

    // MARK: - Opening & closing

    func openFindBar(showReplace: Bool) {
        let bar = findBar ?? makeFindBar()
        if showReplace { bar.isReplaceVisible = true }
        bar.canReplace = textView.isEditable

        // Seed from the selection, else from whatever the last find was —
        // sharing the system find pasteboard is what makes a query typed in one
        // pane (or another app) carry into this one.
        let selection = textView.selectedRange()
        if selection.length > 0, let selected = selectedFindString(in: selection) {
            bar.setQueryText(selected)
            writeToFindPasteboard(selected)
        } else if bar.query.isEmpty, let remembered = findPasteboardString {
            bar.setQueryText(remembered)
        }

        refreshFindMatches(recenterOnCaret: true)
        bar.focusFindField()
    }

    private func makeFindBar() -> FindBarView {
        let bar = FindBarView()
        bar.onQueryChange = { [weak self] in
            guard let self else { return }
            self.writeToFindPasteboard(self.findBar?.query.text ?? "")
            self.refreshFindMatches(recenterOnCaret: true)
        }
        bar.onStep = { [weak self] forward in self?.stepFind(forward: forward) }
        bar.onReplace = { [weak self] in self?.replaceCurrentMatch() }
        bar.onReplaceAll = { [weak self] in self?.replaceAllMatches() }
        bar.onClose = { [weak self] in self?.closeFindBar() }
        findBar = bar
        container.findOverlay = bar
        return bar
    }

    func closeFindBar() {
        clearFindHighlights()
        findBar = nil
        container.findOverlay = nil
        findMatches = []
        findMatchIndex = 0
        findMatchGeneration = -1
        // Focus goes back to the text, not to whatever AppKit picks. The pane's
        // focus border is derived from firstResponder by the window controller,
        // so handing it back here is what keeps the border lit.
        textView.window?.makeFirstResponder(textView)
    }

    // ⌘E: the selection becomes the query without opening the bar, so a
    // subsequent ⌘G steps through it — the standard macOS behaviour, and the
    // reason this honours the find pasteboard at all.
    private func useSelectionForFind() {
        let selection = textView.selectedRange()
        guard selection.length > 0, let selected = selectedFindString(in: selection) else { return }
        writeToFindPasteboard(selected)
        findBar?.setQueryText(selected)
        refreshFindMatches(recenterOnCaret: true)
    }

    // A multi-line selection is a range to search *in* in VS Code, not a query;
    // treating it as one produces a query nobody wants. Single-line only.
    private func selectedFindString(in selection: NSRange) -> String? {
        let ns = textView.string as NSString
        guard selection.location + selection.length <= ns.length else { return nil }
        let text = ns.substring(with: selection)
        return text.contains("\n") ? nil : text
    }

    private var findPasteboardString: String? {
        NSPasteboard(name: .find).string(forType: .string)
    }

    private func writeToFindPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard(name: .find)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Matching

    // The match list for the current buffer, recomputed if anything has touched
    // the text since it was last built. Never read `findMatches` directly.
    @discardableResult
    func currentFindMatches() -> [NSRange] {
        guard findMatchGeneration != loadGeneration else { return findMatches }
        let query = findBar?.query ?? FindQuery()
        findMatches = FindReplace.matchRanges(in: textView.string, query: query)
        findMatchGeneration = loadGeneration
        findMatchIndex = min(findMatchIndex, max(0, findMatches.count - 1))
        return findMatches
    }

    // Recompute, repaint and re-report. `recenterOnCaret` picks the match nearest
    // the caret (opening the bar, or changing the query); stepping passes false to
    // keep the index it just moved to.
    func refreshFindMatches(recenterOnCaret: Bool) {
        guard let bar = findBar else { return }
        // Force a recompute: the query may have changed without the buffer moving.
        findMatchGeneration = -1
        let matches = currentFindMatches()

        if recenterOnCaret {
            findMatchIndex = FindReplace.initialIndex(for: matches, caret: textView.selectedRange().location) ?? 0
        }

        let query = bar.query
        bar.showStatus(index: matches.isEmpty ? nil : findMatchIndex,
                       count: matches.count,
                       invalidPattern: !FindReplace.isValid(query))
        applyFindHighlights()
        if recenterOnCaret, !matches.isEmpty {
            revealCurrentMatch(moveSelection: false)
        }
    }

    // Called from textDidChange: typing invalidates the match list, and the bar's
    // count has to follow the edit rather than lie about it.
    func findBarDidSeeEdit() {
        guard findBar != nil else { return }
        refreshFindMatches(recenterOnCaret: false)
    }

    // Time-travel and reloads flip editability underneath an open bar; the replace
    // row has to follow or it would offer to edit a read-only revision.
    func refreshFindEditability() {
        findBar?.canReplace = textView.isEditable
        guard findBar != nil else { return }
        refreshFindMatches(recenterOnCaret: false)
    }

    // MARK: - Stepping

    private func stepFind(forward: Bool) {
        let matches = currentFindMatches()
        guard !matches.isEmpty else {
            // ⌘G with no bar open and nothing on the find pasteboard: open the bar
            // rather than silently doing nothing.
            if findBar == nil { openFindBar(showReplace: false) }
            return
        }
        guard let next = FindReplace.step(from: findMatchIndex, count: matches.count, forward: forward) else { return }
        findMatchIndex = next
        findBar?.showStatus(index: findMatchIndex, count: matches.count, invalidPattern: false)
        applyFindHighlights()
        revealCurrentMatch(moveSelection: true)
    }

    // Scroll the current match into view. `moveSelection` is false while the bar
    // is being retargeted: moving the caret then would fight the field editor for
    // first responder and yank focus out of the find field mid-typing.
    private func revealCurrentMatch(moveSelection: Bool) {
        let matches = currentFindMatches()
        guard findMatchIndex < matches.count else { return }
        let range = matches[findMatchIndex]
        guard isRangeInBounds(range) else { return }
        if moveSelection {
            textView.setSelectedRange(range)
        }
        textView.scrollRangeToVisible(range)
    }

    // MARK: - Highlighting

    // Painting is capped because it runs on the main thread on every keystroke:
    // a one-letter query in a multi-megabyte file matches hundreds of thousands
    // of times, and that many addTemporaryAttribute calls per keypress is a
    // beachball. The counter still reports the true total — only the wash is
    // capped, and the current match is always painted however far down it is, so
    // stepping past the cap still shows you where you are.
    private static let maxPaintedHighlights = 2000

    private func applyFindHighlights() {
        guard let layoutManager = textView.layoutManager else { return }
        clearFindHighlights()
        let matches = currentFindMatches()
        guard !matches.isEmpty else { return }

        func paint(_ range: NSRange, current: Bool) {
            guard isRangeInBounds(range) else { return }
            // The current match gets the stronger fill, so "which one am I on" is
            // answerable without reading the counter.
            let colour = current ? Theme.accent.withAlphaComponent(0.55) : Theme.selection
            layoutManager.addTemporaryAttribute(.backgroundColor, value: colour, forCharacterRange: range)
        }

        for (index, range) in matches.prefix(Self.maxPaintedHighlights).enumerated() {
            paint(range, current: index == findMatchIndex)
        }
        if findMatchIndex >= Self.maxPaintedHighlights, findMatchIndex < matches.count {
            paint(matches[findMatchIndex], current: true)
        }
    }

    private func clearFindHighlights() {
        guard let layoutManager = textView.layoutManager else { return }
        // Cleared over the *current* full range rather than over the ranges we
        // painted: the painted ones may already be out of bounds after an edit,
        // and a full-range clear can't be stale.
        //
        // This shares .backgroundColor with the go-to-line jump flash, so the two
        // step on each other in both directions: clearing here wipes a flash
        // mid-fade, and the flash's own delayed removal (jump(toLine:)) clears any
        // match highlight on that line until the next refresh. Both are cosmetic
        // and both are rare — a jump and a find are seldom in flight together.
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
    }

    private func isRangeInBounds(_ range: NSRange) -> Bool {
        let length = (textView.string as NSString).length
        return range.location >= 0 && range.length >= 0 && range.location + range.length <= length
    }

    // MARK: - Replacing

    private func replaceCurrentMatch() {
        guard let bar = findBar, textView.isEditable else { return }
        let matches = currentFindMatches()
        guard findMatchIndex < matches.count else { return }
        let range = matches[findMatchIndex]
        guard isRangeInBounds(range) else { return }

        let replacement = FindReplace.replacementText(in: textView.string, matchRange: range,
                                                      query: bar.query, template: bar.replacementTemplate)
        // shouldChangeText/didChangeText bracket the edit so undo coalesces it and
        // the delegate's textDidChange fires — that's what keeps the dirty chip,
        // the gutter and autosave honest. Assigning textView.string would skip all
        // three (isLoadingProgrammatically suppresses the delegate).
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()

        // Land on the next match after the one just replaced, VS Code style. The
        // edit shifted everything after it, so re-derive from the new text rather
        // than reusing the old index.
        refreshFindMatches(recenterOnCaret: false)
        let after = range.location + (replacement as NSString).length
        findMatchIndex = FindReplace.initialIndex(for: currentFindMatches(), caret: after) ?? 0
        refreshFindStatusAfterReplace()
        revealCurrentMatch(moveSelection: false)
    }

    private func replaceAllMatches() {
        guard let bar = findBar, textView.isEditable else { return }
        let text = textView.string
        let result = FindReplace.replaceAll(in: text, query: bar.query, template: bar.replacementTemplate)
        guard result.count > 0 else { return }

        // One edit over the whole document, not N per-match edits: N edits would
        // mean N undo steps to walk back a single Replace All, and N textDidChange
        // storms each restarting the autosave and re-highlight timers.
        let full = NSRange(location: 0, length: (text as NSString).length)
        let caret = textView.selectedRange().location
        let visible = scrollView.contentView.bounds.origin
        guard textView.shouldChangeText(in: full, replacementString: result.text) else { return }
        textView.textStorage?.replaceCharacters(in: full, with: result.text)
        textView.didChangeText()

        // Replacing the whole string drops selection and scroll to the top; put
        // both back so a Replace All doesn't lose the user's place.
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: min(caret, length), length: 0))
        scrollView.contentView.scroll(to: visible)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        refreshFindMatches(recenterOnCaret: false)
    }

    private func refreshFindStatusAfterReplace() {
        let matches = currentFindMatches()
        findBar?.showStatus(index: matches.isEmpty ? nil : findMatchIndex,
                            count: matches.count,
                            invalidPattern: false)
        applyFindHighlights()
    }
}
