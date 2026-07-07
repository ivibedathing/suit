import Cocoa

// The viewer's minimap (ROADMAP Phase 3): the whole document as ~2px-tall
// run-length line blocks, a draggable viewport rectangle, and overlay markers
// (jump targets now; search hits and git-modified regions as their phases
// land). It's the "where is stuff in this file" instrument, not decoration.
final class MinimapView: NSView {
    static let preferredWidth: CGFloat = 72

    // A colored horizontal run on one line, in fractional x (0–1 across the
    // minimap's usable width).
    private struct LineRun {
        let line: Int
        let startFraction: CGFloat
        let endFraction: CGFloat
        let color: NSColor
    }

    struct Marker {
        let line: Int
        let color: NSColor
    }

    // Scroll the document so `fraction` (0–1 through the file) is centered.
    var onJump: ((CGFloat) -> Void)?

    private var runs: [LineRun] = []
    private var lineCount = 1
    private var rendered: NSImage?
    private(set) var markers: [Marker] = []

    // The visible portion of the document, as fractions of its total height.
    private var viewportStart: CGFloat = 0
    private var viewportEnd: CGFloat = 0

    var backgroundColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    // MARK: - Content

    // Rebuilds the line runs from the document text and its syntax spans.
    // Unstyled text renders as dim gray runs; styled spans in their token
    // color. Costs one pass over the text; called on load, off the main path
    // being scrolled.
    func rebuild(text: String, lineStarts: [Int], spans: [SyntaxSpan], baseColor: NSColor) {
        let ns = text as NSString
        lineCount = max(1, lineStarts.count)
        let maxColumns: CGFloat = 120
        var newRuns: [LineRun] = []
        newRuns.reserveCapacity(lineStarts.count * 2)

        // Sort spans once; walk them in step with the lines.
        let sorted = spans.sorted { $0.range.location < $1.range.location }
        var spanIndex = 0
        let dim = baseColor.withAlphaComponent(0.45)

        for (lineIndex, start) in lineStarts.enumerated() {
            let end = lineIndex + 1 < lineStarts.count ? lineStarts[lineIndex + 1] - 1 : ns.length
            guard end > start else { continue }
            let lineLength = min(end - start, Int(maxColumns))

            // Leading indentation is skipped so the minimap shows code shape.
            var contentStart = start
            while contentStart < end, ns.character(at: contentStart) == 32 || ns.character(at: contentStart) == 9 {
                contentStart += 1
            }
            guard contentStart < end else { continue }

            let startColumn = min(contentStart - start, Int(maxColumns))
            newRuns.append(LineRun(
                line: lineIndex,
                startFraction: CGFloat(startColumn) / maxColumns,
                endFraction: CGFloat(lineLength) / maxColumns,
                color: dim
            ))

            // Colored runs for the spans that intersect this line.
            while spanIndex < sorted.count, NSMaxRange(sorted[spanIndex].range) <= start {
                spanIndex += 1
            }
            var probe = spanIndex
            while probe < sorted.count, sorted[probe].range.location < end {
                let span = sorted[probe]
                let overlapStart = max(span.range.location, start) - start
                let overlapEnd = min(NSMaxRange(span.range), end) - start
                if overlapEnd > overlapStart, overlapStart < Int(maxColumns) {
                    newRuns.append(LineRun(
                        line: lineIndex,
                        startFraction: CGFloat(overlapStart) / maxColumns,
                        endFraction: CGFloat(min(overlapEnd, Int(maxColumns))) / maxColumns,
                        color: span.kind.color.withAlphaComponent(0.9)
                    ))
                }
                probe += 1
            }
        }

        runs = newRuns
        rendered = nil
        needsDisplay = true
    }

    func setMarkers(_ markers: [Marker]) {
        self.markers = markers
        needsDisplay = true
    }

    // Where the viewport rect sits, as fractions of the document height.
    func setViewport(start: CGFloat, end: CGFloat) {
        viewportStart = max(0, min(1, start))
        viewportEnd = max(viewportStart, min(1, end))
        needsDisplay = true
    }

    // MARK: - Geometry

    // 2px per line while the file fits; compressed to fit otherwise.
    private var lineHeight: CGFloat {
        guard bounds.height > 0 else { return 2 }
        return min(2, bounds.height / CGFloat(lineCount))
    }

    private var contentHeight: CGFloat {
        lineHeight * CGFloat(lineCount)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rendered = nil
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        bounds.fill()

        if rendered == nil {
            rendered = renderDocumentImage()
        }
        rendered?.draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: contentHeight),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)

        // Markers: full-width ticks that stay visible at any compression.
        for marker in markers {
            marker.color.withAlphaComponent(0.85).setFill()
            let y = CGFloat(marker.line - 1) * lineHeight
            NSRect(x: 0, y: y, width: bounds.width, height: max(2, lineHeight)).fill()
        }

        // Viewport.
        let viewportRect = NSRect(
            x: 0,
            y: viewportStart * contentHeight,
            width: bounds.width,
            height: max(8, (viewportEnd - viewportStart) * contentHeight)
        )
        // Restated from Theme (Phase 15): the viewport is a quiet primary-text
        // tint, not a raw white — it has to sit on the committed dark ground.
        Theme.textPrimary.withAlphaComponent(0.07).setFill()
        viewportRect.fill()
        Theme.textPrimary.withAlphaComponent(0.22).setStroke()
        let outline = NSBezierPath(rect: viewportRect.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
    }

    private func renderDocumentImage() -> NSImage? {
        let size = NSSize(width: bounds.width, height: max(1, contentHeight))
        guard size.width > 0 else { return nil }
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        let lineHeight = self.lineHeight
        let blockHeight = max(1, lineHeight - (lineHeight >= 2 ? 0.7 : 0))
        let usableWidth = size.width - 4
        for run in runs {
            run.color.setFill()
            let x = 2 + run.startFraction * usableWidth
            let width = max(1, (run.endFraction - run.startFraction) * usableWidth)
            NSRect(x: x, y: CGFloat(run.line) * lineHeight, width: width, height: blockHeight).fill()
        }
        image.unlockFocus()
        return image
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        jump(to: event)
    }

    override func mouseDragged(with event: NSEvent) {
        jump(to: event)
    }

    private func jump(to event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard contentHeight > 0 else { return }
        onJump?(max(0, min(1, point.y / contentHeight)))
    }
}
