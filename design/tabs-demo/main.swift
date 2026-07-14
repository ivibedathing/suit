import Cocoa
import UniformTypeIdentifiers

// Renders design/tabs-drag.gif — the README animation of the browser-tab
// model: tabs dragged out of a pane's tab bar (and a pane's title bar) with
// the live drop-zone preview, dropped on edges to split and on the center to
// show. Everything is the real app offscreen: real panes, the real
// drop-indicator overlay (driven via PaneContainerView.previewTabDrop), and
// real dropTab calls, so the GIF can't drift from actual behavior.
//
// Regenerate with design/render-tabs-gif.sh after tab/pane chrome changes.

_ = NSApplication.shared
NSApp.appearance = NSAppearance(named: .darkAqua)
let delegate = AppDelegate()

// MARK: - Fixture files

let fixture = NSTemporaryDirectory() + "suit-tabs-demo"
try? FileManager.default.createDirectory(atPath: fixture, withIntermediateDirectories: true)
let samplePath = fixture + "/Sample.swift"
try? """
import Cocoa

func hello() {
    print("hello")
}
""".write(toFile: samplePath, atomically: true, encoding: .utf8)
let notesPath = fixture + "/notes.md"
try? """
# Notes

- Tabs are the unit; panes are viewports.
- Drop a tab on a pane **edge** to split it out.
- Drop it on the **center** to show it there.
""".write(toFile: notesPath, atomically: true, encoding: .utf8)

func pump(_ s: TimeInterval) {
    let end = Date().addingTimeInterval(s)
    while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
}

// MARK: - Scenario setup (mirrors design/reference/main.swift)

delegate.newWindow(nil)
guard let c = NSApp.windows.compactMap({ $0.delegate as? TerminalWindowController }).first else {
    FileHandle.standardError.write(Data("no window controller\n".utf8))
    exit(1)
}
c.window.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 700), display: true)
pump(1.5)

c.openFile(atPath: samplePath, line: nil)
pump(0.3)
c.openFile(atPath: notesPath, line: nil)
pump(0.5)

// The live shell titles itself user@host — pin a neutral title so the
// committed GIF never carries the machine's real username.
for tab in c.store.tabs where tab.content is TerminalPaneContent {
    tab.customTitle = "user@mac:~"
    c.tabDidChange(tab)
}
pump(0.3)

guard let contentView = c.window.contentView else { exit(1) }
guard let terminalTab = c.store.tabs.first(where: { $0.content is TerminalPaneContent }),
      let sampleTab = c.store.tabs.first(where: { ($0.content as? FileBackedPaneContent)?.filePath == samplePath }),
      let notesTab = c.store.tabs.first(where: { ($0.content as? FileBackedPaneContent)?.filePath == notesPath }) else {
    FileHandle.standardError.write(Data("missing scenario tabs\n".utf8))
    exit(1)
}

// MARK: - Frame capture → GIF

let outputWidth = 880
var frames: [(image: CGImage, delay: Double)] = []

