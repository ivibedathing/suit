import Cocoa

// The window's top-level content view: the body (sidebar split + pane tree)
// fills the whole content area. The old window-level tab strip is gone — tabs
// now live on each pane's own in-pane tab bar, and the sidebar's Sessions tab is
// the cross-pane overview. Terminal transparency is a behind-window frost hosted
// per pane (see PaneContainerView), not a single view behind the whole window.
final class WindowRootView: NSView {
    weak var body: NSView?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutParts()
    }

    func layoutParts() {
        body?.frame = bounds
    }
}
