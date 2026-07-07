import Cocoa

extension TerminalWindowController {
    // MARK: - Sidebar

    func toggleSidebar() {
        sidebar.isHidden.toggle()
        layoutSidebarSplit()
        UserDefaults.standard.set(!sidebar.isHidden, forKey: "sidebarVisible")
    }

    // Cmd-Shift-F: reveal the sidebar's Files tab and put the cursor in the
    // search field above the file tree.
    func focusProjectSearch() {
        if sidebar.isHidden {
            sidebar.isHidden = false
            layoutSidebarSplit()
            UserDefaults.standard.set(true, forKey: "sidebarVisible")
        }
        sidebar.showSearch()
    }

    // Turns the picked search scope into the directory rg runs in. "Project" is
    // the current file index's root (which follows the focused pane, like Cmd-P);
    // "Sub-project" is the deepest marker-file directory above the focused
    // pane's cwd (falling back to the project root); "Pane Directory" is the
    // cwd itself.
    func resolveSearchScope(_ scope: SearchScope) -> (root: String, label: String)? {
        // While the sidebar is pinned (Phase 9), "Project" means what the
        // Files tab shows, not the focused pane's project.
        let index = pinnedSidebarRoot.map { FileIndex.shared(forExactDirectory: $0) } ?? currentFileIndex()
        let projectRoot = index.root
        let projectLabel = (projectRoot as NSString).lastPathComponent

        switch scope {
        case .project:
            return (projectRoot, projectLabel)
        case .subproject:
            guard let cwd = focusedPane()?.workingDirectory,
                  cwd == projectRoot || cwd.hasPrefix(projectRoot + "/") else {
                return (projectRoot, projectLabel)
            }
            let relative = cwd == projectRoot ? "" : String(cwd.dropFirst(projectRoot.count + 1))
            // Deepest sub-project root that is the cwd or one of its parents.
            var best: String?
            for dir in index.subprojectBadges.keys where !dir.isEmpty {
                if relative == dir || relative.hasPrefix(dir + "/") {
                    if best == nil || dir.count > best!.count {
                        best = dir
                    }
                }
            }
            guard let best else { return (projectRoot, projectLabel) }
            return (projectRoot + "/" + best, (best as NSString).lastPathComponent)
        case .paneDirectory:
            guard let cwd = focusedPane()?.workingDirectory else {
                return (projectRoot, projectLabel)
            }
            return (cwd, (cwd as NSString).lastPathComponent)
        }
    }

    // The sidebar keeps its width; the pane tree absorbs all window resizing.
    func layoutSidebarSplit() {
        let bounds = sidebarSplit.bounds
        if sidebar.isHidden {
            paneTreeHost.frame = bounds
            return
        }
        let width = min(max(sidebar.frame.width, SidebarView.minWidth), SidebarView.maxWidth)
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        let treeX = width + sidebarSplit.dividerThickness
        paneTreeHost.frame = NSRect(x: treeX, y: 0, width: max(0, bounds.width - treeX), height: bounds.height)
    }

    // MARK: - Project files & viewer tabs

    // The index for the project the user is actually in right now (the focused
    // pane's cwd), falling back to the window's current project. When Cmd-P
    // resolves a different project than the sidebar is showing, the sidebar
    // follows, so the two navigation surfaces never disagree — unless the
    // sidebar is pinned to an explicit folder (Phase 9), which stops it from
    // trailing pane cwds until unpinned.
    func currentFileIndex() -> FileIndex {
        let directory = focusedPane()?.workingDirectory ?? projectIndex.root
        let index = FileIndex.shared(forDirectory: directory)
        if index !== projectIndex {
            projectIndex = index
            if pinnedSidebarRoot == nil {
                sidebar.fileBrowser.configure(index: index)
                sidebar.gitView.configure(displayRoot: index.root)
                // Following the pane into another project counts as opening
                // that folder — feed the sidebar's project switcher.
                FavoritesStore.shared.noteRecentFolder(index.root)
                sidebar.recentFolders.currentRoot = index.root
            }
        }
        return index
    }

    // MARK: - Sidebar folder pinning (ROADMAP Phase 9)

