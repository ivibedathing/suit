import Cocoa

extension TerminalWindowController {

    // MARK: - Opening file / diff / transcript tabs

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

    // MARK: - "What changed while I was away" markers (ROADMAP Phase 24)

    // Drops a per-repo checkpoint: every worktree's HEAD sha + a timestamp,
    // into markers.json. Silent by design — the Git tab's marker button fills
    // and its tooltip/menu reflect the new mark (no toast system in the app).
    func markAwayPoint(root explicitRoot: String? = nil) {
        let root = explicitRoot ?? currentFileIndex().root
        guard let mainRoot = MarkerCatchUp.mainRoot(root) else {
            NSSound.beep()
            return
        }
        MarkerStore.shared.setMarker(MarkerCatchUp.mark(mainRoot: mainRoot), forRepo: mainRoot)
    }

    // "What Changed Since Mark": composes the aggregate diff across every
    // worktree since the mark into the window's diff tab (reused like
    // openGitDiff) — the Phase 5 review machinery fed a multi-worktree set.
    func openCatchUpDiff(root explicitRoot: String? = nil) {
        let root = explicitRoot ?? currentFileIndex().root
        guard let mainRoot = MarkerCatchUp.mainRoot(root) else {
            NSSound.beep()
            return
        }
        guard let marker = MarkerStore.shared.marker(forRepo: mainRoot) else {
            let alert = NSAlert()
            alert.messageText = "No marker set"
            alert.informativeText = "Use “Mark Now” first to record a checkpoint, then come back to see everything that changed across the repo's worktrees since."
            alert.runModal()
            return
        }

        // Which Claude session (by cwd match) is working in each worktree —
        // resolved fresh on every compose so a Refresh re-attributes.
        let sessionForPath: (String) -> String? = { path in
            let match = ClaudeSessionMonitor.shared.sessions.first {
                guard let cwd = $0.cwd else { return false }
                return cwd == path || cwd.hasPrefix(path + "/")
            }
            guard let match else { return nil }
            return "\(match.displayName) • \(match.state.label)"
        }

        let producer: () -> String = {
            MarkerCatchUp.compose(mainRoot: mainRoot, marker: marker, sessionForPath: sessionForPath).diffText
        }
        let composed = MarkerCatchUp.compose(mainRoot: mainRoot, marker: marker, sessionForPath: sessionForPath)
        let title = "Since \(MarkerCatchUp.shortTime(marker.at)) · \(MarkerCatchUp.fileCount(composed.totalFiles)) +\(composed.totalInsertions) \u{2212}\(composed.totalDeletions)"

        let load = { (content: DiffPaneContent) in
            content.loadDiffText(composed.diffText, title: title, root: mainRoot, reload: producer)
        }
        if let tab = store.tabs.first(where: { $0.content is DiffPaneContent }) {
            if let content = tab.content as? DiffPaneContent { load(content) }
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

    // Opens (or reuses) the window's plan-approval tab showing a Claude
    // session's proposed plan (ROADMAP Phase 26), reused like the transcript.
    func openPlanApproval(for session: ClaudeSession) {
        if let tab = store.tabs.first(where: { $0.content is PlanApprovalPaneContent }) {
            (tab.content as? PlanApprovalPaneContent)?.load(session: session)
            activate(tab)
            return
        }
        let content = PlanApprovalPaneContent()
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

    // Opens (or reuses) the window's background-task monitor tab (ROADMAP
    // Phase 30), scoped to a shell's process subtree — the background jobs
    // launched from that pane's terminal. A shellPid of 0 shows every tracked
    // task (the window-wide fallback when no terminal pane is focused). Reused
    // like the transcript pane; the monitor pane is bound to its shell at
    // creation, so a re-open for a different shell replaces the tab's content.
    func openBackgroundTasks(forShellPid shellPid: Int32, title: String) {
        if let tab = store.tabs.first(where: { $0.content is BackgroundTaskPaneContent }) {
            let existing = tab.content as? BackgroundTaskPaneContent
            // Same shell → just re-activate; different shell → swap in a fresh
            // monitor bound to the new shell (the pane can't rebind live).
            if existing?.rootShellPid == shellPid {
                activate(tab)
                return
            }
            forceCloseTab(tab)
        }
        let content = BackgroundTaskPaneContent(shellPid: shellPid, title: title)
        let tab = Tab(content: content)
        store.insert(tab)
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

    // MARK: - Symbol navigation (ROADMAP Phase 33)

    // The git root a symbol lookup runs against: the clicked file's repo when we
    // have one, else the window's current project root — so references stay
    // repo-scoped like project search.
    private func symbolRoot(forFile path: String?) -> String {
        if let path {
            let directory = (path as NSString).deletingLastPathComponent
            if let root = FileIndex.gitRoot(of: directory) { return root }
        }
        return currentFileIndex().root
    }

    // Go to definition: resolve the identifier to its ctags definition(s) and
    // jump. One definition jumps straight there; several open a palette picker
    // (an overloaded/shadowed name never silently jumps to the wrong site); none
    // — including when ctags isn't installed — degrades to the references pane's
    // rg word search with a header note.
    func goToDefinition(identifier: String, fromFile path: String?) {
        let symbol = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !symbol.isEmpty else { NSSound.beep(); return }
        let root = symbolRoot(forFile: path)
        let index = SymbolIndex.shared(forRoot: root)
        index.definitions(named: symbol, files: { FileIndex.shared(forDirectory: root).files }) { [weak self] defs, available in
            guard let self else { return }
            switch SymbolNavigation.gotoOutcome(for: defs) {
            case .jump(let symbol):
                self.openFile(atPath: root + "/" + symbol.relativePath, line: symbol.line)
            case .choose(let defs):
                self.appDelegate.presentDefinitionPicker(defs, root: root, controller: self)
            case .none:
                self.openReferences(symbol: symbol, root: root, ctagsAvailable: available)
            }
        }
    }

    // Find references: open the references pane (rg whole-word search of the
    // identifier), noting whether ctags backed the lookup.
    func findReferences(identifier: String, fromFile path: String?) {
        let symbol = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !symbol.isEmpty else { NSSound.beep(); return }
        let root = symbolRoot(forFile: path)
        let index = SymbolIndex.shared(forRoot: root)
        // Kick the index build (warms go-to-def, sets isCtagsAvailable) and open
        // the pane once we know whether ctags ran, so the header note is right.
        index.definitions(named: symbol, files: { FileIndex.shared(forDirectory: root).files }) { [weak self] _, available in
            self?.openReferences(symbol: symbol, root: root, ctagsAvailable: available)
        }
    }

    // Opens (or reuses, same policy as the diff/transcript panes) the window's
    // references tab listing every use of a symbol.
    func openReferences(symbol: String, root: String, ctagsAvailable: Bool) {
        let load = { (content: ReferencesPaneContent) in
            content.onOpenMatch = { [weak self] path, line in
                self?.openFile(atPath: path, line: line)
            }
            content.load(symbol: symbol, root: root, ctagsAvailable: ctagsAvailable)
        }
        if let tab = store.tabs.first(where: { $0.content is ReferencesPaneContent }) {
            if let content = tab.content as? ReferencesPaneContent { load(content) }
            activate(tab)
            return
        }
        let content = ReferencesPaneContent()
        let tab = Tab(content: content)
        store.insert(tab)
        load(content)
        activate(tab)
    }

    // MARK: - Claude task worktrees (ROADMAP Phase 5)

    // "New task": a tab running claude, tagged with the task name (ROADMAP
    // Phase 5 as one keystroke). Phase 31 makes isolation a per-task choice —
    // `isolate` on spins a dedicated worktree + branch (the original
    // behavior); off runs claude straight in the current checkout, for cheap
    // tasks that don't want the worktree churn.
    func startClaudeTask(named name: String, isolate: Bool = true) {
        let root = currentFileIndex().root
        let directory: String
        if TaskLaunch.usesWorktree(isolate: isolate) {
            switch WorktreeTasks.createTask(projectRoot: root, name: name) {
            case .failure(let error):
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "New Claude Task"
                alert.informativeText = error.message
                alert.runModal()
                return
            case .success(let worktree):
                directory = TaskLaunch.checkoutDirectory(isolate: isolate, currentRoot: root, worktreeDirectory: worktree)
            }
        } else {
            directory = TaskLaunch.checkoutDirectory(isolate: isolate, currentRoot: root, worktreeDirectory: nil)
        }
        let content = TerminalPaneContent()
        let tab = Tab(content: content)
        tab.customTitle = name
        store.insert(tab)
        content.start(in: directory)
        activate(tab)
        // The pty input queue holds this until zsh is ready to read it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak content] in
            content?.terminalView.send(txt: "claude\r")
        }
    }

    // ROADMAP Phase 29 (reviewer-agent lane, optional): open a fresh claude in
    // the feedback event's worktree, primed to review the branch's changes with
    // the machine feedback as context — a dedicated review pass alongside the
    // working session. The instruction is sent after a beat, once claude's TUI
    // is up (the composer's fixed-delay approach, not Autopilot's session-file
    // handshake — this is a one-off manual action, not an autonomous loop).
    func startReviewPass(for event: FeedbackEvent) {
        let directory = event.worktreePath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            NSSound.beep()
            return
        }
        let content = TerminalPaneContent()
        let tab = Tab(content: content)
        let label = event.branch.map { ($0 as NSString).lastPathComponent } ?? (directory as NSString).lastPathComponent
        tab.customTitle = "Review — \(label)"
        store.insert(tab)
        content.start(in: directory)
        activate(tab)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak content] in
            content?.terminalView.send(txt: "claude\r")
        }
        let prompt = FeedbackRouting.reviewPassPrompt(for: event)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak content] in
            guard let content else { return }
            SessionControl.send(text: prompt, to: content, submit: true, submitDelay: 0.5)
        }
    }

    // A task tab finished (worktree merged/discarded and removed): close it
    // without the usual running-process confirmation — the user just confirmed
    // the whole task's fate in the finish dialog.
    func paneFinishedTask(_ pane: Pane) {
        forceCloseTab(pane.tab)
    }

    // Autopilot cleanup (ROADMAP Phase 32, §2.8 item 4): a merged run's worker
    // tab closes without the running-process confirmation — the merge already
    // decided the run's fate (the paneFinishedTask trust, but tab-addressed:
    // the worker tab is usually backgrounded with no pane).
    func closeAutopilotRunTab(_ tab: Tab) {
        guard store.tab(withId: tab.id) != nil else { return }
        // The run tab as the window's only tab (torn off into its own window,
        // or every other tab closed overnight): forceCloseTab's count==1
        // branch would close the window — quitting the app when it's the last
        // one — killing the Autopilot loop mid-sequence. Open a replacement
        // shell tab first so the window (and the loop) survives; the pane's
        // MRU fallback then displays it.
        if store.tabs.count == 1 {
            let content = TerminalPaneContent()
            let replacement = Tab(content: content)
            store.insert(replacement)
            let root = appDelegate.autopilotProjectRoot
            content.start(in: root.isEmpty ? NSHomeDirectory() : root)
        }
        forceCloseTab(tab)
    }

    // Autopilot run tab (ROADMAP Phase 32, §2.5 launch stage): the
    // startClaudeTask recipe minus worktree creation — the engine already made
    // the worktree. Inserted WITHOUT stealing focus (attention is signaled via
    // the strip/footer, never forced); only a window with no tab at all
    // activates it, since there is nothing to steal focus from then.
    // `continueSession` is the §2.7 watchdog respawn: `claude --continue`
    // resumes the dead worker's conversation.
    @discardableResult
    func openAutopilotRunTab(directory: String, title: String, continueSession: Bool = false) -> Tab {
        let wasEmpty = store.tabs.isEmpty
        let content = TerminalPaneContent()
        let tab = Tab(content: content)
        tab.customTitle = title
        // MRU tail, not head: a background-spawned run must not hijack the
        // ⌃Tab quick-toggle or become the ⌘W close-tab fallback (keystrokes
        // would land in the autonomous worker's input box).
        store.insert(tab, background: true)
        content.start(in: directory)
        if wasEmpty {
            activate(tab)
        }
        reloadStrip(animated: true)
        // One short line typed into zsh; the multi-KB instructions arrive
        // separately once the session file appears (§2.5 two-stage delivery,
        // which avoids every shell-quoting hazard). The extra args are kept
        // newline-free by the settings setter; strip again defensively — a
        // stray newline here would submit a truncated command line.
        var command = "claude --dangerously-skip-permissions"
        if continueSession { command += " --continue" }
        let extraArgs = appDelegate.autopilotExtraArgs
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if !extraArgs.isEmpty { command += " " + extraArgs }
        // The pty input queue holds this until zsh is ready to read it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak content] in
            content?.terminalView.send(txt: command + "\n")
        }
        return tab
    }
}
