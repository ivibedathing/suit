import Cocoa

// The viewer's root view: an optional top bar (the time-travel
// scrubber) above a text scroll view on the left and a minimap strip on the
// right. Manual layout like the rest of the pane tree.
final class ViewerContainerView: NSView {
    let scrollView: NSScrollView
    let minimap: MinimapView

    // The time-travel scrubber bar: non-nil only while the
    // viewer is scrubbing, laid out as a strip across the top that pushes the
    // text + minimap down.
    var topBar: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let topBar { addSubview(topBar) }
            relayout()
        }
    }
    static let topBarHeight: CGFloat = 34

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
        relayout()
    }

    private func relayout() {
        let barHeight = topBar == nil ? 0 : Self.topBarHeight
        topBar?.frame = NSRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
        let contentHeight = max(0, bounds.height - barHeight)
        let minimapWidth = minimap.isHidden ? 0 : MinimapView.preferredWidth
        scrollView.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - minimapWidth), height: contentHeight)
        minimap.frame = NSRect(x: bounds.width - minimapWidth, y: 0, width: minimapWidth, height: contentHeight)
    }
}
