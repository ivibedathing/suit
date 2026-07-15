import Cocoa

// This window's slice of state restoration: snapshot its tab list + split tree
// into StateRestoration's Codable model, replay a saved snapshot on launch or
// layout-open (dropping tabs whose content can't come back), and re-attach
// Claude sessions to the restored panes.
extension TerminalWindowController {

    // MARK: - State restoration

    func captureState() -> SavedWindow {
        var savedTabs: [SavedTab] = []
        var indexById: [String: Int] = [:]
        for tab in store.tabs {
            if let saved = savedTab(for: tab) {
                indexById[tab.id] = savedTabs.count
                savedTabs.append(saved)
            }
        }
        let tree = captureNode(paneTreeRoot, indexById: indexById)
        let mru = store.tabsInMRUOrder().compactMap { indexById[$0.id] }
        return SavedWindow(
            frame: window.frame,
            tabs: savedTabs,
            tree: tree,
            mru: mru,
            activeTabIndex: activeTab.flatMap { indexById[$0.id] }
        )
    }

    func savedTab(for tab: Tab) -> SavedTab? {
        switch tab.content {
        // Before the TerminalPaneContent arm — SSHPaneContent is a subclass.
        case let ssh as SSHPaneContent:
            return SavedTab(
                kind: .ssh, cwd: ssh.workingDirectory,
                isPreview: tab.isPreview, isPinned: tab.isPinned, customTitle: tab.customTitle,
                sshHostId: ssh.sshHost.id.uuidString
            )
        case let terminal as TerminalPaneContent:
            return SavedTab(
                kind: .terminal, cwd: terminal.workingDirectory,
                isPreview: tab.isPreview, isPinned: tab.isPinned, customTitle: tab.customTitle
            )
        case let viewer as FileViewerPaneContent:
            guard let path = viewer.filePath else { return nil }
            return SavedTab(
                kind: .viewer, filePath: path, firstVisibleLine: viewer.firstVisibleLine,
                isPreview: tab.isPreview, isPinned: tab.isPinned, customTitle: tab.customTitle
            )
        case let markdown as MarkdownPaneContent:
            guard let path = markdown.filePath else { return nil }
            return SavedTab(
                kind: .markdown, filePath: path,
                isPreview: tab.isPreview, isPinned: tab.isPinned, customTitle: tab.customTitle,
                scrollFraction: markdown.scrollFraction
            )
        case let image as ImagePaneContent:
            guard let path = image.filePath else { return nil }
            return SavedTab(
                kind: .image, filePath: path,
                isPreview: tab.isPreview, isPinned: tab.isPinned, customTitle: tab.customTitle,
                imageActualSize: image.isActualSize
            )
        case let pdf as PDFPaneContent:
            guard let path = pdf.filePath else { return nil }
            return SavedTab(
                kind: .pdf, filePath: path,
                isPreview: tab.isPreview, isPinned: tab.isPinned, customTitle: tab.customTitle,
                pdfPage: pdf.currentPageIndex
            )
        case let diff as DiffPaneContent:
            guard let root = diff.gitRoot else { return nil }
            let comments = diff.reviewDraft.comments
            return SavedTab(
                kind: .diff, diffRoot: root,
                reviewComments: comments.isEmpty ? nil : comments,
                isPreview: tab.isPreview, isPinned: tab.isPinned, customTitle: tab.customTitle
            )
        case let graph as CommitGraphPaneContent:
            guard let root = graph.gitRoot else { return nil }
            return SavedTab(
                kind: .commitGraph, graphRoot: root,
                isPreview: tab.isPreview, isPinned: tab.isPinned, customTitle: tab.customTitle
            )
        default:
            // Transcript tabs: the session won't exist next launch.
            return nil
        }
    }

    private func captureNode(_ view: NSView, indexById: [String: Int]) -> SavedNode? {
        if let split = view as? NSSplitView, split.arrangedSubviews.count == 2 {
            let firstView = split.arrangedSubviews[0]
            let total = split.isVertical ? split.frame.width : split.frame.height
            let firstSize = split.isVertical ? firstView.frame.width : firstView.frame.height
            let first = captureNode(firstView, indexById: indexById)
            let second = captureNode(split.arrangedSubviews[1], indexById: indexById)
            guard let first else { return second }
            guard let second else { return first }
            return .split(
                vertical: split.isVertical,
                fraction: total > 0 ? Double(firstSize / total) : 0.5,
                first: first,
                second: second
            )
        }
        guard let pane = (view as? PaneContainerView)?.pane,
              let index = indexById[pane.tab.id] else { return nil }
        // Only a size that differs from the global font is a per-pane override
        // worth carrying across the relaunch.
        let paneSize = pane.appliedFont?.pointSize
        let fontSize = paneSize == appDelegate.currentFont.pointSize ? nil : paneSize.map(Double.init)
        return .pane(tabIndex: index, fontSize: fontSize)
    }

    func buildNode(_ node: SavedNode, restored: [Int: Tab]) -> NSView? {
        switch node {
        case .pane(let tabIndex, let fontSize):
            // A tab can only be displayed once; a stale tree that references
            // the same tab twice keeps the first viewport.
            guard let tab = restored[tabIndex], tab.pane == nil else { return nil }
            let pane = makePane(displaying: tab)
            if let fontSize {
                pane.setFont(NSFontManager.shared.convert(appDelegate.currentFont, toSize: CGFloat(fontSize)))
            }
            return pane.container
        case .split(let vertical, let fraction, let first, let second):
            let a = buildNode(first, restored: restored)
            let b = buildNode(second, restored: restored)
            guard let a else { return b }
            guard let b else { return a }
            let split = NSSplitView(frame: .zero)
            split.isVertical = vertical
            split.dividerStyle = .thin
            split.delegate = self
            split.addArrangedSubview(a)
            split.addArrangedSubview(b)
            pendingDividerFractions.append((split, fraction))
            return split
        }
    }

