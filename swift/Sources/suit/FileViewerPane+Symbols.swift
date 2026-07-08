import Cocoa

// Go-to-definition & find-references from the viewer (ROADMAP Phase 33): pull
// the identifier out from under the caret (menu / keystroke) or a Cmd-click,
// and hand it to the host, which owns the symbol index and the tab it opens
// into (Pane.goToDefinition / findReferences → the window controller). This is
// the semantic sibling of the terminal's Cmd-click-on-a-path link — same
// "resolve what's under the cursor, then route through the pane" shape.
extension FileViewerPaneContent {

    // The word under the insertion point, or the current selection when it is
    // itself a single identifier (so selecting `fooBar` and asking works even if
    // the caret logic would trip on a boundary). nil when there's nothing
    // symbol-shaped to act on.
    func symbolAtCaret() -> String? {
        let range = textView.selectedRange()
        if range.length > 0 {
            let selected = (textView.string as NSString).substring(with: range)
            if let identifier = SymbolIndexCore.identifier(in: selected, atUTF16Offset: 0),
               identifier.utf16.count == (selected as NSString).length {
                return identifier
            }
        }
        return symbol(atCharacterOffset: range.location)
    }

    // The identifier straddling a document character offset (a Cmd-click's hit
    // index, or the caret), resolved within its own line so column math stays
    // local.
    func symbol(atCharacterOffset offset: Int) -> String? {
        guard let (lineText, column) = lineAndColumn(forCharacterAt: offset) else { return nil }
        return SymbolIndexCore.identifier(in: lineText, atUTF16Offset: column)
    }

    // Cmd-click entry point: resolve + navigate, returning whether an identifier
    // was found so ViewerTextView knows to swallow the click (vs. fall through
    // to normal selection).
    @discardableResult
    func goToDefinition(atCharacterOffset offset: Int) -> Bool {
        guard let symbol = symbol(atCharacterOffset: offset) else { return false }
        pane?.goToDefinition(symbol: symbol, fromDirectory: workingDirectory)
        return true
    }

    // Menu / keystroke entry points (caret-based).
    func goToDefinitionAtCaret() {
        guard let symbol = symbolAtCaret() else { NSSound.beep(); return }
        pane?.goToDefinition(symbol: symbol, fromDirectory: workingDirectory)
    }

    func findReferencesAtCaret() {
        guard let symbol = symbolAtCaret() else { NSSound.beep(); return }
        pane?.findReferences(symbol: symbol, fromDirectory: workingDirectory)
    }

    // The line's text (newline stripped) and the UTF-16 column of `offset`
    // within it — the shape SymbolIndexCore.identifier(in:atUTF16Offset:) wants.
    // lineStarts is in the document's UTF-16 offsets (built from NSString
    // ranges), so the arithmetic is exact.
    private func lineAndColumn(forCharacterAt offset: Int) -> (line: String, column: Int)? {
        let ns = textView.string as NSString
        guard offset >= 0, offset <= ns.length, !lineStarts.isEmpty else { return nil }
        let lineIdx = lineIndex(forCharacterAt: offset)
        let start = lineStarts[lineIdx]
        let end = lineIdx + 1 < lineStarts.count ? lineStarts[lineIdx + 1] : ns.length
        guard start <= ns.length, end <= ns.length, start <= end else { return nil }
        var lineText = ns.substring(with: NSRange(location: start, length: end - start))
        if lineText.hasSuffix("\n") { lineText = String(lineText.dropLast()) }
        return (lineText, offset - start)
    }

    // The 0-based index into lineStarts of the line owning `offset` (the last
    // start ≤ offset), by binary search.
    private func lineIndex(forCharacterAt offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }
}
