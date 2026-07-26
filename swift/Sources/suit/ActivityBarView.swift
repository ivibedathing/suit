import Cocoa

// The window's activity bar: a fixed-width, full-height strip pinned to the far
// left edge, outside the sidebar split (WindowRootView lays it out beside the
// body). It holds the tab icons — Files / Search / Sessions / SSH / Notes,
// in SidebarView.Tab.railOrder — that used to sit as a horizontal row inside the
// sidebar's own top edge. Moving them out is the point: the tabs stay on screen
// and clickable while the sidebar itself is collapsed with Cmd-B, so the bar is
// how you bring a collapsed sidebar back on the tab you want.
//
// Deliberately dumb — it owns no tab state. SidebarView stays the model (the
// enum, the rail order, the persisted selection); this view renders whatever
// `selectedTab` it is handed and reports clicks through `onSelect`. A selected
// tab with no icon here is legal and expected: Git and Bookmarks are
// palette-only, absent from railOrder, and simply leave every icon unselected.
final class ActivityBarView: NSView {
    static let width: CGFloat = 48

    var onSelect: ((SidebarView.Tab) -> Void)?

    var selectedTab: SidebarView.Tab = .files {
        didSet {
            for icon in icons { icon.isSelected = icon.tab == selectedTab }
        }
    }

    private var icons: [RailIconView] = []

    // A count in the corner of one tab's icon — the Source Control tab's
    // changed-file count, so a dirty tree is visible with the sidebar
    // collapsed. A tab with no icon here (Bookmarks) silently ignores it.
    func setBadge(_ count: Int, for tab: SidebarView.Tab) {
        icons.first { $0.tab == tab }?.badgeCount = count
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // The same flat bar ground as the sidebar beside it — the bar, the
        // sidebar and the headers are one dark world, not chrome on chrome.
        wantsLayer = true
        layer?.backgroundColor = Theme.barChrome.cgColor

        for tab in SidebarView.Tab.railOrder {
            let icon = RailIconView(tab: tab)
            icon.onClick = { [weak self] tab in self?.onSelect?(tab) }
            icons.append(icon)
            addSubview(icon)
        }
        layoutContents()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Live theme switch: the layer ground and each icon's tint are baked in at
    // init, so neither is reached by the controller's recursive needsDisplay
    // sweep — that only repaints draw()-based chrome. Called explicitly from
    // applyTheme(), exactly like SidebarView.reapplyTheme().
    func reapplyTheme() {
        layer?.backgroundColor = Theme.barChrome.cgColor
        for icon in icons { icon.reapplyTheme() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContents()
        needsDisplay = true
    }

    // The bar and the sidebar beside it share one ground (`barChrome`), which
    // is the look — but it also means the strip has no edge, and the icons run
    // into the panel as one undifferentiated column. Two hairlines give it
    // back: a full-height rule down the right edge so the strip is a column of
    // its own, and a short inset rule between consecutive icons so each tab
    // reads as its own cell rather than a floating glyph. The separators are
    // inset well inside the 40pt hover square, so a hovered or selected icon's
    // rounded fill still sits clear of them.
    override func draw(_ dirtyRect: NSRect) {
        Theme.hairline.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()

        let inset: CGFloat = 12
        // Between each pair, not after the last: a rule under the bottom icon
        // would read as the end of a list the strip doesn't have.
        for icon in icons.dropLast() {
            NSRect(
                x: bounds.minX + inset, y: icon.frame.minY - 2.5,
                width: bounds.width - inset * 2 - 1, height: 1
            ).fill()
        }
    }

    // Manual layout, consistent with the rest of the window's chrome (Auto
    // Layout and NSSplitView's frame management don't mix here).
    private func layoutContents() {
        let size = RailIconView.size
        // Shared with the sidebar's own top inset so the first icon and the tab
        // content beside it start on one line — now that both are zero, the
        // icon's 40pt cell brackets the 28pt title band next to it.
        let topPadding = SidebarView.topInset
        let gap: CGFloat = 4
        // Unflipped coords: start at the top edge and walk down.
        var y = bounds.height - topPadding - size
        for icon in icons {
            icon.frame = NSRect(x: (bounds.width - size) / 2, y: y, width: size, height: size)
            y -= size + gap
        }
    }
}
