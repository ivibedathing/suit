import Cocoa

extension TerminalWindowController {

    // MARK: - Panes

    // Builds a viewport around a tab from the store — the one place pane
    // appearance setup happens.
    func makePane(displaying tab: Tab) -> Pane {
        let pane = Pane(host: self, tab: tab)
        panes.append(pane)
        updateBorderVisibility()
        pane.setBackgroundAlpha(appDelegate.backgroundAlpha)
        pane.setFont(appDelegate.currentFont)
        pane.setTextColor(appDelegate.currentTextColor)
        (tab.content as? FileViewerPaneContent)?.setWordWrap(appDelegate.wordWrapEnabled)
        return pane
    }

    // The border is only meaningful once there's more than one pane to distinguish.
    func updateBorderVisibility() {
        let showBorders = panes.count > 1
        for pane in panes {
            pane.setBorderVisible(showBorders)
        }
    }

    // Walks up from the first responder to the PaneContainerView that owns it,
    // so this works for any pane content, not just terminals.
    func focusedPane() -> Pane? {
        var view = window.firstResponder as? NSView
        while let current = view {
            if let container = current as? PaneContainerView {
                return container.pane
            }
            view = current.superview
        }
        return nil
    }

    func paneTitleChanged(_ pane: Pane) {
        if focusedPane() === pane {
            window.title = pane.displayTitle
            store.touchMRU(pane.tab)
        }
        reloadStrip()
    }

    // MARK: - In-pane tab bar (PaneHost)

    // The tabs a pane owns, in strip order — feeds its in-pane tab bar.
    func ownedTabs(for pane: Pane) -> [Tab] {
        store.ownedTabs(of: pane)
    }

    // A chip click in a pane's own tab bar: show that tab in that pane and
    // focus it (it already belongs there, so no cross-pane move).
    func paneDidSelectOwnedTab(_ pane: Pane, tab: Tab) {
        guard store.tab(withId: tab.id) != nil else { return }
        if pane.tab !== tab {
            pane.display(tab)
        }
        focusPane(pane)
        store.touchMRU(tab)
        reloadStrip()
    }

    // The chip's close box.
    func paneDidCloseOwnedTab(_ pane: Pane, tab: Tab) {
        closeTab(tab)
    }

    func contextMenu(forOwnedTab tab: Tab) -> NSMenu {
        tabContextMenu(for: tab)
    }

    // Move every tab `pane` still owns to `dest` as background tabs — used
    // before a viewport dissolves (unsplit / merge / drag-away) so the pane's
    // tabs live on instead of vanishing with the viewport.
    func absorbOwnedTabs(from pane: Pane, into dest: Pane) {
        guard dest !== pane else { return }
        for tab in store.ownedTabs(of: pane) {
            if tab.pane === pane {
                tab.pane = nil
                tab.content.pane = nil
            }
            tab.homePane = dest
        }
    }

    // The pane a dissolving `pane`'s tabs should move to: prefer an explicit
    // destination, else any other pane.
    func absorbTarget(excluding pane: Pane) -> Pane? {
        panes.first { $0 !== pane }
    }

    // A terminal pane's Cmd-click on a file-path link (see PaneTerminalView.mouseUp).
    func paneRequestedOpenFile(path: String, line: Int?) {
        openFile(atPath: path, line: line)
    }

    // Blame sha click (ROADMAP Phase 17): open that commit's per-file diff.
    func paneRequestedOpenCommitDiff(forFile path: String, sha: String) {
        let directory = (path as NSString).deletingLastPathComponent
        guard let root = FileIndex.gitRoot(of: directory) else {
            NSSound.beep()
            return
        }
        let relative = relativePath(of: path, inRoot: root)
        openCommitDiff(root: root, file: relative, sha: sha)
    }

    // Commit-graph node click (ROADMAP Phase 34): open that commit's whole diff.
    func paneRequestedOpenCommitDiff(sha: String, root: String) {
        openCommitDiff(root: root, sha: sha)
    }

    // Viewer "Show File History" / palette: reveal the Git tab's File History
    // section for this file.
    func paneRequestedShowFileHistory(forPath path: String) {
        let directory = (path as NSString).deletingLastPathComponent
        guard FileIndex.gitRoot(of: directory) != nil else {
            NSSound.beep()
            return
        }
        showGit()
        sidebar.gitView.showFileHistory(absolutePath: (path as NSString).standardizingPath)
    }

    // Symbol navigation (ROADMAP Phase 33): resolve against the pane's project.
    func paneRequestedGoToDefinition(symbol: String, fromDirectory directory: String?) {
        goToDefinition(symbol: symbol, fromDirectory: directory)
    }

    func paneRequestedFindReferences(symbol: String, fromDirectory directory: String?) {
        findReferences(symbol: symbol, fromDirectory: directory)
    }

