import Cocoa

// The AppKit half of the Files-tab branch actions: it confirms, runs, and
// reports. Every decision about *what* a given action does — the argv, whether
// it needs a confirmation, what the failure alert is called — comes from the
// UI-free `GitBranchOps`, so this file stays a runner.
//
// Three things it does own, all of them about the surrounding app rather than
// about git:
//
//   * Nothing blocks the main thread. git can sit on the network for seconds
//     (fetch, pull, push), so the commands run on a background queue and only
//     the alerts come back to the main one.
//   * Refresh is explicit. `GitStatusMonitor` watches refs, so a checkout or a
//     pull would eventually repaint on its own, but the FSEvents debounce makes
//     that feel laggy right after a deliberate action — so the monitor (and,
//     for anything that rewrote files, the file index) is kicked directly.
//   * `git branch -d` refusing an unmerged branch is a question, not an error.
//     That one failure escalates into an offer to force-delete, which routes
//     back through the same runner and so picks up the force variant's own
//     "these commits become unreachable" confirmation.
extension TerminalWindowController {

    // MARK: - Running an action

    func runBranchAction(root: String, action: GitBranchOps.Action) {
        let plan = GitBranchOps.plan(for: action)
        guard confirm(plan.confirmation) else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: WorktreeTaskError?
            for arguments in plan.commands {
                if case .failure(let error) = WorktreeTasks.runGit(root, arguments) {
                    failure = error
                    break
                }
            }
            DispatchQueue.main.async {
                self?.finishBranchAction(root: root, action: action, plan: plan, failure: failure)
            }
        }
    }

    private func finishBranchAction(
        root: String, action: GitBranchOps.Action, plan: GitBranchOps.Plan, failure: WorktreeTaskError?
    ) {
        GitStatusMonitor.shared(forRoot: root).refresh()
        if plan.touchesWorkingTree {
            // Pull / stash / checkout can add and remove files wholesale;
            // FSEvents will catch up, but the tree should not lag the action
            // that the user just watched complete.
            FileIndex.shared(forExactDirectory: sidebar.fileBrowser.rootPath).rescan()
        }
        guard let failure else { return }

        // The one recoverable failure: -d refusing an unmerged branch. Offer
        // the force variant instead of dead-ending on git's suggestion.
        if case .deleteBranch(let name, force: false) = action, Self.isUnmergedRefusal(failure.message) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "“\(name)” isn’t fully merged"
            alert.informativeText = "Git won’t delete it with the safe delete because its commits aren’t on any other branch."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Delete Anyway…")
            presentAlert(alert) { [weak self] response in
                guard response == .alertSecondButtonReturn else { return }
                // One hop: the force variant's own confirmation is app-modal,
                // and presenting it from inside this sheet's completion handler
                // — while the sheet is still tearing down — is how a second
                // alert ends up behind the window.
                DispatchQueue.main.async {
                    self?.runBranchAction(root: root, action: .deleteBranch(name: name, force: true))
                }
            }
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = plan.failureTitle
        alert.informativeText = failure.message
        presentAlert(alert) { _ in }
    }

    // git's wording for the -d refusal has been stable for years, but match
    // loosely — a miss only costs the escalation shortcut, never correctness.
    private static func isUnmergedRefusal(_ message: String) -> Bool {
        message.lowercased().contains("not fully merged")
    }

    // MARK: - Confirmation

    // A destructive plan's confirm button gives up its Return equivalent, so
    // the dialog can only be accepted by clicking it — a reflexive Return does
    // nothing. Cancel keeps the Escape equivalent NSAlert hands any button
    // titled "Cancel"; overwriting it to make Return cancel would take Escape
    // away from the most dangerous dialog in the app, which is the worse trade.
    private func confirm(_ confirmation: GitBranchOps.Confirmation?) -> Bool {
        guard let confirmation else { return true }
        let alert = NSAlert()
        alert.alertStyle = confirmation.isDestructive ? .critical : .warning
        alert.messageText = confirmation.messageText
        alert.informativeText = confirmation.informativeText
        let confirmButton = alert.addButton(withTitle: confirmation.confirmButton)
        alert.addButton(withTitle: "Cancel")
        if confirmation.isDestructive {
            if #available(macOS 11.0, *) { confirmButton.hasDestructiveAction = true }
            confirmButton.keyEquivalent = ""
        }
        // Modal rather than a sheet: the caller needs the answer before it can
        // decide whether to spawn the work at all.
        return alert.runModal() == .alertFirstButtonReturn
    }

    // A sheet on the window that owns the sidebar the action came from.
    private func presentAlert(_ alert: NSAlert, then handle: @escaping (NSApplication.ModalResponse) -> Void) {
        alert.beginSheetModal(for: window, completionHandler: handle)
    }

    // MARK: - New branch

    // Prompts for a name on the overlay surface (the same prompt New File and
    // Create PR use), validates it against git's ref rules before spending a
    // process on it, then checks the new branch out.
    func promptForNewBranch(root: String) {
        OverlayPromptController.shared.ask(
            caption: "New Branch", placeholder: "feature/my-change", over: window
        ) { [weak self] raw in
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let self else { return }
            if let complaint = GitBranchOps.validateBranchName(name) {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Invalid branch name"
                alert.informativeText = complaint
                self.presentAlert(alert) { _ in }
                return
            }
            self.runBranchAction(root: root, action: .createBranch(name: name))
        }
    }
}
