import Cocoa

// The strip above the viewer's text showing where the caret is:
// `File.swift › TabStore › activate()`. Each crumb is clickable and jumps to
// that symbol's declaration, which makes it a one-click "go to the top of the
// thing I'm inside" — the reason breadcrumbs earn their vertical space.
//
// Drawn rather than built from NSButtons: there are at most a handful of crumbs,
// they change on every caret move, and re-laying out a stack of controls at that
// rate costs more than the whole strip is worth.
final class BreadcrumbBarView: NSView {
    static let height: CGFloat = 22

    // A crumb's line, or nil for the file-name crumb (which jumps to line 1).
    var onSelect: ((Int) -> Void)?

    private var fileName = ""
    private var entries: [OutlineEntry] = []
    // Hit rects in view coordinates, rebuilt each draw so clicking always tests
    // against exactly what is on screen.
    private var crumbRects: [(rect: NSRect, line: Int)] = []
    private var hoveredIndex: Int?

    override var isFlipped: Bool { true }

    func setTrail(fileName: String, entries: [OutlineEntry]) {
        guard fileName != self.fileName || entries != self.entries else { return }
        self.fileName = fileName
        self.entries = entries
        needsDisplay = true
    }

    private var font: NSFont { NSFont.systemFont(ofSize: 11) }
    private var separator: NSAttributedString {
        NSAttributedString(string: "  ›  ", attributes: [.font: font, .foregroundColor: Theme.textFaint])
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.bg.setFill()
        bounds.fill()
        Theme.hairline.setFill()
        NSRect(x: 0, y: bounds.height - 0.5, width: bounds.width, height: 0.5).fill()

        crumbRects = []
        var x: CGFloat = 10

        func drawCrumb(_ text: String, line: Int, dim: Bool, index: Int) {
            let hovered = hoveredIndex == index
            let color = dim && !hovered ? Theme.textFaint : Theme.textPrimary
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            let size = string.size()
            let y = (bounds.height - size.height) / 2
            // Stop drawing rather than overflow into the minimap.
            guard x + size.width < bounds.width - 10 else { return }
            string.draw(at: NSPoint(x: x, y: y))
            crumbRects.append((NSRect(x: x, y: 0, width: size.width, height: bounds.height), line))
            if hovered {
                color.withAlphaComponent(0.5).setFill()
                NSRect(x: x, y: y + size.height - 1, width: size.width, height: 1).fill()
            }
            x += size.width
        }

        drawCrumb(fileName, line: 1, dim: true, index: 0)
        for (i, entry) in entries.enumerated() {
            let sep = separator
            guard x + sep.size().width < bounds.width - 10 else { break }
            sep.draw(at: NSPoint(x: x, y: (bounds.height - sep.size().height) / 2))
            x += sep.size().width
            // The last crumb is where the caret is — full strength, the rest dim.
            drawCrumb("\(entry.symbol) \(entry.name)", line: entry.line,
                      dim: i < entries.count - 1, index: i + 1)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = crumbRects.first(where: { $0.rect.contains(point) }) else { return }
        onSelect?(hit.line)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = crumbRects.firstIndex { $0.rect.contains(point) }
        guard index != hoveredIndex else { return }
        hoveredIndex = index
        if index != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredIndex != nil else { return }
        hoveredIndex = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    // The theme changed under us (Settings ▸ Appearance).
    func reapplyTheme() {
        needsDisplay = true
    }
}
