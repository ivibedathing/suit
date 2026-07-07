import Cocoa

// A container that sizes every subview to its bounds. Used as the window's
// top-level content view (blur effect view + the sidebar split) and as the
// pane tree's host inside that sidebar split.
final class RootContainerView: NSView {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        for subview in subviews {
            subview.frame = bounds
        }
    }
}
