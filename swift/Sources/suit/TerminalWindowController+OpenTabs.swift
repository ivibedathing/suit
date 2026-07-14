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

    // Open a PR's diff for review: `gh pr diff <n>` into the
    // window's diff tab, tagged with the PR number so Submit Review knows where
    // to post. gh hits the network, so fetch off the main thread and show a
    // placeholder meanwhile; Refresh re-fetches via the stored producer.
    func openPRDiff(_ pr: PRReviewItem) {
        guard let root = sidebar.gitView.gitRoot else { NSSound.beep(); return }
        let number = pr.number
        let title = "PR #\(number)"
        let producer = { GitHubCLI.prDiff(root: root, number: number) }

        let content: DiffPaneContent
        if let tab = store.tabs.first(where: { $0.content is DiffPaneContent }),
           let existing = tab.content as? DiffPaneContent {
            content = existing
            activate(tab)
        } else {
            content = DiffPaneContent()
            let tab = Tab(content: content)
            store.insert(tab)
            activate(tab)
        }
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

    // Whole-commit diff: from a commit-graph node click.
    // `git show <sha>` prints the commit's header + full diff; reuses the
    // window's diff tab like the per-file variant.
    func openCommitDiff(root: String, sha: String) {
        let producer = {
            runProcess("/usr/bin/git", ["-C", root, "show", "--stat", "--patch", sha]) ?? ""
        }
        let title = "commit \(sha.prefix(8))"
        let load = { (content: DiffPaneContent) in
            content.loadDiffText(producer(), title: title, root: root, reload: producer)
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

    // The commit-graph pane: one per window, reused like the
    // diff/transcript tabs (scan the store for the existing one). Opened from
    // the Git tab's button and the "Show Commit Graph" palette command.
    func openCommitGraph(root explicitRoot: String? = nil) {
        let root = explicitRoot ?? currentFileIndex().root
        guard FileIndex.gitRoot(of: root) != nil else { NSSound.beep(); return }
        if let tab = store.tabs.first(where: { $0.content is CommitGraphPaneContent }) {
            (tab.content as? CommitGraphPaneContent)?.load(root: root)
            activate(tab)
            return
        }
        let content = CommitGraphPaneContent()
        let tab = Tab(content: content)
        store.insert(tab)
        content.load(root: root)
        activate(tab)
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
    // conversation.
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
    // session's proposed plan, reused like the transcript.
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
    // session's change history, reused like the transcript.
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
        if let tab = store.tabs.first(where: { $0.content is ReferencesPaneContent }) {
            (tab.content as? ReferencesPaneContent)?.load(symbol: symbol, root: root, fallbackNote: fallbackNote)
            activate(tab)
            return
        }
        let content = ReferencesPaneContent()
        let tab = Tab(content: content)
        store.insert(tab)
        content.load(symbol: symbol, root: root, fallbackNote: fallbackNote)
        activate(tab)
    }

    // MARK: - Claude task worktrees

    // "New task": a tab running claude, tagged with the task name (originally
    // one keystroke). Isolation is now a per-task choice —
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
        // The pty input queue holds this until zsh is ready to read it. The
        // Claude API pane's env overrides prefix the command (session-scoped).
        let command = appDelegate.claudeAPI.launchCommand(base: "claude")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak content] in
            content?.terminalView.send(txt: command + "\r")
        }
    }

    // Session task recipe: the startClaudeTask recipe plus a
    // parameterized prompt. Spins the worktree (or current checkout, honoring
    // the isolation choice), opens the `claude` tab, and — once its TUI
    // is up — sends the already-substituted recipe prompt (the startReviewPass
    // fixed-delay approach; this is a manual, interactive launcher, not the
    // Autopilot session-file handshake).
    func startRecipeTask(named name: String, promptText: String, isolate: Bool = true) {
        let root = currentFileIndex().root
        let directory: String
        if TaskLaunch.usesWorktree(isolate: isolate) {
            switch WorktreeTasks.createTask(projectRoot: root, name: name) {
            case .failure(let error):
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Recipe Task"
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
        let recipeCommand = appDelegate.claudeAPI.launchCommand(base: "claude")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak content] in
            content?.terminalView.send(txt: recipeCommand + "\r")
        }
        let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak content] in
            guard let content else { return }
            SessionControl.send(text: trimmed, to: content, submit: true, submitDelay: 0.5)
        }
    }

    // The <FILE> / <SELECTION> a recipe fills from the focused pane: the viewer's
    // open file + selected text, or a terminal's selection. Empty when there's
    // no such context (the placeholders then collapse to nothing).
    func recipeContext() -> (file: String, selection: String) {
        guard let content = focusedPane()?.content else { return ("", "") }
        if let viewer = content as? FileViewerPaneContent {
            let range = viewer.textView.selectedRange()
            let selection = range.length > 0 ? (viewer.textView.string as NSString).substring(with: range) : ""
            return (viewer.filePath ?? "", selection)
        }
        if let terminal = content as? TerminalPaneContent {
            return ("", terminal.terminalView.getSelection() ?? "")
        }
        return ("", "")
    }

    // Reviewer-agent lane (optional): open a fresh claude in
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
        let reviewCommand = appDelegate.claudeAPI.launchCommand(base: "claude")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak content] in
            content?.terminalView.send(txt: reviewCommand + "\r")
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

    // Autopilot cleanup: a merged run's worker
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

    // Autopilot run tab (launch stage): the
    // startClaudeTask recipe minus worktree creation — the engine already made
    // the worktree. Inserted WITHOUT stealing focus (attention is signaled via
    // the strip/footer, never forced); only a window with no tab at all
    // activates it, since there is nothing to steal focus from then.
    // `continueSession` is the §2.7 watchdog respawn: `claude --continue`
    // resumes the dead worker's conversation. `model`/`effort` are the
    // phase's routing annotations (ROADMAP.md "model:"/"effort:" body lines,
    // snapshotted on the run): they prefix the command with ANTHROPIC_MODEL /
    // CLAUDE_CODE_EFFORT_LEVEL so a mechanical phase can run on a cheaper
    // tier. Deliberately independent of the Settings ▸ Claude API prefix —
    // autonomous runs must not silently inherit interactive experiments
    // (see ClaudeAPISettings); the roadmap annotation is the explicit opt-in.
    @discardableResult
    func openAutopilotRunTab(directory: String, title: String, continueSession: Bool = false,
                             model: String? = nil, effort: String? = nil) -> Tab {
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
        var envPrefix = ""
        if let model = model.map(ClaudeAPISettings.sanitize), !model.isEmpty {
            envPrefix += "ANTHROPIC_MODEL=\(ClaudeAPISettings.shellQuote(model)) "
        }
        if let effort = effort.map(ClaudeAPISettings.sanitize), !effort.isEmpty {
            envPrefix += "CLAUDE_CODE_EFFORT_LEVEL=\(ClaudeAPISettings.shellQuote(effort)) "
        }
        command = envPrefix + command
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
