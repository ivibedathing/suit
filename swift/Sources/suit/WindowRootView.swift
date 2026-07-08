import Cocoa

// The window's top-level content view: the body (sidebar split + pane tree)
// fills the whole content area, with the blur effect view behind it. The old
// window-level tab strip is gone — tabs now live on each pane's own in-pane tab
// bar, and the sidebar's Sessions tab is the cross-pane overview.
final class WindowRootView: NSView {
    weak var body: NSView?
    weak var background: NSView?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutParts()
    }

    func layoutParts() {
        background?.frame = bounds
        body?.frame = bounds
    }
}
