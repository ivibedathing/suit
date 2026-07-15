import Cocoa

// Opening things as tabs in this window: files (deduped by path), the
// window-singleton panes (diff, transcript, commit graph, plan approval,
// references, checkpoint timeline) via reuseOrCreateTab, the "what changed
// since mark" catch-up diff, and go-to-definition / find-references. The
// Claude task/recipe/review launchers live in TerminalWindowController+Tasks.
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

    // Routes a file to its preview pane by extension:
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
    // draft that "Send Review to Session…" acts on.
    var currentDiffContent: DiffPaneContent? {
        store.tabs.first { $0.content is DiffPaneContent }?.content as? DiffPaneContent
    }

    // The reuse-or-create policy every window-singleton pane shares (diff,
    // transcript, commit graph, plan approval, references, checkpoint
    // timeline): reuse the window's existing tab of that content type, or
    // create one — then load and activate. One place to change the
    // focus/dedup behavior for all of them.
    @discardableResult
    func reuseOrCreateTab<Content: PaneContent>(_ create: @autoclosure () -> Content,
                                                load: (Content) -> Void) -> Content {
        if let tab = store.tabs.first(where: { $0.content is Content }),
           let existing = tab.content as? Content {
            load(existing)
            activate(tab)
            return existing
        }
        let content = create()
        let tab = Tab(content: content)
        store.insert(tab)
        load(content)
        activate(tab)
        return content
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
        reuseOrCreateTab(DiffPaneContent()) { $0.loadGitDiff(root: root) }
    }

    // The Git tab's file-scoped variant: the same diff tab, showing only one
    // changed file (staged and unstaged both, like the full HEAD diff).
    func openGitDiff(root: String, file: String) {
        let producer = {
            runProcess("/usr/bin/git", ["-C", root, "diff", "HEAD", "--", file]) ?? ""
        }
        let title = "diff: \((file as NSString).lastPathComponent)"
        reuseOrCreateTab(DiffPaneContent()) { content in
            content.loadDiffText(producer(), title: title, root: root, reload: producer)
        }
    }

    // Open a PR's diff for review: `gh pr diff <n>` into the
    // window's diff tab, tagged with the PR number so Submit Review knows where
    // to post. gh hits the network, so fetch off the main thread and show a
    // placeholder meanwhile; Refresh re-fetches via the stored producer.
    func openPRDiff(_ pr: PRReviewItem) {
        guard let root = sidebar.gitView.gitRoot else { NSSound.beep(); return }
        let number = pr.number
        let title = "PR #\(number)"
        let producer = { GitHubCLI.prDiff(root: root, number: number) }

        let content = reuseOrCreateTab(DiffPaneContent()) { _ in }
        content.reviewingPR = DiffPaneContent.ReviewingPR(number: number, root: root, title: pr.title)
        content.loadDiffText("Loading \(title)…", title: title, root: root, reload: producer)
        DispatchQueue.global(qos: .userInitiated).async {
            let diff = producer()
            DispatchQueue.main.async {
                // Only apply if the tab is still reviewing this PR (guards a
                // quick second click that repointed the one diff tab).
                guard content.reviewingPR?.number == number else { return }
                content.loadDiffText(diff, title: title, root: root, reload: producer)
            }
        }
    }

    // Opens (or reuses, same policy) the diff tab showing one commit's changes
    // to a single file (from a File History row or a clicked
    // blame sha). `git show --format=` prints just the per-file diff, no commit
    // header; it handles the root commit (whole-file addition) too.
    func openCommitDiff(root: String, file: String, sha: String) {
        let producer = {
            runProcess("/usr/bin/git", ["-C", root, "show", "--format=", sha, "--", file]) ?? ""
        }
        let title = "diff: \((file as NSString).lastPathComponent) @ \(sha.prefix(8))"
        reuseOrCreateTab(DiffPaneContent()) { content in
            content.loadDiffText(producer(), title: title, root: root, reload: producer)
        }
    }

    // Whole-commit diff: from a commit-graph node click.
    // `git show <sha>` prints the commit's header + full diff; reuses the
    // window's diff tab like the per-file variant.
    func openCommitDiff(root: String, sha: String) {
        let producer = {
            runProcess("/usr/bin/git", ["-C", root, "show", "--stat", "--patch", sha]) ?? ""
        }
        let title = "commit \(sha.prefix(8))"
        reuseOrCreateTab(DiffPaneContent()) { content in
            content.loadDiffText(producer(), title: title, root: root, reload: producer)
        }
    }

    // The commit-graph pane: one per window, reused like the
    // diff/transcript tabs (scan the store for the existing one). Opened from
    // the Git tab's button and the "Show Commit Graph" palette command.
    func openCommitGraph(root explicitRoot: String? = nil) {
        let root = explicitRoot ?? currentFileIndex().root
        guard FileIndex.gitRoot(of: root) != nil else { NSSound.beep(); return }
        reuseOrCreateTab(CommitGraphPaneContent()) { $0.load(root: root) }
    }

    // MARK: - "What changed while I was away" markers

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
    // openGitDiff) — the review machinery fed a multi-worktree set.
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

        reuseOrCreateTab(DiffPaneContent()) { content in
            content.loadDiffText(composed.diffText, title: title, root: mainRoot, reload: producer)
        }
    }

    // Opens (or reuses) the window's transcript tab showing a Claude session's
    // conversation.
    func openTranscript(for session: ClaudeSession) {
        reuseOrCreateTab(TranscriptPaneContent()) { $0.load(session: session) }
    }

    // Opens (or reuses) the window's plan-approval tab showing a Claude
    // session's proposed plan, reused like the transcript.
    func openPlanApproval(for session: ClaudeSession) {
        reuseOrCreateTab(PlanApprovalPaneContent()) { $0.load(session: session) }
    }

    // Opens (or reuses) the window's checkpoint-timeline tab showing a Claude
    // session's change history, reused like the transcript.
    func openCheckpointTimeline(for session: ClaudeSession) {
        reuseOrCreateTab(CheckpointTimelinePaneContent()) { $0.load(session: session) }
    }

    // Opens (or reuses) the window's background-task monitor tab,
    // scoped to a shell's process subtree — the background jobs
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
    // file — how cross-transcript search jumps to a historical
    // session, anchoring the pane on the matching line.
    func openTranscript(path: String, cwd: String?, title: String, line: Int?) {
        let content = reuseOrCreateTab(TranscriptPaneContent()) {
            $0.load(path: path, cwd: cwd, title: title)
        }
        // Defer the jump one turn so the pane has laid out (scrollRangeToVisible
        // needs a real frame after activate).
        if let line {
            DispatchQueue.main.async { content.jump(toSourceLine: line) }
        }
    }

    // MARK: - Go to definition / find references

    // Resolves `symbol` to its definition(s) via the project's SymbolIndex and
    // navigates: exactly one jumps straight there; several open the palette
    // picker; none (or no ctags at all) fall back to the references pane's rg
    // word search, which still surfaces the definition among the uses — with a
    // header note explaining the fallback.
    func goToDefinition(symbol: String, fromDirectory directory: String?) {
        let base = directory ?? currentFileIndex().root
        let root = FileIndex.gitRoot(of: base) ?? base
        let definitions = SymbolIndex.shared(forDirectory: root).definitions(for: symbol)
        switch definitions.count {
        case 1:
            let def = definitions[0]
            openFile(atPath: root + "/" + def.relativePath, line: def.lineNumber)
        case 0:
            let note = SymbolIndex.hasCtags
                ? "No indexed definition for “\(symbol)” — showing every use."
                : "ctags not found — showing every use (rebuild the app or set SUIT_CTAGS_PATH)."
            openReferences(symbol: symbol, root: root, fallbackNote: note)
        default:
            appDelegate.showDefinitionPicker(symbol: symbol, definitions: definitions, root: root, controller: self)
        }
    }

    // Jumps to one specific definition — the palette picker's action for the
    // multi-definition case.
    func openDefinition(_ definition: SymbolDefinition, root: String) {
        openFile(atPath: root + "/" + definition.relativePath, line: definition.lineNumber)
    }

    // Opens (or reuses) the window's references pane for `symbol`. A missing
    // ctags binary just means the list is unqualified — the rg word search runs
    // the same way — so a note is passed through to the header.
    func findReferences(symbol: String, fromDirectory directory: String?) {
        let base = directory ?? currentFileIndex().root
        let root = FileIndex.gitRoot(of: base) ?? base
        let note = SymbolIndex.hasCtags
            ? nil
            : "ctags not found — this is an rg word search (rebuild the app or set SUIT_CTAGS_PATH)."
        openReferences(symbol: symbol, root: root, fallbackNote: note)
    }

    // The references pane itself, reused like the diff / transcript panes.
    func openReferences(symbol: String, root: String, fallbackNote: String? = nil) {
        reuseOrCreateTab(ReferencesPaneContent()) {
            $0.load(symbol: symbol, root: root, fallbackNote: fallbackNote)
        }
    }
}
