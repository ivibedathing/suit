import Cocoa

// Branch / PR overview: loads the repo's local branches and layers
// gh PR badges on top, plus the per-branch context-menu actions (checkout /
// switch worktree, create PR, open on GitHub).
extension GitView {
    // MARK: - Branch / PR overview

    // Loads local branches (ahead/behind, worktree, dirty) off the main thread,
    // then — if `gh` is installed — layers PR badges on in a second pass so the
    // branch list never waits on the network.
    func loadBranchData() {
        guard let root = gitRoot else { return }
        let current = monitor?.currentBranch
        loadToken += 1
        let token = loadToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let list = GitBranchList.compute(root: root, currentBranch: current)
            DispatchQueue.main.async {
                guard let self, token == self.loadToken, root == self.gitRoot else { return }
                self.branches = list
                self.reload()
                // Conflicts need no gh, so gather feedback now; the PR pass
                // below refreshes it once CI/review data is available.
                self.loadFeedbackData()
                // The PR review inbox is its own gh pass.
                self.loadReviewInbox()
                self.loadPullRequests(root: root, token: token)
            }
        }
    }

    private func loadPullRequests(root: String, token: Int) {
        guard GitHubCLI.isAvailable else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let prs = GitHubCLI.pullRequests(root: root)
            guard !prs.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, token == self.loadToken, root == self.gitRoot else { return }
                self.prByBranch = prs
                self.reload()
                // Now that PRs are known, re-gather so CI failures and review
                // comments join the conflict events already shown.
                self.loadFeedbackData()
            }
        }
    }

    // Clicking a branch: switch to its worktree when it lives in one (git won't
    // check out a branch already claimed by another worktree), else check it
    // out in place. The current branch is a no-op.
    func activate(branch: GitBranchInfo) {
        guard !branch.isCurrent else { return }
        if let worktree = branch.worktreePath {
            onSwitchWorktree?(worktree)
        } else {
            checkout(branch: branch.name)
        }
    }

    // Per-branch gh actions. gh entries only appear when gh is
    // installed; without it, a disabled hint says so and Checkout still works.
    func buildBranchMenu(_ menu: NSMenu, branch: GitBranchInfo) {
        if !branch.isCurrent {
            let title = branch.worktreePath != nil ? "Switch to Worktree" : "Checkout"
            let item = menu.addItem(withTitle: title, action: #selector(activateBranchItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = branch.name
        }
        menu.addItem(.separator())
        if GitHubCLI.isAvailable {
            let createItem = menu.addItem(withTitle: "Create PR…", action: #selector(createPRItem(_:)), keyEquivalent: "")
            createItem.target = self
            createItem.representedObject = branch.name
            let openItem = menu.addItem(withTitle: "Open on GitHub", action: #selector(openOnGitHubItem(_:)), keyEquivalent: "")
            openItem.target = self
            openItem.representedObject = branch.name
        } else {
            menu.addItem(Self.headerItem("Install the gh CLI for PR actions"))
        }
        addDeleteItem(menu, branch: branch)
    }

    // Delete lands last and behind a separator — it's the one item here that
    // destroys something. Only the safe `-d`: an unmerged branch fails first
    // and the failure alert offers the force variant, so the warning appears
    // exactly when it's true (see TerminalWindowController+GitActions).
    //
    // A branch another worktree holds gets the item disabled rather than
    // hidden: git's refusal is the interesting fact, and silently dropping it
    // would read as "delete isn't a thing here". The current branch is the one
    // case worth hiding — the row already shows it's the one you're on.
    private func addDeleteItem(_ menu: NSMenu, branch: GitBranchInfo) {
        guard !branch.isCurrent else { return }
        menu.addItem(.separator())
        let item = menu.addItem(withTitle: "Delete Branch", action: #selector(deleteBranchItem(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = branch.name
        item.isEnabled = branch.isDeletable
        if let worktree = branch.worktreePath {
            item.toolTip = "“\(branch.name)” is checked out in \((worktree as NSString).abbreviatingWithTildeInPath)"
                + " — git won’t delete a branch a worktree holds."
        }
    }

    @objc private func deleteBranchItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        // Deleting a branch moves no file, so the status monitor may never fire
        // — reload the list off the action's own completion instead.
        run(.deleteBranch(name: name, force: false)) { [weak self] _ in
            self?.loadBranchData()
        }
    }

    @objc private func activateBranchItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let info = branches.first(where: { $0.name == name }) else { return }
        activate(branch: info)
    }

    @objc private func createPRItem(_ sender: NSMenuItem) {
        guard let branch = sender.representedObject as? String, let root = gitRoot else { return }
        // Title prefilled from the branch's last path component, dashes → spaces.
        let leaf = branch.split(separator: "/").last.map(String.init) ?? branch
        let suggested = leaf.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        OverlayPromptController.shared.ask(
            caption: "Create PR — title", text: suggested, placeholder: "Pull request title",
            over: window
        ) { [weak self] title in
            guard let self, !title.isEmpty else { return }
            self.runCreatePR(root: root, branch: branch, title: title)
        }
    }

    private func runCreatePR(root: String, branch: String, title: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let body = GitHubCLI.commitBody(root: root, branch: branch)
            let result = GitHubCLI.createPR(root: root, branch: branch, title: title, body: body)
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let url):
                    self.monitor?.refresh()
                    self.loadBranchData()
                    let alert = NSAlert()
                    alert.messageText = "Pull Request Created"
                    alert.informativeText = url.isEmpty ? "The PR was created." : url
                    if !url.isEmpty, let prURL = URL(string: url) {
                        alert.addButton(withTitle: "Open in Browser")
                        alert.addButton(withTitle: "Done")
                        if alert.runModal() == .alertFirstButtonReturn {
                            NSWorkspace.shared.open(prURL)
                        }
                    } else {
                        alert.runModal()
                    }
                case .failure(let error):
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Create PR Failed"
                    alert.informativeText = error.message
                    alert.runModal()
                }
            }
        }
    }

    @objc private func openOnGitHubItem(_ sender: NSMenuItem) {
        guard let branch = sender.representedObject as? String, let root = gitRoot else { return }
        GitHubCLI.openWeb(root: root, branch: branch, hasPR: prByBranch[branch] != nil)
    }
}
