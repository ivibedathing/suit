import Cocoa

extension DiffPaneContent {
    // MARK: - Loading

    // Shows the working tree's uncommitted changes (vs HEAD, so staged and
    // unstaged both appear) for the repo at `root`.
    func loadGitDiff(root: String) {
        gitRoot = root
        let producer = {
            runProcess("/usr/bin/git", ["-C", root, "diff", "HEAD"]) ?? ""
        }
        reload = producer
        setDiff(producer(), status: (root as NSString).lastPathComponent)
        tab?.contentTitleDidChange("diff: \((root as NSString).lastPathComponent)")
    }

    // Feeds an arbitrary diff (Phase 5 review sets use this).
    func loadDiffText(_ diff: String, title: String, root: String?, reload: (() -> String)? = nil) {
        gitRoot = root
        self.reload = reload
        setDiff(diff, status: title)
        tab?.contentTitleDidChange(title)
    }

    @objc func refresh(_ sender: Any?) {
        guard let reload else { return }
        setDiff(reload(), status: statusLabel.stringValue.replacingOccurrences(of: " — refreshed", with: ""))
    }

    private func setDiff(_ diff: String, status: String) {
        diffLines = diff.isEmpty ? [] : UnifiedDiffParser.parse(diff)
        changedFilePaths = UnifiedDiffParser.changedPaths(diff)
        if diffLines.isEmpty {
            statusLabel.stringValue = "\(status) — no changes"
        } else {
            let files = changedFilePaths.count
            statusLabel.stringValue = "\(status) — \(files) file\(files == 1 ? "" : "s") · n/p walk, o open, c comment"
        }
        render()
        updateReviewButton()
    }

    // Reflects the draft's comment count into the header button (hidden when
    // empty), then relays out so the status field reclaims the freed width.
    private func updateReviewButton() {
        let count = reviewDraft.count
        reviewButton.isHidden = count == 0
        reviewButton.title = "Review (\(count))"
        layoutContents()
    }

    // Re-run after any draft mutation from outside (a send that cleared it).
    func reviewChanged() {
        render()
        updateReviewButton()
    }

    // Loads comments restored from a SavedTab into the draft (ROADMAP Phase 16).
    func restoreComments(_ comments: [DiffReviewComment]?) {
        guard let comments, !comments.isEmpty else { return }
        for c in comments {
            reviewDraft.set(text: c.text, file: c.file, side: c.side, line: c.line, lineText: c.lineText)
        }
        reviewChanged()
    }

    // The human-readable name of what's under review, for the prompt header.
    var reviewRef: String {
        if let gitRoot { return (gitRoot as NSString).lastPathComponent }
        return statusLabel.stringValue.components(separatedBy: " — ").first ?? "these changes"
    }

    @objc func modeChanged(_ sender: Any?) {
        updateModeVisibility()
        if let window = containerView.window, window.firstResponder === unifiedText || window.firstResponder === leftText {
            window.makeFirstResponder(focusTarget)
        }
    }

    func updateModeVisibility() {
        let unified = modePicker.selectedSegment == 0
        unifiedScroll.isHidden = !unified
        leftScroll.isHidden = unified
        rightScroll.isHidden = unified
    }
}
