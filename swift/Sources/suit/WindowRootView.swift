import Cocoa

// Directional pane focus (⌥⌘ arrows).
enum PaneDirection {
    case left, right, up, down
}

// The window's top-level content view: the tab strip as its own row at the
// top of the content area (directly under the real title bar, which owns
// window dragging), the body (sidebar split + pane tree) below it, and the
// blur effect view behind everything.
final class WindowRootView: NSView {
    weak var strip: NSView?
    weak var body: NSView?
    weak var background: NSView?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutParts()
    }

    func layoutParts() {
        background?.frame = bounds
        let stripHeight = TabStripView.height
        strip?.frame = NSRect(x: 0, y: bounds.height - stripHeight, width: bounds.width, height: stripHeight)
        body?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - stripHeight))
    }
}
