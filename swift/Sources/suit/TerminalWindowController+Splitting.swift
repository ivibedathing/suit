import Cocoa

extension TerminalWindowController {

    // MARK: - Split Screen (tab-first)

    // Strip right-click ▸ Split Screen: show `tab` beside the active tab in a
    // new viewport — vertical when the screen is wide enough, else stacked.
    // The tab-first replacement for the old pane-first ⌘D splits.
    // `forcedOrientation` (⇧⌘D) pins the split axis; otherwise it's chosen by
    // the pane's shape (wide → side-by-side, tall → stacked).
    func splitScreen(with tab: Tab, forcedOrientation: SplitOrientation? = nil) {
        guard store.tab(withId: tab.id) != nil, tab.pane == nil,
              let target = displayTargetPane(),
              let orientation = splitOrientation(for: target, forced: forcedOrientation) else {
            NSSound.beep()
            return
        }
        let newPane = makePane(displaying: tab)
        insert(newPane.container, besides: target.container, orientation: orientation, before: false)
        equalizeSplits()
        focusPane(newPane)
        store.touchMRU(tab)
        reloadStrip()
    }

    // A forced orientation is honored only if the pane has room along that axis;
    // otherwise: wide enough → side-by-side, tall enough → stacked, neither → nil.
    private func splitOrientation(for target: Pane, forced: SplitOrientation? = nil) -> SplitOrientation? {
        if let forced {
            let room = forced == .vertical
                ? target.container.frame.width >= minPaneWidth * 2
                : target.container.frame.height >= minPaneHeight * 2
            return room ? forced : nil
        }
        if target.container.frame.width >= minPaneWidth * 2 { return .vertical }
        if target.container.frame.height >= minPaneHeight * 2 { return .horizontal }
        return nil
    }

    // ⌘D (auto orientation) / ⇧⌘D (forced horizontal, stacked): split the screen
    // with a brand-new shell tab starting in the focused pane's cwd — the
    // fresh-terminal twin of ⌘T, shown beside instead of over.
    func splitScreenWithNewTerminal(forcedOrientation: SplitOrientation? = nil) {
        // Check there's room before creating the tab, so a refused split
        // doesn't strand a freshly started shell in the strip's background.
        guard let target = displayTargetPane(),
              splitOrientation(for: target, forced: forcedOrientation) != nil else {
            NSSound.beep()
            return
        }
        let content = TerminalPaneContent()
        let tab = Tab(content: content)
        store.insert(tab)
        content.start(in: target.workingDirectory ?? NSHomeDirectory())
        splitScreen(with: tab, forcedOrientation: forcedOrientation)
    }

    // Palette "Split Screen (last used tab)": Split Screen with the most recently
    // used background tab — the same tab a vacated viewport would fall back to.
    func splitScreenWithMRUTab() {
        guard let tab = store.mruBackgroundTab() else {
            NSSound.beep()
            return
        }
        splitScreen(with: tab)
    }

    // The background tabs, for the palette's "Split Screen with Tab…" picker.
    func backgroundTabs() -> [Tab] {
        store.tabs.filter { $0.pane == nil }
    }

    // Strip right-click ▸ Unsplit: the tab's viewport dissolves and the tab
    // returns to the strip's background, its process untouched.
    func unsplit(_ tab: Tab) {
        guard let pane = tab.pane, panes.count > 1 else {
            NSSound.beep()
            return
        }
        // The viewport collapses; every tab it owned (the shown one and any
        // background tabs) folds into a surviving pane — dissolvePane absorbs.
        dissolvePane(pane)
        equalizeSplits()
        reloadStrip()
    }

    // N screens share the space equally: every divider apportions its axis by
    // the number of panes on each side, so a run of same-orientation splits
    // comes out exactly 1/N (three tabs → thirds), and mixed grids get
    // area-proportional shares. Applied when Split Screen / Unsplit change
    // the screen count — drag-resized dividers stay put otherwise.
    private func equalizeSplits() {
        guard let root = paneTreeRoot else { return }
        equalizeNode(root)
    }

