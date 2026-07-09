import Cocoa

// The header's worktree/branch switcher dropdown: repoints the sidebar between
// the repo's worktrees, checks out local branches, and — inside a task
// worktree — finishes the task (merge or discard).
extension GitView {
    // MARK: - Worktree / branch switcher

    @objc func openSwitcherMenu() {
        guard let root = gitRoot else { return }
        let menu = NSMenu()

        menu.addItem(Self.headerItem("Worktrees"))
        for worktree in WorktreeSwitcher.worktrees(root: root) {
            let name = (worktree.path as NSString).lastPathComponent
            let item = menu.addItem(
                withTitle: "\(name) — \(worktree.branch ?? "detached")",
                action: #selector(switchWorktreeItem(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = worktree.path
            item.state = worktree.path == root ? .on : .off
            item.toolTip = worktree.path
            item.indentationLevel = 1
        }

        menu.addItem(.separator())
        menu.addItem(Self.headerItem("Branches"))
        let current = monitor?.currentBranch
        for branch in WorktreeSwitcher.branches(root: root) {
            let item = menu.addItem(withTitle: branch, action: #selector(checkoutBranchItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = branch
            item.state = branch == current ? .on : .off
            item.indentationLevel = 1
        }

        if WorktreeTasks.isTaskWorktree(root) {
            menu.addItem(.separator())
            let mergeItem = menu.addItem(withTitle: "Finish Task: Merge & Remove", action: #selector(finishTaskMerge), keyEquivalent: "")
            mergeItem.target = self
            let discardItem = menu.addItem(withTitle: "Finish Task: Discard & Remove", action: #selector(finishTaskDiscard), keyEquivalent: "")
            discardItem.target = self
        }

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: branchButton.frame.minX, y: branchButton.frame.minY - 2),
            in: self
        )
    }

    static func headerItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func switchWorktreeItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, path != gitRoot else { return }
        onSwitchWorktree?(path)
    }

    @objc private func checkoutBranchItem(_ sender: NSMenuItem) {
        guard let branch = sender.representedObject as? String, branch != monitor?.currentBranch else { return }
        checkout(branch: branch)
    }

    func checkout(branch: String) {
        guard let root = gitRoot else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = WorktreeTasks.runGit(root, ["checkout", branch])
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure(let error) = result {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Checkout Failed"
                    alert.informativeText = error.message
                    alert.runModal()
                }
                self.monitor?.refresh()
            }
        }
    }

    @objc private func finishTaskMerge() {
        confirmFinishTask(merge: true)
    }

    @objc private func finishTaskDiscard() {
        confirmFinishTask(merge: false)
    }

    // The dropdown twin of the pane header's "Finish Claude Task…": merge (or
    // drop) the task branch, remove the worktree, and hand the sidebar back to
    // the main checkout.
    private func confirmFinishTask(merge: Bool) {
        guard let root = gitRoot else { return }
        let branch = WorktreeTasks.currentBranch(root) ?? "the task branch"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = merge ? "Merge & Remove Task Worktree?" : "Discard & Remove Task Worktree?"
        alert.informativeText = merge
            ? "Merges \(branch) into the main checkout's current branch, then removes the worktree and branch."
            : "Removes the worktree and deletes \(branch) without merging. Uncommitted work is lost."
        let confirm = alert.addButton(withTitle: merge ? "Merge & Remove" : "Discard & Remove")
        if !merge {
            confirm.hasDestructiveAction = true
        }
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Resolved before finish() removes the worktree out from under us.
        let mainRoot = WorktreeTasks.mainRoot(ofWorktree: root)
        if let error = WorktreeTasks.finish(worktreePath: root, merge: merge) {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = "Finish Claude Task"
            failure.informativeText = error
            failure.runModal()
            return
        }
        if let mainRoot {
            onTaskFinished?(mainRoot)
        }
    }
}