    // "Select Folder…" (Files-tab header button / palette): pin the sidebar's
    // browser and project-scoped search to a picked directory.
    func selectSidebarFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Pin the sidebar's Files tab to a folder."
        panel.directoryURL = URL(fileURLWithPath: pinnedSidebarRoot ?? currentFileIndex().root)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let path = panel.url?.path else { return }
            self?.pinSidebar(toDirectory: path)
        }
    }

    // showFiles: false keeps the current sidebar tab (the Git tab's worktree
    // switcher pins without yanking the user over to the file tree).
    func pinSidebar(toDirectory path: String, showFiles: Bool = true) {
        applySidebarPin(path)
        UserDefaults.standard.set(path, forKey: "sidebarPinnedRoot")
        // Show the result: unhide the sidebar if needed and land on Files.
        if sidebar.isHidden {
            sidebar.isHidden = false
            layoutSidebarSplit()
            UserDefaults.standard.set(true, forKey: "sidebarVisible")
        }
        if showFiles {
            sidebar.select(tab: .files)
        }
    }

    func applySidebarPin(_ path: String) {
        pinnedSidebarRoot = path
        // Exact directory, not the enclosing git root: picking a repo
        // subfolder means "browse this subfolder".
        sidebar.fileBrowser.configure(index: FileIndex.shared(forExactDirectory: path))
        sidebar.fileBrowser.setPinned(true)
        sidebar.gitView.configure(displayRoot: path)
        FavoritesStore.shared.noteRecentFolder(path)
        sidebar.recentFolders.currentRoot = path
    }

    func unpinSidebarFolder() {
        pinnedSidebarRoot = nil
        UserDefaults.standard.removeObject(forKey: "sidebarPinnedRoot")
        sidebar.fileBrowser.setPinned(false)
        // Back to following the focused pane's project.
        let index = currentFileIndex()
        sidebar.fileBrowser.configure(index: index)
        sidebar.gitView.configure(displayRoot: index.root)
        sidebar.recentFolders.currentRoot = index.root
    }

    // Reveal the Notes tab (palette) and put the caret in it.
    func showNotes() {
        if sidebar.isHidden {
            sidebar.isHidden = false
            layoutSidebarSplit()
            UserDefaults.standard.set(true, forKey: "sidebarVisible")
        }
        sidebar.select(tab: .notes)
    }

    // Reveal the Git tab (palette).
    func showGit() {
        if sidebar.isHidden {
            sidebar.isHidden = false
            layoutSidebarSplit()
            UserDefaults.standard.set(true, forKey: "sidebarVisible")
        }
        sidebar.select(tab: .git)
    }

    // Reveal the Bookmarks tab (palette / ROADMAP Phase 22).
    func showBookmarks() {
        if sidebar.isHidden {
            sidebar.isHidden = false
            layoutSidebarSplit()
            UserDefaults.standard.set(true, forKey: "sidebarVisible")
        }
        sidebar.select(tab: .bookmarks)
    }

    // Opens `path` as a first-class tab (files are regular tabs — the Chrome
    // rule): a path that's already open gets its tab activated; otherwise the
    // file opens in a tab of its own. Files never replace one another —
    // opening three files leaves three tabs, deduped by path.
    func openFile(atPath path: String, line: Int?) {
        let standardized = (path as NSString).standardizingPath
        // Deduped by path across every preview kind (viewer/markdown/image/PDF):
        // a file opens at most one tab. A re-open re-loads it, honoring a line
        // jump where the kind supports it.
        if let tab = store.tabs.first(where: { ($0.content as? FileBackedPaneContent)?.filePath == standardized }) {
            (tab.content as? FileBackedPaneContent)?.load(path: standardized, line: line)
            activate(tab)
            return
        }

        let content = makePreviewContent(forPath: standardized)
        let tab = Tab(content: content)
        store.insert(tab)
        content.load(path: standardized, line: line)
        activate(tab)
    }

    // Routes a file to its preview pane by extension (ROADMAP Phase 19):
    // markdown/image/PDF get their own kind, everything else the text viewer.
    private func makePreviewContent(forPath path: String) -> FileBackedPaneContent {
        switch PreviewKind.forPath(path) {
        case .markdown:
            return MarkdownPaneContent()
        case .image:
            return ImagePaneContent()
        case .pdf:
            return PDFPaneContent()
        case .text:
            let viewer = FileViewerPaneContent()
            viewer.setWordWrap(appDelegate.wordWrapEnabled)
            return viewer
        }
    }

    // The window's reused diff tab's content, if one is open — the review
    // draft that "Send Review to Session…" acts on (ROADMAP Phase 16).
    var currentDiffContent: DiffPaneContent? {
        store.tabs.first { $0.content is DiffPaneContent }?.content as? DiffPaneContent
    }

    // Opens (or reuses, same policy as openFile) the window's diff tab showing
    // a project's uncommitted changes — the focused pane's project unless the
    // caller (the Git tab) names a root explicitly.
    func openGitDiff(root explicitRoot: String? = nil) {
        let root = explicitRoot ?? currentFileIndex().root
        guard FileIndex.gitRoot(of: root) != nil else {
            NSSound.beep()
            return
        }
        if let tab = store.tabs.first(where: { $0.content is DiffPaneContent }) {
            (tab.content as? DiffPaneContent)?.loadGitDiff(root: root)
            activate(tab)
            return
        }
        let content = DiffPaneContent()
        let tab = Tab(content: content)
        store.insert(tab)
        content.loadGitDiff(root: root)
        activate(tab)
    }

    // The Git tab's file-scoped variant: the same diff tab, showing only one
    // changed file (staged and unstaged both, like the full HEAD diff).
    func openGitDiff(root: String, file: String) {
        let producer = {
            runProcess("/usr/bin/git", ["-C", root, "diff", "HEAD", "--", file]) ?? ""
        }
        let title = "diff: \((file as NSString).lastPathComponent)"
        let load = { (content: DiffPaneContent) in
            content.loadDiffText(producer(), title: title, root: root, reload: producer)
        }
        if let tab = store.tabs.first(where: { $0.content is DiffPaneContent }) {
            if let content = tab.content as? DiffPaneContent {
                load(content)
            }
            activate(tab)
            return
        }
        let content = DiffPaneContent()
        let tab = Tab(content: content)
        store.insert(tab)
        load(content)
        activate(tab)
    }

    // Opens (or reuses, same policy) the diff tab showing one commit's changes
    // to a single file (ROADMAP Phase 17 — from a File History row or a clicked
    // blame sha). `git show --format=` prints just the per-file diff, no commit
    // header; it handles the root commit (whole-file addition) too.
    func openCommitDiff(root: String, file: String, sha: String) {
        let producer = {
            runProcess("/usr/bin/git", ["-C", root, "show", "--format=", sha, "--", file]) ?? ""
        }
        let title = "diff: \((file as NSString).lastPathComponent) @ \(sha.prefix(8))"
        let load = { (content: DiffPaneContent) in
            content.loadDiffText(producer(), title: title, root: root, reload: producer)
        }
        if let tab = store.tabs.first(where: { $0.content is DiffPaneContent }) {
            if let content = tab.content as? DiffPaneContent {
                load(content)
            }
            activate(tab)
            return
        }
        let content = DiffPaneContent()
        let tab = Tab(content: content)
        store.insert(tab)
        load(content)
        activate(tab)
    }

    // Opens (or reuses) the window's transcript tab showing a Claude session's
    // conversation (ROADMAP Phase 7).
    func openTranscript(for session: ClaudeSession) {
        if let tab = store.tabs.first(where: { $0.content is TranscriptPaneContent }) {
            (tab.content as? TranscriptPaneContent)?.load(session: session)
            activate(tab)
            return
        }
        let content = TranscriptPaneContent()
        let tab = Tab(content: content)
        store.insert(tab)
        content.load(session: session)
        activate(tab)
    }

    // Opens (or reuses) the window's checkpoint-timeline tab showing a Claude
    // session's change history (ROADMAP Phase 25), reused like the transcript.
    func openCheckpointTimeline(for session: ClaudeSession) {
        if let tab = store.tabs.first(where: { $0.content is CheckpointTimelinePaneContent }) {
            (tab.content as? CheckpointTimelinePaneContent)?.load(session: session)
            activate(tab)
            return
        }
        let content = CheckpointTimelinePaneContent()
        let tab = Tab(content: content)
        store.insert(tab)
        content.load(session: session)
        activate(tab)
    }

    // Opens (or reuses) the window's transcript tab for an explicit transcript
    // file — how cross-transcript search (Phase 20) jumps to a historical
    // session, anchoring the pane on the matching line.
    func openTranscript(path: String, cwd: String?, title: String, line: Int?) {
        let content: TranscriptPaneContent
        if let tab = store.tabs.first(where: { $0.content is TranscriptPaneContent }),
           let existing = tab.content as? TranscriptPaneContent {
            content = existing
            content.load(path: path, cwd: cwd, title: title)
            activate(tab)
        } else {
            content = TranscriptPaneContent()
            let tab = Tab(content: content)
            store.insert(tab)
            content.load(path: path, cwd: cwd, title: title)
            activate(tab)
        }
        // Defer the jump one turn so the pane has laid out (scrollRangeToVisible
        // needs a real frame after activate).
        if let line {
            DispatchQueue.main.async { content.jump(toSourceLine: line) }
        }
    }

    // MARK: - Claude task worktrees (ROADMAP Phase 5)

    // "New task": worktree + branch + a tab running claude in it, tagged with
    // the task name. The CLAUDE.md multi-agent discipline as one keystroke.
    func startClaudeTask(named name: String) {
        let root = currentFileIndex().root
        switch WorktreeTasks.createTask(projectRoot: root, name: name) {
        case .failure(let error):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "New Claude Task"
            alert.informativeText = error.message
            alert.runModal()
        case .success(let directory):
            let content = TerminalPaneContent()
            let tab = Tab(content: content)
            tab.customTitle = name
            store.insert(tab)
            content.start(in: directory)
            activate(tab)
            // The pty input queue holds this until zsh is ready to read it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak content] in
                content?.terminalView.send(txt: "claude\n")
            }
        }
    }

    // A task tab finished (worktree merged/discarded and removed): close it
    // without the usual running-process confirmation — the user just confirmed
    // the whole task's fate in the finish dialog.
    func paneFinishedTask(_ pane: Pane) {
        forceCloseTab(pane.tab)
    }
}
