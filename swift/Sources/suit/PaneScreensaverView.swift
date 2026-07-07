import Cocoa

enum PaneScreensaverKind: String {
    case waves = "Waves"
    case stars = "Stars"
    case matrix = "Matrix"
}

// A calm, endless ASCII animation drawn over a pane's terminal content — waves,
// blinking stars, or Matrix-style digital rain — toggled from the pane's
// right-click menu. Purely decorative: the shell underneath keeps running
// untouched, and toggling back to "None" just removes this overlay and reveals
// it again.
final class PaneScreensaverView: NSView {
    var kind: PaneScreensaverKind = .waves {
        didSet { rebuildFieldState() }
    }

    var fontColor = NSColor.white {
        didSet { needsDisplay = true }
    }

    var backgroundColor = NSColor.black {
        didSet { applyBackgroundColor() }
    }

    var backgroundAlpha: CGFloat = 1 {
        didSet { applyBackgroundColor() }
    }

    var fontSize: CGFloat = 13 {
        didSet {
            font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            cellSize = Self.measureCell(font: font)
            rebuildFieldState()
        }
    }

    // Multiplies how much `time` advances per tick, so wave motion and star
    // twinkle speed up/slow down without changing the timer's frame rate.
    var speed: CGFloat = 1

    private var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var cellSize: NSSize
    private var time: CGFloat = 0
    private var timer: Timer?

    private var starPhases: [[CGFloat]] = []
    private var lastGridSize: (cols: Int, rows: Int) = (0, 0)

    // One falling drop per column: where it started, how fast it falls (rows per
    // tick, scaled by `speed` via `time`), and how long its fading tail is.
    private struct MatrixDrop {
        var phase: CGFloat
        var fallSpeed: CGFloat
        var trail: Int
    }
    private var matrixDrops: [MatrixDrop] = []

    private static let waveRamp: [Character] = Array(" .:-=+*#%@")
    private static let starChars: [Character] = [" ", " ", " ", ".", "*", "+", "#"]
    private static let matrixChars: [Character] =
        Array("abcdefghijklmnopqrstuvwxyz0123456789$+*=%#@&<>?!")

    override init(frame frameRect: NSRect) {
        cellSize = Self.measureCell(font: font)
        super.init(frame: frameRect)
        wantsLayer = true
        applyBackgroundColor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        timer?.invalidate()
    }

    private func applyBackgroundColor() {
        layer?.backgroundColor = backgroundColor.withAlphaComponent(backgroundAlpha).cgColor
        needsDisplay = true
    }

