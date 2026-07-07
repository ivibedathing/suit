import Cocoa

// A top-anchored document view for the settings scroll views, so content lays
// out from the top and scrolls downward the usual way.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
