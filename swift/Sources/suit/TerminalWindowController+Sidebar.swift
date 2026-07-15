import Cocoa

// The window's sidebar half: build/toggle the icon rail and its tabs, route
// sidebar events into the window (file clicks become viewer tabs), and pin the
// Files tab to a folder.
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
        // While the sidebar is pinned, "Project" means what the
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
    // sidebar is pinned to an explicit folder, which stops it from
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

    // MARK: - Sidebar folder pinning

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

    // Picking a worktree from either switcher (Files-tab footer, Git-tab
    // header): repoint the sidebar there, and — the point of this method over a
    // bare pinSidebar — walk the window's terminals over to the new worktree so
    // the shells the user is looking at actually land on the new branch.
    func switchWorktree(toDirectory path: String, showFiles: Bool = true) {
        pinSidebar(toDirectory: path, showFiles: showFiles)
        followWorktreeInTerminals(newRoot: path)
    }

    // Switching worktrees repoints the sidebar; the terminals should follow so
    // the active shell reflects the new branch. For each visible terminal
    // sitting idle at a prompt whose cwd belongs to this repo's worktree family,
    // `cd` it to the matching spot under the new worktree — preserving the
    // relative subpath when it exists there, otherwise landing at the root.
    // Terminals running a foreground job (claude, vim, a build) are skipped: a
    // cd would just be swallowed by that program's stdin.
    func followWorktreeInTerminals(newRoot: String) {
        // Every worktree of this repo, including the main checkout — the set a
        // shell must currently sit inside to be considered "following" the repo.
        let siblings = WorktreeSwitcher.worktrees(root: newRoot).map { $0.path }
        guard !siblings.isEmpty else { return }
        for pane in panes {
            guard let terminal = pane.terminalContent else { continue }
            // SSH shells run on a remote host — a local worktree path is
            // meaningless there.
            if terminal is SSHPaneContent { continue }
            guard pane.runningProcessName == nil else { continue }
            guard let cwd = terminal.workingDirectory,
                  let base = siblings.first(where: { cwd == $0 || cwd.hasPrefix($0 + "/") }),
                  base != newRoot else { continue }
            let relative = cwd == base ? "" : String(cwd.dropFirst(base.count + 1))
            var target = relative.isEmpty ? newRoot : newRoot + "/" + relative
            if !FileManager.default.fileExists(atPath: target) {
                target = newRoot
            }
            SessionControl.send(text: "cd " + shellQuote(target), to: terminal, submit: true)
        }
    }

    // Check out a local branch in the shown repo, from the Files-tab footer's
    // worktree/branch switcher. Off-thread git; failures alerted; the status
    // monitor refresh repaints the footer and file badges.
    func checkoutBranch(root: String, branch: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = WorktreeTasks.runGit(root, ["checkout", branch])
            DispatchQueue.main.async {
                if case .failure(let error) = result {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Checkout Failed"
                    alert.informativeText = error.message
                    if let window = self?.window {
                        alert.beginSheetModal(for: window)
                    } else {
                        alert.runModal()
                    }
                }
                GitStatusMonitor.shared(forRoot: root).refresh()
            }
        }
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

    // Reveal the Bookmarks tab (palette).
    func showBookmarks() {
        if sidebar.isHidden {
            sidebar.isHidden = false
            layoutSidebarSplit()
            UserDefaults.standard.set(true, forKey: "sidebarVisible")
        }
        sidebar.select(tab: .bookmarks)
    }

    // Reveal the Git tab's Feedback inbox and refresh it (palette).
    func showFeedbackInbox() {
        showGit()
        sidebar.gitView.loadFeedbackData()
    }

    // The active window's gathered feedback events, for palette routing.
    func currentFeedbackEvents() -> [FeedbackEvent] {
        sidebar.gitView.feedbackEvents
    }

    // Reveal the Git tab's PR review inbox and refresh it (palette).
    func showPRReviewInbox() {
        showGit()
        sidebar.gitView.loadReviewInbox()
    }

    // Re-fetch the inbox after a review is submitted, so the row reflects it.
    func reloadPRInbox() {
        sidebar.gitView.loadReviewInbox()
    }
}