    // Background-task monitor for a pane's shell (ROADMAP Phase 30): a terminal
    // pane scopes to its own shell's job subtree; any other pane kind opens the
    // window-wide monitor (shellPid 0).
    func paneRequestedShowBackgroundTasks(_ pane: Pane) {
        if let shellPid = pane.terminalContent?.shellPid, shellPid > 0 {
            openBackgroundTasks(forShellPid: shellPid, title: "Background Tasks")
        } else {
            openBackgroundTasks(forShellPid: 0, title: "Background Tasks")
        }
    }

    // A path relative to a git root, for the file-scoped git commands.
    private func relativePath(of path: String, inRoot root: String) -> String {
        let standardized = (path as NSString).standardizingPath
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return standardized.hasPrefix(prefix) ? String(standardized.dropFirst(prefix.count)) : standardized
    }

    // MARK: - Footer

    // The footer is simply the bottom half of a horizontal split at the very root
    // of the pane tree, so it always spans the window's full width no matter how
    // the panes above it are split.
    func paneIsFooter(_ pane: Pane) -> Bool {
        guard let rootSplit = paneTreeRoot as? NSSplitView, !rootSplit.isVertical else { return false }
        return rootSplit.arrangedSubviews.last === pane.container
    }

    // Pulls the pane out of wherever it sits in the split tree and re-roots the
    // tree as {everything else} stacked above {this pane}, full width.
    func paneRequestedFooter(_ pane: Pane) {
        guard !paneIsFooter(pane) else { return }
        let paneContainer = pane.container

        // Sole pane (it's the tree root) — already full width, nothing to dock below.
        // Also refuse when the window is too short to stack two usable rows.
        guard let parentSplit = paneContainer.superview as? NSSplitView,
              paneTreeHost.bounds.height >= minPaneHeight * 2 else {
            NSSound.beep()
            return
        }

        guard detachFromPaneTree(paneContainer, parentSplit: parentSplit) != nil else {
            NSSound.beep()
            return
        }

        let splitView = NSSplitView(frame: paneTreeHost.bounds)
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.delegate = self

        let upperTree = paneTreeRoot!
        paneTreeHost.replaceSubview(upperTree, with: splitView)
        splitView.addArrangedSubview(upperTree)
        splitView.addArrangedSubview(paneContainer)
        paneTreeRoot = splitView

        splitView.layoutSubtreeIfNeeded()
        let footerHeight = max(minPaneHeight, splitView.frame.height * 0.3)
        splitView.setPosition(splitView.frame.height - footerHeight, ofDividerAt: 0)

        window.makeFirstResponder(pane.focusTarget)
    }

    func firstPane(in view: NSView) -> Pane? {
        if let container = view as? PaneContainerView {
            return container.pane
        }
        for subview in view.subviews {
            if let found = firstPane(in: subview) {
                return found
            }
        }
        return nil
    }

    // MARK: - Palette

    // Every open tab in this window, as palette commands — the fuzzy "jump to
    // any open tab" surface (Go to Tab…).
    func tabPaletteCommands() -> [PaletteCommand] {
        store.tabs.enumerated().map { index, tab in
            let location = tab.pane == nil ? "background" : "visible"
            return PaletteCommand(title: tab.title, shortcut: "tab \(index + 1) · \(location)") { [weak self, weak tab] in
                guard let self, let tab else { return }
                self.activate(tab)
            }
        }
    }

    // MARK: - Opacity, blur & appearance

    // window.backgroundColor only paints pixels no subview covers. Keep it
    // opaque so the title-bar row (traffic lights) never goes see-through;
    // panes handle their own translucency via setBackgroundAlpha regardless.
    func applyTransparency(alpha: CGFloat, blurEnabled: Bool) {
        let transparent = alpha < 1
        window.isOpaque = !transparent
        window.backgroundColor = Theme.bg
        effectView.isHidden = !blurEnabled
        for pane in panes {
            pane.setBackgroundAlpha(alpha)
        }
    }

    func applyFont(_ font: NSFont) {
        for pane in panes {
            pane.setFont(font)
        }
    }

    func applyTextColor(_ color: NSColor) {
        for pane in panes {
            pane.setTextColor(color)
        }
    }

    func applyWordWrap(_ wrap: Bool) {
        for tab in store.tabs {
            (tab.content as? FileViewerPaneContent)?.setWordWrap(wrap)
        }
    }

    // The settings window changed the default pane background. Repaint every
    // pane — same all-panes sweep as applyTextColor; per-pane menu overrides
    // are repainted too and can be re-picked.
    func applyDefaultBackground(_ color: NSColor) {
        for pane in panes {
            pane.setBackgroundColor(color)
        }
    }

    // Every terminal tab, background ones included — the pty and its Terminal
    // keep running while a tab is hidden from every pane.
    func applyCursorStyle(_ style: CursorStyle) {
        for tab in store.tabs {
            (tab.content as? TerminalPaneContent)?.applyCursorStyle(style)
        }
    }
}
