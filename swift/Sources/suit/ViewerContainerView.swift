import Cocoa

// The viewer's root view: text scroll view on the left, minimap strip on the
// right. Manual layout like the rest of the pane tree.
final class ViewerContainerView: NSView {
    let scrollView: NSScrollView
    let minimap: MinimapView

    init(scrollView: NSScrollView, minimap: MinimapView) {
        self.scrollView = scrollView
        self.minimap = minimap
        super.init(frame: .zero)
        addSubview(scrollView)
        addSubview(minimap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let minimapWidth = minimap.isHidden ? 0 : MinimapView.preferredWidth
        scrollView.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - minimapWidth), height: bounds.height)
        minimap.frame = NSRect(x: bounds.width - minimapWidth, y: 0, width: minimapWidth, height: bounds.height)
    }
}