    private func paneCount(in view: NSView) -> Int {
        if view is PaneContainerView { return 1 }
        return view.subviews.reduce(0) { $0 + paneCount(in: $1) }
    }

    // Top-down: size a split's own divider first, then its children against
    // their settled frames.
    private func equalizeNode(_ view: NSView) {
        guard let split = view as? NSSplitView, split.arrangedSubviews.count == 2 else { return }
        split.layoutSubtreeIfNeeded()
        let first = split.arrangedSubviews[0]
        let second = split.arrangedSubviews[1]
        let firstShare = CGFloat(paneCount(in: first))
        let secondShare = CGFloat(paneCount(in: second))
        guard firstShare > 0, secondShare > 0 else { return }
        let total = (split.isVertical ? split.frame.width : split.frame.height) - split.dividerThickness
        split.setPosition(total * firstShare / (firstShare + secondShare), ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        equalizeNode(first)
        equalizeNode(second)
    }

    // ⌃⌘M / palette: collapse the split tree back to the single-viewport
    // default (the Chrome state). Every displaced tab stays open
    // in the strip as a background tab; only the viewports go away.
    func mergeAllPanes() {
        guard panes.count > 1, let keep = displayTargetPane() else {
            NSSound.beep()
            return
        }
        for pane in Array(panes) where pane !== keep {
            // Every other viewport's tabs fold into `keep` as background tabs.
            dissolvePane(pane, absorbInto: keep)
        }
        focusPane(keep)
        reloadStrip(animated: true)
    }

    // Wraps `target`'s slot in the tree (its parent split's arranged position, or
    // the root) with a new NSSplitView holding `container` and `target` side by
    // side, divider at the midpoint. `before` puts `container` on the left/top.
    func insert(_ container: NSView, besides target: NSView, orientation: SplitOrientation, before: Bool) {
        let splitView = NSSplitView(frame: target.frame)
        splitView.isVertical = orientation == .vertical
        splitView.dividerStyle = .thin
        splitView.delegate = self

        if target === paneTreeRoot {
            paneTreeHost.replaceSubview(target, with: splitView)
            paneTreeRoot = splitView
        } else if let parent = target.superview as? NSSplitView {
            let index = parent.arrangedSubviews.firstIndex(of: target) ?? 0
            parent.removeArrangedSubview(target)
            target.removeFromSuperview()
            parent.insertArrangedSubview(splitView, at: index)
        }

        splitView.addArrangedSubview(before ? container : target)
        splitView.addArrangedSubview(before ? target : container)
        splitView.layoutSubtreeIfNeeded()
        let dividerPosition = orientation == .vertical ? splitView.frame.width / 2 : splitView.frame.height / 2
        splitView.setPosition(dividerPosition, ofDividerAt: 0)
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView === sidebarSplit { return SidebarView.minWidth }
        return proposedMinimumPosition + (splitView.isVertical ? minPaneWidth : minPaneHeight)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView === sidebarSplit { return SidebarView.maxWidth }
        return proposedMaximumPosition - (splitView.isVertical ? minPaneWidth : minPaneHeight)
    }

    // The pane-tree splits keep NSSplitView's default proportional resizing;
    // the sidebar split instead pins the sidebar's width so window resizes go
    // entirely to the pane tree.
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        if splitView === sidebarSplit {
            layoutSidebarSplit()
        } else {
            splitView.adjustSubviews()
        }
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Persist the width the user dragged the sidebar to.
        guard notification.object as? NSSplitView === sidebarSplit,
              !sidebar.isHidden, sidebar.frame.width >= SidebarView.minWidth else { return }
        UserDefaults.standard.set(Double(sidebar.frame.width), forKey: "sidebarWidth")
    }
}