    private static func measureCell(font: NSFont) -> NSSize {
        let width = ("M" as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: width, height: font.ascender - font.descender + font.leading)
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.time += self.speed
            self.needsDisplay = true
        }
    }

    // Must be called before this view is discarded — a repeating Timer is kept
    // alive by the run loop itself, not by anything holding a reference to this
    // view, so it never stops (and never lets this view deallocate) on its own.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func gridSize() -> (cols: Int, rows: Int) {
        guard cellSize.width > 0, cellSize.height > 0 else { return (0, 0) }
        return (max(1, Int(bounds.width / cellSize.width)), max(1, Int(bounds.height / cellSize.height)))
    }

    // Regenerates whatever per-cell/per-column randomness the current kind
    // needs; waves are purely a function of (position, time) and need none.
    private func rebuildFieldState() {
        switch kind {
        case .waves: break
        case .stars: rebuildStarField()
        case .matrix: rebuildMatrixDrops()
        }
    }

    private func rebuildStarField() {
        let (cols, rows) = gridSize()
        lastGridSize = (cols, rows)
        guard cols > 0, rows > 0 else { return }
        starPhases = (0..<rows).map { _ in (0..<cols).map { _ in CGFloat.random(in: 0..<(2 * .pi)) } }
        needsDisplay = true
    }

    private func rebuildMatrixDrops() {
        let (cols, rows) = gridSize()
        lastGridSize = (cols, rows)
        guard cols > 0, rows > 0 else { return }
        matrixDrops = (0..<cols).map { _ in
            MatrixDrop(phase: CGFloat.random(in: 0..<500),
                       fallSpeed: CGFloat.random(in: 0.3...1.2),
                       trail: Int.random(in: 5...max(6, min(22, rows))))
        }
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if kind != .waves { rebuildFieldState() }
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.withAlphaComponent(backgroundAlpha).setFill()
        dirtyRect.fill()

        let (cols, rows) = gridSize()
        guard cols > 0, rows > 0 else { return }

        switch kind {
        case .waves:
            drawWaves(cols: cols, rows: rows)
        case .stars:
            if lastGridSize.cols != cols || lastGridSize.rows != rows { rebuildStarField() }
            drawStars(cols: cols, rows: rows)
        case .matrix:
            if lastGridSize.cols != cols || lastGridSize.rows != rows { rebuildMatrixDrops() }
            drawMatrix(cols: cols, rows: rows)
        }
    }

    private func drawWaves(cols: Int, rows: Int) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fontColor,
        ]

        var lines: [String] = []
        lines.reserveCapacity(rows)
        for row in 0..<rows {
            var line = ""
            line.reserveCapacity(cols)
            let rowPhase = CGFloat(row) * 0.5
            for col in 0..<cols {
                let x = CGFloat(col) * 0.25
                let value = sin(x + rowPhase + time * 0.15) * 0.5 + sin(x * 0.5 - time * 0.08 + rowPhase) * 0.3
                let normalized = min(1, max(0, (value + 0.8) / 1.6))
                line.append(Self.waveRamp[Int(normalized * CGFloat(Self.waveRamp.count - 1))])
            }
            lines.append(line)
        }
        draw(lines: lines, attrs: attrs)
    }

    private func drawStars(cols: Int, rows: Int) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fontColor,
        ]

        var lines: [String] = []
        lines.reserveCapacity(rows)
        for row in 0..<rows where row < starPhases.count {
            var line = ""
            line.reserveCapacity(cols)
            for col in 0..<cols where col < starPhases[row].count {
                let twinkle = sin(time * 0.1 + starPhases[row][col])
                let index = Int((twinkle * 0.5 + 0.5) * CGFloat(Self.starChars.count - 1))
                line.append(Self.starChars[index])
            }
            lines.append(line)
        }
        draw(lines: lines, attrs: attrs)
    }

    // Matrix-style digital rain: one drop per column falling top→bottom, a
    // bright head glyph and a tail fading out behind it. Cell glyphs are picked
    // by a deterministic hash of (col, row, time bucket) so they flicker as the
    // rain passes without any per-cell mutation state.
    private func drawMatrix(cols: Int, rows: Int) {
        let headColor = fontColor.blended(withFraction: 0.7, of: .white) ?? fontColor
        let baseAttrs: [NSAttributedString.Key: Any] = [.font: font]

        var y = bounds.height - cellSize.height
        for row in 0..<rows {
            var chars = [Character](repeating: " ", count: cols)
            var colors: [(column: Int, color: NSColor)] = []
            for col in 0..<cols where col < matrixDrops.count {
                let drop = matrixDrops[col]
                // The head wraps over a cycle longer than the pane so each drop
                // leaves a gap before re-entering at the top; distances are
                // computed modulo the cycle so the tail keeps fading out at the
                // bottom while the head has already restarted above.
                let cycle = CGFloat(rows + drop.trail + 8)
                let head = (drop.phase + time * drop.fallSpeed).truncatingRemainder(dividingBy: cycle)
                var distance = head - CGFloat(row)
                if distance < 0 { distance += cycle }
                guard distance < CGFloat(drop.trail) else { continue }
                chars[col] = matrixGlyph(col: col, row: row)
                let fade = max(0.15, 1 - distance / CGFloat(drop.trail))
                colors.append((col, distance < 1 ? headColor : fontColor.withAlphaComponent(fade)))
            }
            let line = NSMutableAttributedString(string: String(chars), attributes: baseAttrs)
            for (column, color) in colors {
                line.addAttribute(.foregroundColor, value: color, range: NSRange(location: column, length: 1))
            }
            line.draw(at: NSPoint(x: 0, y: y))
            y -= cellSize.height
            if y < -cellSize.height { break }
        }
    }

    private func matrixGlyph(col: Int, row: Int) -> Character {
        // The row/col-dependent offset staggers when each cell crosses a time
        // bucket, so glyphs mutate at different moments instead of all at once.
        let bucket = Int(time * 0.3 + CGFloat((col * 7 + row * 13) % 11))
        var hash = UInt32(truncatingIfNeeded: col &* 73_856_093 ^ row &* 19_349_663 ^ bucket &* 83_492_791)
        hash ^= hash >> 13
        hash = hash &* 0x5bd1_e995
        hash ^= hash >> 15
        return Self.matrixChars[Int(hash % UInt32(Self.matrixChars.count))]
    }

    private func draw(lines: [String], attrs: [NSAttributedString.Key: Any]) {
        var y = bounds.height - cellSize.height
        for line in lines {
            NSAttributedString(string: line, attributes: attrs).draw(at: NSPoint(x: 0, y: y))
            y -= cellSize.height
            if y < -cellSize.height { break }
        }
    }
}
