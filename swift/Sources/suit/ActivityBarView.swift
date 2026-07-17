import Cocoa

// The window's activity bar: a fixed-width, full-height strip pinned to the far
// left edge, outside the sidebar split (WindowRootView lays it out beside the
// body). It holds the tab icons — Files / Sessions / SSH / Notes / Bookmarks,
// in SidebarView.Tab.railOrder — that used to sit as a horizontal row inside the
// sidebar's own top edge. Moving them out is the point: the tabs stay on screen
// and clickable while the sidebar itself is collapsed with Cmd-B, so the bar is
// how you bring a collapsed sidebar back on the tab you want.
//
// Deliberately dumb — it owns no tab state. SidebarView stays the model (the
// enum, the rail order, the persisted selection); this view renders whatever
// `selectedTab` it is handed and reports clicks through `onSelect`. A selected
// tab with no icon here is legal and expected: Git is palette-only, absent from
// railOrder, and simply leaves every icon unselected.
final class ActivityBarView: NSView {
    static let width: CGFloat = 48

    var onSelect: ((SidebarView.Tab) -> Void)?

    var selectedTab: SidebarView.Tab = .files {
        didSet {
            for icon in icons { icon.isSelected = icon.tab == selectedTab }
        }
    }

    private var icons: [RailIconView] = []

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
    }

    // Manual layout, consistent with the rest of the window's chrome (Auto
    // Layout and NSSplitView's frame management don't mix here).
    private func layoutContents() {
        let size = RailIconView.size
        let topPadding: CGFloat = 8
        let gap: CGFloat = 4
        // Unflipped coords: start at the top edge and walk down.
        var y = bounds.height - topPadding - size
        for icon in icons {
            icon.frame = NSRect(x: (bounds.width - size) / 2, y: y, width: size, height: size)
            y -= size + gap
        }
    }
}
