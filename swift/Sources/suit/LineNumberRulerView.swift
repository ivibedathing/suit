import Cocoa

// The line-number gutter: draws the number of each visible line fragment's
// first fragment, in the same font family as the document at a smaller size.
final class LineNumberRulerView: NSRulerView, NSViewToolTipOwner {
    weak var textView: NSTextView?
    var textColor: NSColor = Theme.textFaint
    var gutterBackground: NSColor = .clear

    // Character offsets of each line start, maintained by the viewer on load —
    // cheaper than re-walking the string on every draw.
    var lineStarts: [Int] = [0]

    // Live theme switch: re-set the gutter text color baked in at init; the
    // inline hairline / change-bar / blame fills in draw() re-read live.
    func reapplyTheme() {
        textColor = Theme.textFaint
        needsDisplay = true
    }

    // Lines changed vs HEAD, drawn as an orange bar along
    // the gutter's right edge.
    var changedLines = IndexSet() {
        didSet { needsDisplay = true }
    }

    // Blame gutter: a toggleable column left of the line
    // numbers showing each line's last-touching commit (sha + author, tinted by
    // age), the full subject on hover, and the sha clickable to that commit's
    // diff. Reuses the ruler's line-fragment walk — the same plumbing as the
    // changed-line marks above.
    var blameVisible = false {
        didSet {
            guard blameVisible != oldValue else { return }
            updateThickness()
            needsDisplay = true
        }
    }
    var blameByLine: [Int: BlameLine] = [:] {
        didSet { if blameVisible { needsDisplay = true } }
    }
    // A commit's short sha (from a clicked blame line) → open its diff.
    var onBlameClick: ((BlameLine) -> Void)?

    private static let blameWidth: CGFloat = 172

    // Bookmarked lines in this file, drawn as an accent bar
    // along the gutter's *left* edge (the right edge is the changed-line bar).
    var bookmarkedLines = IndexSet() {
        didSet { needsDisplay = true }
    }

    // A gutter click toggles the bookmark on the clicked line.
    var onToggleLine: ((Int) -> Void)?

    // Code folding: which lines open a foldable region, which of
    // those are currently folded, and the click that toggles one. The chevrons
    // live in a narrow column between the numbers and the text, where every
    // editor puts them — and where they can't be confused with the bookmark bar
    // on the gutter's left edge.
    var foldableLines: Set<Int> = [] {
        didSet { if foldableLines != oldValue { updateThickness(); needsDisplay = true } }
    }
    var foldedLines: Set<Int> = [] {
        didSet { if foldedLines != oldValue { needsDisplay = true } }
    }
    var onToggleFold: ((Int) -> Void)?

    // The line whose chevron the pointer is over, or nil. Chevrons for unfolded
    // regions only paint on hover (VS Code's rule) so a dense file doesn't read
    // as a column of arrows; a *folded* one always paints, because it's the only
    // sign that lines are missing.
    private var hoveredFoldLine: Int?

    private static let foldColumnWidth: CGFloat = 14
    private var foldColumnOrigin: CGFloat { ruleThickness - Self.foldColumnWidth }

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        updateThickness()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var blameColumnWidth: CGFloat { blameVisible ? Self.blameWidth : 0 }

    func updateThickness() {
        let digits = max(3, String(lineStarts.count).count)
        let charWidth = ("0" as NSString).size(withAttributes: [.font: numberFont]).width
        // The fold column is reserved as soon as the file has anything foldable
        // in it, not per visible line — a gutter that changes width as you
        // scroll would reflow wrapped text under the pointer.
        let foldWidth = foldableLines.isEmpty ? 0 : Self.foldColumnWidth
        ruleThickness = blameColumnWidth + CGFloat(digits) * charWidth + 12 + foldWidth
    }

    private var numberFont: NSFont {
        let base = textView?.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        return NSFont.monospacedDigitSystemFont(ofSize: max(8, base.pointSize - 2), weight: .regular)
    }

