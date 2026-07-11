import Cocoa

// Image preview tab: PNG/JPG/GIF/SVG open here instead of
// bouncing out to Preview.app. An image drawn over a checkerboard backing (so
// transparency reads), a zoom-to-fit / actual-size toggle, and the pixel
// dimensions in a slim header. Read-only — no scope creep toward an editor.

// Draws the checkerboard backing and the image on top, flipped so it tops-out
// like every other scroll document in the app. The view's frame is the image's
// draw rect: fit-to-window sizes it to the visible area, actual-size to the
// image's pixel size (the scroll view then pans).
final class ImageCanvasView: NSView {
    var image: NSImage?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Two-tone checkerboard, the Preview.app convention for transparency.
        let tile: CGFloat = 9
        NSColor(white: 0.32, alpha: 1).setFill()
        bounds.fill()
        NSColor(white: 0.24, alpha: 1).setFill()
        var y = (bounds.minY / tile).rounded(.down) * tile
        while y < bounds.maxY {
            let rowEven = (Int((y / tile).rounded()) % 2) == 0
            var x = (bounds.minX / tile).rounded(.down) * tile + (rowEven ? 0 : tile)
            while x < bounds.maxX {
                NSRect(x: x, y: y, width: tile, height: tile).intersection(dirtyRect).fill()
                x += 2 * tile
            }
            y += tile
        }
        image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil)
    }
}

final class ImagePaneContent: NSObject, FileBackedPaneContent {
    weak var pane: Pane?
    weak var tab: Tab?

    private let containerView = NSView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let canvas = ImageCanvasView(frame: .zero)
    private let dimsLabel = NSTextField(labelWithString: "")
    private let zoomButton = NSButton(title: "Actual Size", target: nil, action: nil)

    private static let headerHeight: CGFloat = 28

    private(set) var filePath: String?
    private var image: NSImage?
    private var pixelSize: NSSize = .zero
    private var actualSize = false
    private var background = Theme.bg

    var view: NSView { containerView }
    var focusTarget: NSView { scrollView }
    var defaultTitle: String { "Image" }
    var workingDirectory: String? {
        filePath.map { ($0 as NSString).deletingLastPathComponent }
    }
    var initialBackgroundColor: NSColor { background }

    override init() {
        super.init()

        // Ground the dimensions/zoom header strip in the chrome color.
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = Theme.bg.cgColor

        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.terminalBg
        scrollView.borderType = .noBorder
        containerView.addSubview(scrollView)

        dimsLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        dimsLabel.textColor = Theme.textDim
        dimsLabel.lineBreakMode = .byTruncatingTail
        containerView.addSubview(dimsLabel)

        zoomButton.controlSize = .small
        zoomButton.bezelStyle = .texturedRounded
        zoomButton.target = self
        zoomButton.action = #selector(toggleZoom)
        containerView.addSubview(zoomButton)

        containerView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(layoutContents),
            name: NSView.frameDidChangeNotification, object: containerView
        )
        // Fit-to-window recomputes the canvas size as the pane resizes.
        scrollView.contentView.postsBoundsChangedNotifications = true
    }

    func load(path: String, line: Int?) {
        let standardized = (path as NSString).standardizingPath
        filePath = standardized
        image = NSImage(contentsOfFile: standardized)
        canvas.image = image
        pixelSize = image.map(Self.pixelDimensions) ?? .zero

        if pixelSize.width > 0 {
            dimsLabel.stringValue = "\(Int(pixelSize.width)) × \(Int(pixelSize.height)) px"
        } else {
            dimsLabel.stringValue = "Could not read image"
        }
        updateZoomButton()
        relayoutCanvas()
        tab?.contentTitleDidChange((standardized as NSString).lastPathComponent)
    }

    // The largest bitmap rep's pixel count is the true resolution; vector/PDF
    // reps (SVG) report point size, which is the best we can do for them.
    private static func pixelDimensions(_ image: NSImage) -> NSSize {
        var best = NSSize.zero
        for rep in image.representations {
            let size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            if size.width * size.height > best.width * best.height { best = size }
        }
        if best.width <= 0 { best = image.size }
        return best
    }

    @objc private func toggleZoom(_ sender: Any?) {
        actualSize.toggle()
        updateZoomButton()
        relayoutCanvas()
    }

    private func updateZoomButton() {
        zoomButton.title = actualSize ? "Zoom to Fit" : "Actual Size"
        zoomButton.isEnabled = image != nil && pixelSize.width > 0
    }

    // Fit-to-window: the canvas fills the visible area (aspect kept by drawing
    // the image proportionally). Actual-size: the canvas is the image's pixel
    // size and the scroll view pans.
    private func relayoutCanvas() {
        let visible = scrollView.contentSize
        if actualSize, pixelSize.width > 0 {
            canvas.frame = NSRect(origin: .zero, size: pixelSize)
        } else if pixelSize.width > 0 {
            let scale = min(visible.width / pixelSize.width, visible.height / pixelSize.height, 1)
            let w = pixelSize.width * scale
            let h = pixelSize.height * scale
            canvas.frame = NSRect(
                x: max(0, (visible.width - w) / 2), y: max(0, (visible.height - h) / 2),
                width: max(1, w), height: max(1, h)
            )
        } else {
            canvas.frame = NSRect(origin: .zero, size: visible)
        }
        canvas.needsDisplay = true
    }

    @objc private func layoutContents() {
        let bounds = containerView.bounds
        let contentHeight = max(0, bounds.height - Self.headerHeight)

        dimsLabel.sizeToFit()
        dimsLabel.frame = NSRect(x: 8, y: contentHeight + (Self.headerHeight - 14) / 2,
                                 width: max(0, bounds.width - 120), height: 14)
        zoomButton.sizeToFit()
        zoomButton.frame.origin = NSPoint(
            x: bounds.width - zoomButton.frame.width - 8,
            y: contentHeight + (Self.headerHeight - zoomButton.frame.height) / 2
        )
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: contentHeight)
        if !actualSize { relayoutCanvas() }
    }

    // MARK: - State restoration

    var isActualSize: Bool { actualSize }

    func restoreZoom(actualSize: Bool) {
        self.actualSize = actualSize
        updateZoomButton()
        relayoutCanvas()
    }

    // MARK: - Appearance

    func applyBackground(_ color: NSColor) {
        background = color
        // The image sits on its own checkerboard; only the letterbox area
        // around it takes the pane background.
        scrollView.backgroundColor = color
    }

    // Live theme switch: re-ground the container layer and re-tint the
    // dimensions label (baked-once colors); the letterbox scroll background is
    // re-pushed separately via applyBackground.
    func reapplyTheme() {
        containerView.layer?.backgroundColor = Theme.bg.cgColor
        dimsLabel.textColor = Theme.textDim
    }

    func teardown() {
        NotificationCenter.default.removeObserver(self)
    }
}