    func restoredContent(_ tab: SavedTab) -> PaneContent? {
        switch tab.kind {
        case .terminal:
            let terminal = TerminalPaneContent()
            let cwd = tab.cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            terminal.start(in: cwd ?? NSHomeDirectory())
            return terminal
        case .viewer:
            guard let path = tab.filePath, FileManager.default.fileExists(atPath: path) else { return nil }
            let viewer = FileViewerPaneContent()
            viewer.setWordWrap(appDelegate.wordWrapEnabled)
            viewer.load(path: path, line: nil)
            if let line = tab.firstVisibleLine, line > 1 {
                pendingScrollRestores.append { viewer.scrollTo(firstVisibleLine: line) }
            }
            return viewer
        case .markdown:
            guard let path = tab.filePath, FileManager.default.fileExists(atPath: path) else { return nil }
            let markdown = MarkdownPaneContent()
            markdown.load(path: path, line: nil)
            if let fraction = tab.scrollFraction, fraction > 0 {
                pendingScrollRestores.append { markdown.restore(scrollFraction: fraction) }
            }
            return markdown
        case .image:
            guard let path = tab.filePath, FileManager.default.fileExists(atPath: path) else { return nil }
            let image = ImagePaneContent()
            image.load(path: path, line: nil)
            if tab.imageActualSize == true {
                pendingScrollRestores.append { image.restoreZoom(actualSize: true) }
            }
            return image
        case .pdf:
            guard let path = tab.filePath, FileManager.default.fileExists(atPath: path) else { return nil }
            let pdf = PDFPaneContent()
            pdf.load(path: path, line: nil)
            if let page = tab.pdfPage, page > 0 {
                pendingScrollRestores.append { pdf.restore(pageIndex: page) }
            }
            return pdf
        case .diff:
            guard let root = tab.diffRoot, FileManager.default.fileExists(atPath: root) else { return nil }
            let diff = DiffPaneContent()
            diff.loadGitDiff(root: root)
            diff.restoreComments(tab.reviewComments)
            return diff
        case .commitGraph:
            guard let root = tab.graphRoot, FileManager.default.fileExists(atPath: root),
                  FileIndex.gitRoot(of: root) != nil else { return nil }
            let graph = CommitGraphPaneContent()
            graph.load(root: root)
            return graph
        case .ssh:
            let cwd = tab.cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            guard let host = tab.sshHostId
                .flatMap(UUID.init(uuidString:))
                .flatMap({ SSHHostsStore.shared.host(withId: $0) }) else {
                // The saved host is gone — restore the tab as a plain shell
                // rather than dropping it.
                let terminal = TerminalPaneContent()
                terminal.start(in: cwd ?? NSHomeDirectory())
                return terminal
            }
            let ssh = SSHPaneContent(host: host)
            ssh.start(in: NSHomeDirectory())
            // Pre-typed, not submitted: relaunching the app must never
            // reconnect to servers on its own.
            ssh.prepareReconnect()
            return ssh
        }
    }

    // MARK: - Claude sessions

    func updateUsageLabel() {
        guard let usage = ClaudeSessionMonitor.shared.usage else {
            strip.setUsage(text: "", color: Theme.textDim)
            return
        }
        var parts: [String] = []
        if let five = usage.fiveHourPct {
            parts.append("5h \(Int(five.rounded()))%")
        }
        if let week = usage.sevenDayPct {
            parts.append("7d \(Int(week.rounded()))%")
        }
        let worst = max(usage.fiveHourPct ?? 0, usage.sevenDayPct ?? 0)
        strip.setUsage(text: parts.joined(separator: " · "), color: Theme.usageLevelColor(worst))
    }

    // Re-maps sessions onto this window's terminal tabs (pid ancestry, cwd
    // fallback — see ClaudeSessionAssigner). Called by AppDelegate on session
    // updates and on a slow heartbeat, since process trees change silently.
    // Every tab carries its own session so background tabs still route
    // attention (strip dot + pane header when visible).
    func refreshClaudeSessions(assigner: ClaudeSessionAssigner) {
        var changed = false
        for tab in store.tabs {
            let session: ClaudeSession?
            if tab.exitStatus == nil, let terminal = tab.content as? TerminalPaneContent {
                session = assigner.session(forShellPid: terminal.shellPid, cwd: terminal.workingDirectory)
            } else {
                session = nil
            }
            if session?.id != tab.claudeSession?.id || session?.state != tab.claudeSession?.state
                || session?.contextPct != tab.claudeSession?.contextPct {
                changed = true
            }
            tab.claudeSession = session
        }
        if changed {
            reloadStrip()
            for pane in panes {
                pane.refreshChrome()
            }
        }
        updateUsageLabel()
    }

    func runsClaudeSession(withId id: String) -> Bool {
        store.tabs.contains { $0.claudeSession?.id == id }
    }

    // Notification click-through (ClaudeAttentionCenter): bring the exact tab
    // running that session forward, wherever it's hiding.
    func focusPane(runningSession session: ClaudeSession) {
        guard let tab = store.tabs.first(where: { $0.claudeSession?.id == session.id }) else {
            NSSound.beep()
            return
        }
        window.makeKeyAndOrderFront(nil)
        activate(tab)
    }
}
