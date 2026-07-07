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

    // A path relative to a git root, for the file-scoped git commands.
    private func relativePath(of path: String, inRoot root: String) -> String {
        let standardized = (path as NSString).standardizingPath
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return standardized.hasPrefix(prefix) ? String(standardized.dropFirst(prefix.count)) : standardized
    }

    // MARK: - Window closing

    // The whole-window confirmation, shared by ⌘W on the window's last tab and
    // the close button (windowShouldClose). Unlike confirmTermination it also
    // fires with nothing running, since losing a whole window (or the app,
    // when it's the last window) deserves a warning even when every tab is an
    // idle shell.
    func confirmCloseWindow(processNames: [String]) -> Bool {
        let quitsApp = appDelegate.isLastWindowController(self)
        let messageText = quitsApp ? "Quit Suit?" : "Close Window?"
        guard processNames.isEmpty else {
            return Self.confirmTermination(
                messageText: messageText,
                confirmTitle: quitsApp ? "Quit" : "Close",
                processNames: processNames
            )
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = messageText
        alert.informativeText = quitsApp
            ? "Closing this window will quit Suit."
            : "This will close this window and its \(store.tabs.count) tab\(store.tabs.count == 1 ? "" : "s")."
        alert.addButton(withTitle: quitsApp ? "Quit" : "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // Every tab in this window that currently has a foreground process (i.e. is
    // running something beyond its idle shell), by process name.
    func busyPaneProcessNames() -> [String] {
        store.tabs.compactMap { $0.runningProcessName }
    }

    // One confirmation shared by the tab-, window- and app-close paths,
    // naming what's still running since closing terminates it without further
    // warning. Static so AppDelegate can reuse it for Cmd-Q.
    static func confirmTermination(messageText: String, confirmTitle: String, processNames: [String]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = messageText
        let list = processNames.map { "“\($0)”" }.joined(separator: ", ")
        alert.informativeText = processNames.count == 1
            ? "This will terminate the running process \(list)."
            : "This will terminate \(processNames.count) running processes: \(list)."
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // The traffic-light close button comes through performClose, not ⌘W, so
    // closing a whole window gets the same always-on confirmation here,
    // naming any tabs still running something. window.close() — used by the
    // close paths once everything is torn down — skips this deliberately.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmCloseWindow(processNames: busyPaneProcessNames())
    }

    func windowWillClose(_ notification: Notification) {
        appDelegate.windowControllerDidClose(self)
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
