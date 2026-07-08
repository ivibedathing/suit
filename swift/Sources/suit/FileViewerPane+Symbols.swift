import Cocoa

// Symbol-aware navigation from the viewer (ROADMAP Phase 33): pull the
// identifier at a caret / click / selection out of the text and route it
// through the pane → host to the symbol index. Pure token extraction lives in
// SymbolLookup (SymbolIndex.swift); this bridges it to the text view's
// character indexing.
extension FileViewerPaneContent {
    // The identifier the user means: the current selection when it's a single
    // token, otherwise the word at the caret.
    func identifierAtCaret() -> String? {
        let range = textView.selectedRange()
        if range.length > 0 {
            let selected = (textView.string as NSString)
                .substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !selected.isEmpty,
               selected.unicodeScalars.allSatisfy({ SymbolLookup.isIdentifierChar($0) }) {
                return selected
            }
        }
        return identifier(atCharacterIndex: range.location)
    }

    // The identifier straddling a character offset (a Cmd-click / right-click
    // target), resolved within its own line so SymbolLookup's UTF-16 math is
    // line-local.
    func identifier(atCharacterIndex index: Int) -> String? {
        let ns = textView.string as NSString
        guard ns.length > 0 else { return nil }
        let clamped = min(max(index, 0), ns.length)
        let line = lineStartIndex(forCharacterAt: clamped)
        let start = lineStarts[line]
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : ns.length
        let lineText = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
        return SymbolLookup.identifier(in: lineText, atUTF16Offset: clamped - start)
    }

    // 0-based index into lineStarts of the line owning a character offset — the
    // last line start ≤ offset, by binary search (mirrors the gutter lookup).
    private func lineStartIndex(forCharacterAt offset: Int) -> Int {
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

    func goToDefinitionAtCaret() {
        guard let identifier = identifierAtCaret(), let pane else { NSSound.beep(); return }
        pane.goToDefinition(identifier: identifier, fromFile: filePath)
    }

    func findReferencesAtCaret() {
        guard let identifier = identifierAtCaret(), let pane else { NSSound.beep(); return }
        pane.findReferences(identifier: identifier, fromFile: filePath)
    }
}
