import Cocoa

// Code folding in the viewer: gutter chevrons, ⌥⌘[ / ⌥⌘] to fold and unfold the
// block around the caret, fold-all / unfold-all, and the state that survives a
// re-render. Regions come from CodeFolding (pure, harness-tested); hiding comes
// from FoldingLayoutManager; this is the glue and the invariants.
//
// The load-bearing invariant is that folded state is expressed as a set of
// *start lines*, never as ranges. Lines move on every edit, but the line that
// opens a block is the one the user pointed at, and after a re-parse the fold
// either still exists at that line or it doesn't — which makes prune() a
// one-liner and makes a stale fold impossible.
extension FileViewerPaneContent {

    var foldingLayoutManager: FoldingLayoutManager? {
        textView.layoutManager as? FoldingLayoutManager
    }

    // MARK: - Region discovery

    // Recompute the foldable regions for the current buffer. Called on load and
    // debounced behind edits, alongside re-highlighting — folding a file being
    // actively typed into would be both expensive and useless.
    func refreshFoldRegions() {
        guard let filePath else {
            foldRegions = []
            foldedStarts = []
            applyFolds()
            return
        }
        foldRegions = CodeFolding.regions(in: textView.string, language: EditorLanguage.detect(path: filePath))
        // An edit can delete the block a fold was holding closed; drop those
        // rather than leaving lines hidden with no chevron to bring them back.
        foldedStarts = CodeFolding.prune(foldedStarts: foldedStarts, regions: foldRegions)
        applyFolds()
    }

    // MARK: - Applying folds

    // Push the current fold set into the layout manager and the gutter.
    func applyFolds() {
        ruler.foldableLines = Set(foldRegions.map { $0.startLine })
        ruler.foldedLines = foldedStarts
        ruler.needsDisplay = true

        guard let layoutManager = foldingLayoutManager else { return }
        // The minimap deliberately keeps showing the whole file: it is an
        // overview of the *document*, and a folded block is a property of this
        // view of it. Collapsing the minimap too would make the one widget that
        // answers "how big is this file" lie.
        let hidden = CodeFolding.hiddenLines(foldedStarts: foldedStarts, regions: foldRegions)
        layoutManager.hiddenRanges = characterRanges(forLines: hidden)
    }

    // 1-based line numbers → the character ranges covering them, merged so the
    // layout manager sees a handful of ranges rather than one per line.
    private func characterRanges(forLines lines: IndexSet) -> [NSRange] {
        guard !lines.isEmpty else { return [] }
        let length = (textView.string as NSString).length
        var ranges: [NSRange] = []
        for range in lines.rangeView {
            let firstLine = range.lowerBound
            let lastLine = range.upperBound - 1
            guard lineStarts.indices.contains(firstLine - 1) else { continue }
            let start = lineStarts[firstLine - 1]
            let end = lineStarts.indices.contains(lastLine) ? lineStarts[lastLine] : length
            guard start < end, end <= length else { continue }
            ranges.append(NSRange(location: start, length: end - start))
        }
        return ranges
    }

    // MARK: - Toggling

    // The gutter chevron, and the entry point everything else funnels through.
    func toggleFold(atLine line: Int) {
        guard CodeFolding.region(startingAt: line, in: foldRegions) != nil else { NSSound.beep(); return }
        if foldedStarts.contains(line) {
            foldedStarts.remove(line)
        } else {
            foldedStarts.insert(line)
        }
        applyFolds()
        keepCaretVisible()
    }

    // ⌥⌘[ — fold the innermost block containing the caret, so it works from
    // anywhere inside a function rather than only on its header line.
    func foldAtCaret() {
        let line = currentLineNumber()
        guard let region = CodeFolding.innermostRegion(containing: line, in: foldRegions) else {
            NSSound.beep()
            return
        }
        // Already folded at this level — step out and fold the parent, so
        // repeated presses collapse outward the way every editor does.
        if foldedStarts.contains(region.startLine),
           let parent = CodeFolding.innermostRegion(containing: region.startLine - 1, in: foldRegions),
           !foldedStarts.contains(parent.startLine) {
            foldedStarts.insert(parent.startLine)
        } else {
            foldedStarts.insert(region.startLine)
        }
        applyFolds()
        keepCaretVisible()
    }

    // ⌥⌘] — unfold the block the caret is in (or on).
    func unfoldAtCaret() {
        let line = currentLineNumber()
        // Prefer a fold starting on this very line (the caret sits on a folded
        // header) before looking outward.
        if foldedStarts.contains(line) {
            foldedStarts.remove(line)
        } else if let region = CodeFolding.innermostRegion(containing: line, in: foldRegions),
                  foldedStarts.contains(region.startLine) {
            foldedStarts.remove(region.startLine)
        } else {
            NSSound.beep()
            return
        }
        applyFolds()
    }

    // ⌥⌘0 / ⇧⌥⌘0 — everything at once.
    func foldAll() {
        foldedStarts = Set(foldRegions.map { $0.startLine })
        applyFolds()
        keepCaretVisible()
    }

    func unfoldAll() {
        guard !foldedStarts.isEmpty else { return }
        foldedStarts = []
        applyFolds()
    }

    // Fold everything at one nesting level — "collapse to the top-level
    // declarations" is the useful case, and it's level 0.
    func foldToLevel(_ level: Int) {
        foldedStarts = Set(CodeFolding.regions(atLevel: level, in: foldRegions).map { $0.startLine })
        applyFolds()
        keepCaretVisible()
    }

    // MARK: - Invariants

    // A caret inside newly-hidden text has nowhere to draw and typing there would
    // edit invisible characters — move it up to the fold's header line, which is
    // the line the user is looking at.
    private func keepCaretVisible() {
        let line = currentLineNumber()
        let hidden = CodeFolding.hiddenLines(foldedStarts: foldedStarts, regions: foldRegions)
        guard hidden.contains(line) else { return }

        // The enclosing folded region's header.
        let header = foldedStarts
            .filter { start in
                guard let region = CodeFolding.region(startingAt: start, in: foldRegions) else { return false }
                return region.startLine < line && line <= region.endLine
            }
            .min() ?? line

        guard lineStarts.indices.contains(header - 1) else { return }
        let target = NSRange(location: lineStarts[header - 1], length: 0)
        textView.setSelectedRange(target)
        textView.scrollRangeToVisible(target)
    }

    // Expand whatever hides `line`, so a jump (go-to-definition, a bookmark, a
    // search hit) can never land on a line the reader can't see. Returns true
    // when something was actually unfolded.
    @discardableResult
    func revealLine(_ line: Int) -> Bool {
        let hidden = CodeFolding.hiddenLines(foldedStarts: foldedStarts, regions: foldRegions)
        guard hidden.contains(line) else { return false }
        let hiding = foldedStarts.filter { start in
            guard let region = CodeFolding.region(startingAt: start, in: foldRegions) else { return false }
            return region.startLine < line && line <= region.endLine
        }
        guard !hiding.isEmpty else { return false }
        foldedStarts.subtract(hiding)
        applyFolds()
        return true
    }

    // The 1-based line the caret is on.
    func currentLineNumber() -> Int {
        EditorOps.lineIndex(forOffset: textView.selectedRange().location, lineStarts: lineStarts) + 1
    }
}