func captureFrame(delay: Double) {
    pump(0.03)
    contentView.layoutSubtreeIfNeeded()
    guard let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else { return }
    contentView.cacheDisplay(in: contentView.bounds, to: rep)
    guard let cg = rep.cgImage else { return }
    let outputHeight = Int((CGFloat(outputWidth) * contentView.bounds.height / contentView.bounds.width).rounded())
    guard let ctx = CGContext(
        data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
    if let scaled = ctx.makeImage() { frames.append((scaled, delay)) }
}

// MARK: - Drag ghost + cursor overlays

// The ghost is the exact image a live chip/title-bar drag renders, centered
// under the cursor the way AppKit places it.
let ghostView = NSImageView(frame: .zero)
ghostView.alphaValue = 0.9
ghostView.isHidden = true
contentView.addSubview(ghostView)

func makeCursorImage() -> NSImage {
    // The classic pointer, black with a white outline so it reads on the dark
    // chrome. Points are y-down and flipped when built.
    let pointsDown: [(CGFloat, CGFloat)] = [
        (0, 0), (0, 16.5), (3.5, 13), (6, 18), (8.5, 17), (6.2, 11.8), (11, 11.8),
    ]
    let height: CGFloat = 18.5
    let image = NSImage(size: NSSize(width: 12, height: height))
    image.lockFocus()
    let path = NSBezierPath()
    for (i, p) in pointsDown.enumerated() {
        let point = NSPoint(x: p.0 + 0.5, y: height - p.1 - 0.5)
        if i == 0 { path.move(to: point) } else { path.line(to: point) }
    }
    path.close()
    NSColor.black.setFill()
    path.fill()
    NSColor.white.setStroke()
    path.lineWidth = 1
    path.stroke()
    image.unlockFocus()
    return image
}

let cursorView = NSImageView(frame: .zero)
cursorView.image = makeCursorImage()
cursorView.isHidden = true
contentView.addSubview(cursorView)

// Every pane container currently in the window (tabs' viewports, deduped).
func paneContainers() -> [PaneContainerView] {
    var seen = [PaneContainerView]()
    for tab in c.store.tabs {
        guard let container = tab.pane?.container, !seen.contains(where: { $0 === container }) else { continue }
        seen.append(container)
    }
    return seen
}

// Moves the ghost + cursor to `point` (contentView coordinates) and lets the
// container under the cursor preview the drop, exactly as a live drag would.
func setDragPosition(_ point: NSPoint) {
    let size = ghostView.image?.size ?? .zero
    ghostView.frame = NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
    let cursorSize = cursorView.image?.size ?? .zero
    cursorView.frame = NSRect(x: point.x, y: point.y - cursorSize.height, width: cursorSize.width, height: cursorSize.height)
    for container in paneContainers() {
        let local = container.convert(point, from: contentView)
        container.previewTabDrop(at: container.bounds.contains(local) ? local : nil)
    }
}

func endDrag() {
    ghostView.isHidden = true
    cursorView.isHidden = true
    for container in paneContainers() { container.previewTabDrop(at: nil) }
}

// A point inside `pane` at fractional coordinates of its container (y grows
// upward: fy 0.1 is near the bottom edge).
func point(in pane: Pane, fx: CGFloat, fy: CGFloat) -> NSPoint {
    let rect = pane.container.convert(pane.container.bounds, to: contentView)
    return NSPoint(x: rect.minX + rect.width * fx, y: rect.minY + rect.height * fy)
}

// One scripted drag: lift the tab's ghost at `start`, glide to `end` capturing
// frames (the drop preview tracks live), linger on the highlight, then perform
// the real drop and settle.
func animateDrag(of tab: Tab, from start: NSPoint, to end: NSPoint, onto target: Pane, drop: TabDropTarget) {
    ghostView.image = PaneTitleBarView.dragPreviewImage(for: tab)
    ghostView.isHidden = false
    cursorView.isHidden = false
    setDragPosition(start)
    captureFrame(delay: 0.35)

    let steps = 11
    for step in 1...steps {
        let t = CGFloat(step) / CGFloat(steps)
        let eased = t * t * (3 - 2 * t)
        let p = NSPoint(x: start.x + (end.x - start.x) * eased, y: start.y + (end.y - start.y) * eased)
        setDragPosition(p)
        captureFrame(delay: 0.08)
    }
    captureFrame(delay: 0.9)

    endDrag()
    _ = c.dropTab(withId: tab.id, onto: target, drop: drop)
    pump(0.4)
    captureFrame(delay: 1.4)
}

// The center of a tab's chip in the pane tab bar that owns it (contentView
// coordinates), falling back to the owning pane's title bar.
func chipCenter(of tab: Tab, in pane: Pane) -> NSPoint {
    let tabBar = pane.container.tabBar
    if let frame = tabBar.chipFrame(forTabId: tab.id) {
        return tabBar.convert(NSPoint(x: frame.midX, y: frame.midY), to: contentView)
    }
    let titleBar = pane.container.titleBar
    return titleBar.convert(NSPoint(x: titleBar.bounds.midX, y: titleBar.bounds.midY), to: contentView)
}

// MARK: - The storyboard

// Opening: one pane, three tabs in its tab bar.
captureFrame(delay: 1.3)

// Scene 1 — drag the background Sample.swift chip to the pane's right edge:
// the right-half preview lights up, the drop splits it out into its own pane.
guard let firstPane = notesTab.pane else { exit(1) }
animateDrag(
    of: sampleTab,
    from: chipCenter(of: sampleTab, in: firstPane),
    to: point(in: firstPane, fx: 0.88, fy: 0.5),
    onto: firstPane, drop: .edge(.right)
)

// Scene 2 — drag the displayed notes.md chip onto the bottom edge of the new
// right pane: bottom-half preview, drop stacks it under Sample.swift (the
// vacated left viewport backfills with the terminal).
guard let samplePane = sampleTab.pane else { exit(1) }
animateDrag(
    of: notesTab,
    from: chipCenter(of: notesTab, in: firstPane),
    to: point(in: samplePane, fx: 0.5, fy: 0.12),
    onto: samplePane, drop: .edge(.bottom)
)

// Scene 3 — drag Sample.swift by its pane title bar onto the terminal pane's
// center: the whole viewport lights up, the drop shows the tab there and the
// emptied pane dissolves.
guard let terminalPane = terminalTab.pane, let liftedPane = sampleTab.pane else { exit(1) }
animateDrag(
    of: sampleTab,
    from: chipCenter(of: sampleTab, in: liftedPane),
    to: point(in: terminalPane, fx: 0.5, fy: 0.5),
    onto: terminalPane, drop: .show
)

// Closing hold before the loop restarts.
captureFrame(delay: 2.2)

// MARK: - Encode

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "design/tabs-drag.gif"
let url = URL(fileURLWithPath: out)
guard !frames.isEmpty,
      let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
    FileHandle.standardError.write(Data("no frames / gif destination\n".utf8))
    exit(1)
}
CGImageDestinationSetProperties(destination, [
    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
] as CFDictionary)
for frame in frames {
    CGImageDestinationAddImage(destination, frame.image, [
        kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: frame.delay,
            kCGImagePropertyGIFUnclampedDelayTime: frame.delay,
        ]
    ] as CFDictionary)
}
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("gif finalize failed\n".utf8))
    exit(1)
}
for tab in c.store.tabs { tab.content.teardown() }
print("wrote \(out) (\(frames.count) frames)")
exit(0)