    private var blameFont: NSFont {
        let base = textView?.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        return NSFont.monospacedSystemFont(ofSize: max(8, base.pointSize - 3), weight: .regular)
    }

    // The document line under a window-space point, mapped through the text
    // view so it stays correct regardless of the ruler's own flippedness.
    private func line(atWindowPoint windowPoint: NSPoint) -> Int? {
        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer, lineStarts.count > 1 else { return nil }
        let pointInText = textView.convert(windowPoint, from: nil)
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 2, y: pointInText.y), in: container)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyph)
        return lineNumber(forCharacterAt: charIndex)
    }

    // Hover tracking exists only to show fold chevrons; without a fold column
    // there is nothing to track, so the area is torn down with it.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard !foldableLines.isEmpty else { return }
        addTrackingArea(NSTrackingArea(
            rect: NSRect(x: foldColumnOrigin, y: 0, width: Self.foldColumnWidth, height: bounds.height),
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let line = self.line(atWindowPoint: event.locationInWindow)
        let hovered = line.flatMap { foldableLines.contains($0) ? $0 : nil }
        if hovered != hoveredFoldLine {
            hoveredFoldLine = hovered
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredFoldLine != nil else { return }
        hoveredFoldLine = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        // The fold column takes priority over the bookmark toggle: it is the
        // narrower target and the one the chevron under the pointer promises.
        if !foldableLines.isEmpty, location.x >= foldColumnOrigin,
           let line = line(atWindowPoint: event.locationInWindow),
           foldableLines.contains(line) {
            onToggleFold?(line)
            return
        }
        // A click in the blame column on a committed line opens that commit's
        // diff.
        if blameVisible, location.x <= blameColumnWidth,
           let line = line(atWindowPoint: event.locationInWindow),
           let blame = blameByLine[line], !blame.isUncommitted {
            onBlameClick?(blame)
            return
        }
        // Otherwise a gutter click toggles the bookmark on that line
        //.
        if let line = line(atWindowPoint: event.locationInWindow) {
            onToggleLine?(line)
            return
        }
        super.mouseDown(with: event)
    }

    // The blame column carries the commit subject as a tooltip (registered over
    // the whole column each draw so it tracks resize/scroll).
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let windowPoint = convert(point, to: nil)
        guard let line = line(atWindowPoint: windowPoint), let blame = blameByLine[line] else { return "" }
        if blame.isUncommitted { return "Uncommitted changes" }
        return "\(blame.shortSha)  \(blame.author)\n\(blame.summary)"
    }

    // The line number owning a character offset: the index of the last line
    // start ≤ offset (binary search — files can be hundreds of thousands of lines).
    private func lineNumber(forCharacterAt offset: Int) -> Int {
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
        return low + 1
    }

    // Where line numbers end: short of the fold column when there is one.
    private var numbersRightEdge: CGFloat {
        (foldableLines.isEmpty ? ruleThickness : foldColumnOrigin) - 6
    }

    // A disclosure chevron — down for an open region, right for a folded one —
    // stroked rather than drawn as text so it stays crisp at any font size and
    // needs no glyph fallback.
    private func drawChevron(in rect: NSRect, pointingRight: Bool, color: NSColor) {
        let size: CGFloat = 4
        let centerX = rect.minX + 5
        let centerY = rect.midY
        let path = NSBezierPath()
        if pointingRight {
            path.move(to: NSPoint(x: centerX - size / 2, y: centerY - size))
            path.line(to: NSPoint(x: centerX + size / 2, y: centerY))
            path.line(to: NSPoint(x: centerX - size / 2, y: centerY + size))
        } else {
            path.move(to: NSPoint(x: centerX - size, y: centerY - size / 2))
            path.line(to: NSPoint(x: centerX, y: centerY + size / 2))
            path.line(to: NSPoint(x: centerX + size, y: centerY - size / 2))
        }
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        gutterBackground.setFill()
        bounds.fill()

        // Re-register the blame column's tooltip each draw so it tracks
        // resize/scroll; clearing on every draw also wipes residue once blame
        // is toggled back off.
        removeAllToolTips()
        if blameVisible {
            addToolTip(NSRect(x: 0, y: 0, width: blameColumnWidth, height: bounds.height), owner: self, userData: nil)
            Theme.hairline.setFill()
            NSRect(x: blameColumnWidth - 0.5, y: 0, width: 0.5, height: bounds.height).fill()
        }

        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: textColor]
        let now = Date().timeIntervalSince1970
        let blameFont = self.blameFont

        var lastLine = -1
        var glyphIndex = glyphRange.location
        while glyphIndex < NSMaxRange(glyphRange) {
            var fragmentGlyphRange = NSRange()
            let fragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &fragmentGlyphRange)
            let charIndex = layoutManager.characterIndexForGlyph(at: fragmentGlyphRange.location)
            let line = lineNumber(forCharacterAt: charIndex)
            // Wrapped continuations share the line number of their first fragment;
            // only the first gets a label.
            if line != lastLine {
                lastLine = line
                let label = "\(line)" as NSString
                let size = label.size(withAttributes: attributes)
                let y = fragmentRect.minY - visibleRect.minY + textView.textContainerInset.height + (fragmentRect.height - size.height) / 2
                label.draw(at: NSPoint(x: numbersRightEdge - size.width, y: y), withAttributes: attributes)

                // Fold chevron for a line that opens a region: always for a
                // folded one (it's the only evidence the block is there), on
                // hover otherwise.
                if foldableLines.contains(line) {
                    let folded = foldedLines.contains(line)
                    if folded || hoveredFoldLine == line {
                        let top = fragmentRect.minY - visibleRect.minY + textView.textContainerInset.height
                        drawChevron(
                            in: NSRect(x: foldColumnOrigin, y: top, width: Self.foldColumnWidth, height: fragmentRect.height),
                            pointingRight: folded,
                            color: folded ? Theme.accent : textColor
                        )
                    }
                }

                if blameVisible, let blame = blameByLine[line] {
                    let tint = GitAgeTint.color(forTime: blame.time, now: now)
                    let text = blame.isUncommitted
                        ? NSAttributedString(string: "Uncommitted", attributes: [.font: blameFont, .foregroundColor: tint])
                        : NSAttributedString(string: "\(blame.shortSha)  \(blame.author)", attributes: [.font: blameFont, .foregroundColor: tint])
                    let blameY = fragmentRect.minY - visibleRect.minY + textView.textContainerInset.height + (fragmentRect.height - text.size().height) / 2
                    NSGraphicsContext.current?.saveGraphicsState()
                    NSRect(x: 6, y: blameY, width: blameColumnWidth - 12, height: fragmentRect.height).clip()
                    text.draw(at: NSPoint(x: 6, y: blameY))
                    NSGraphicsContext.current?.restoreGraphicsState()
                }
            }
            if changedLines.contains(line) {
                Theme.sessionBusy.withAlphaComponent(0.75).setFill()
                let barY = fragmentRect.minY - visibleRect.minY + textView.textContainerInset.height
                NSRect(x: ruleThickness - 2.5, y: barY, width: 2.5, height: fragmentRect.height).fill()
            }
            if bookmarkedLines.contains(line) {
                Theme.accent.setFill()
                let barY = fragmentRect.minY - visibleRect.minY + textView.textContainerInset.height
                NSRect(x: 0, y: barY, width: 3, height: fragmentRect.height).fill()
            }
            glyphIndex = NSMaxRange(fragmentGlyphRange)
        }

        // Empty document / trailing empty line still shows "1" so the gutter
        // never looks broken on an empty file.
        if lastLine == -1 && lineStarts.count == 1 {
            let label = "1" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: textView.textContainerInset.height), withAttributes: attributes)
        }
    }

}
