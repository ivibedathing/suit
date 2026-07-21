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

    // The ⌘F find/replace widget. Deliberately its own slot rather than sharing
    // `topBar` with the scrubber: that slot drops its old view when reassigned,
    // so sharing it would let entering time-travel silently tear down an open
    // find bar (and exiting tear it down again from the other side). Finding
    // inside a historical revision is a real thing to want, so the two coexist.
    //
    // It floats over the text instead of taking a strip, which is both what VS
    // Code does and why it costs nothing: no layout change means no wrap-width
    // re-tile and no scroll jump when it opens.
    var findOverlay: FindBarView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let findOverlay { addSubview(findOverlay, positioned: .above, relativeTo: scrollView) }
            relayout()
        }
    }
    private static let findOverlayInset: CGFloat = 10

    // The breadcrumb strip. Its own slot for the same reason the find bar has
    // one: it must survive entering and leaving time-travel, and it takes a
    // strip (pushing the text down) rather than floating, because it is chrome
    // that belongs to the document, not an overlay on it.
    var breadcrumbBar: BreadcrumbBarView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let breadcrumbBar { addSubview(breadcrumbBar) }
            relayout()
        }
    }

    // The peek-definition popover — floats over the text, positioned near the
    // caret rather than pinned to a corner, because its whole job is to answer a
    // question about the line you're looking at.
    var peekOverlay: DefinitionPeekView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let peekOverlay { addSubview(peekOverlay, positioned: .above, relativeTo: scrollView) }
        }
    }

    // Place the peek below the anchor line when there's room, above it when
    // there isn't — it must never cover the line the reader is asking about.
    func positionPeek(nearCharacterOffset offset: Int, in textView: NSTextView) {
        guard let peekOverlay, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        layoutManager.ensureLayout(for: container)
        let glyph = layoutManager.glyphIndexForCharacter(at: offset)
        let fragment = glyph < layoutManager.numberOfGlyphs
            ? layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            : layoutManager.extraLineFragmentRect

        // Text coordinates → this view's, via the clip view's scroll offset.
        let scrolled = fragment.minY - scrollView.contentView.bounds.minY + textView.textContainerInset.height
        let lineTopFromBottom = scrollView.frame.height - scrolled
        let lineBottomFromBottom = lineTopFromBottom - fragment.height

        let width = min(DefinitionPeekView.preferredWidth, max(240, scrollView.frame.width - 40))
        peekOverlay.frame = NSRect(x: 0, y: 0, width: width, height: DefinitionPeekView.maximumHeight)
        peekOverlay.layoutSubtreeIfNeeded()
        let height = min(peekOverlay.preferredHeight(), scrollView.frame.height - 20)

        let gap: CGFloat = 4
        let below = lineBottomFromBottom - gap - height
        let above = lineTopFromBottom + gap
        let y = below >= 8 ? below : min(above, scrollView.frame.height - height - 8)

        let x = min(max(20, scrollView.frame.width - width - 40), max(0, scrollView.frame.width - width))
        peekOverlay.frame = NSRect(x: x, y: max(8, y), width: width, height: height)
    }

    // The bar changes height when its replace row opens; it calls this to be
    // re-placed without the whole container re-laying out.
    func repositionFindOverlay() {
        relayout()
    }

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

        // The breadcrumb sits under the scrubber (when both are up) and above
        // the text + minimap.
        let crumbHeight = breadcrumbBar == nil ? 0 : BreadcrumbBarView.height
        breadcrumbBar?.frame = NSRect(x: 0, y: bounds.height - barHeight - crumbHeight,
                                      width: bounds.width, height: crumbHeight)

        let contentHeight = max(0, bounds.height - barHeight - crumbHeight)
        let minimapWidth = minimap.isHidden ? 0 : MinimapView.preferredWidth
        scrollView.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - minimapWidth), height: contentHeight)
        minimap.frame = NSRect(x: bounds.width - minimapWidth, y: 0, width: minimapWidth, height: contentHeight)

        // Top-right of the text area, clear of the minimap and of a legacy
        // scroller (overlay scrollers sit on top of the text and auto-hide, so
        // they need no allowance).
        if let findOverlay {
            let inset = Self.findOverlayInset
            let scroller = scrollView.scrollerStyle == .legacy
                ? (scrollView.verticalScroller?.frame.width ?? 0) : 0
            let size = findOverlay.preferredSize(maxWidth: scrollView.frame.width - inset * 2 - scroller)
            findOverlay.frame = NSRect(x: scrollView.frame.maxX - scroller - inset - size.width,
                                       y: contentHeight - inset - size.height,
                                       width: size.width, height: size.height)
        }
    }
}
