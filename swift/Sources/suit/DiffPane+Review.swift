import Cocoa

extension DiffPaneContent {
    // MARK: - Review walking (n/p/o)

    private var activeTextView: DiffTextView {
        modePicker.selectedSegment == 0 ? unifiedText : leftText
    }

    private var activeAnchors: [Int] {
        modePicker.selectedSegment == 0 ? unifiedAnchors : sideAnchors
    }

    // The file whose header is at or above the top of the visible text.
    private func currentFileIndex() -> Int {
        let anchors = activeAnchors
        guard !anchors.isEmpty, let layoutManager = activeTextView.layoutManager,
              let container = activeTextView.textContainer else { return 0 }
        let glyphRange = layoutManager.glyphRange(forBoundingRect: activeTextView.visibleRect, in: container)
        let topChar = layoutManager.characterIndexForGlyph(at: glyphRange.location)
        var index = 0
        for (i, anchor) in anchors.enumerated() where anchor <= topChar + 1 {
            index = i
        }
        return index
    }

    func navigateFiles(_ direction: Int) {
        let anchors = activeAnchors
        guard !anchors.isEmpty else { return }
        let target = max(0, min(anchors.count - 1, currentFileIndex() + direction))
        scrollToAnchor(anchors[target])
    }

    private func scrollToAnchor(_ location: Int) {
        let textView = activeTextView
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer,
              location < (textView.string as NSString).length else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        // Header to the top of the view, not merely "visible".
        let point = NSPoint(x: 0, y: max(0, rect.minY - 4))
        textView.enclosingScrollView?.contentView.scroll(to: point)
        textView.enclosingScrollView.map { $0.reflectScrolledClipView($0.contentView) }

        // Flash the header line so the eye lands with the jump.
        let ns = textView.string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
        layoutManager.addTemporaryAttribute(.backgroundColor, value: Theme.accent.withAlphaComponent(0.3), forCharacterRange: lineRange)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak layoutManager] in
            layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: lineRange)
        }
    }

    // `o`: open the file under review in the viewer pane, via the same route
    // terminal path-links take.
    func openCurrentFile() {
        guard !changedFilePaths.isEmpty, let gitRoot else { return }
        let path = changedFilePaths[min(currentFileIndex(), changedFilePaths.count - 1)]
        pane?.openFileLink(path: gitRoot + "/" + path, line: nil)
    }

    // MARK: - Review comments (ROADMAP Phase 16)

    // `c`: comment on the diff line at the caret. Commenting happens in the
    // unified view (its line map is what we hit-test); side-by-side flips over.
    func addCommentAtCaret() {
        if modePicker.selectedSegment != 0 {
            modePicker.selectedSegment = 0
            modeChanged(nil)
        }
        let caret = unifiedText.selectedRange().location
        // The line whose range contains the caret, else the nearest one above it.
        guard let ref = unifiedLineRefs.first(where: { NSLocationInRange(caret, $0.range) })
            ?? unifiedLineRefs.last(where: { $0.range.location <= caret }) else {
            NSSound.beep()
            return
        }
        promptComment(for: ref.file, side: ref.side, line: ref.line, lineText: ref.text)
    }

    private func promptComment(for file: String, side: DiffReviewComment.Side, line: Int, lineText: String) {
        let existing = reviewDraft.comment(file: file, side: side, line: line)?.text ?? ""
        OverlayPromptController.shared.ask(
            caption: "Comment · \((file as NSString).lastPathComponent):\(line)",
            text: existing,
            placeholder: "Review comment (empty deletes)…",
            over: containerView.window
        ) { [weak self] value in
            guard let self else { return }
            self.reviewDraft.set(text: value, file: file, side: side, line: line, lineText: lineText)
            self.reviewChanged()
        }
    }

    // The review inspector: the whole draft, each comment editable / deletable /
    // openable, plus Send to Session and Clear.
    @objc func showReviewMenu(_ sender: NSButton) {
        let menu = NSMenu()

        let send = menu.addItem(withTitle: "Send Review to Session…", action: #selector(sendReview), keyEquivalent: "")
        send.target = self
        send.isEnabled = !reviewDraft.isEmpty

        // Submit straight to GitHub when this diff is a PR under review (Phase 39).
        if reviewingPR != nil {
            let submit = menu.addItem(withTitle: "Submit as PR Review…", action: #selector(submitPRReview), keyEquivalent: "")
            submit.target = self
        }

        let clear = menu.addItem(withTitle: "Clear Review", action: #selector(clearReview), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !reviewDraft.isEmpty

        if !reviewDraft.isEmpty {
            menu.addItem(.separator())
            for comment in reviewDraft.comments {
                let head = "\((comment.file as NSString).lastPathComponent):\(comment.line) — \(comment.text)"
                let item = menu.addItem(withTitle: head.count > 64 ? String(head.prefix(63)) + "…" : head, action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for (title, action) in [("Edit…", #selector(editComment(_:))), ("Open File", #selector(openCommentFile(_:))), ("Delete", #selector(deleteComment(_:)))] {
                    let entry = sub.addItem(withTitle: title, action: action, keyEquivalent: "")
                    entry.target = self
                    entry.representedObject = comment
                }
                item.submenu = sub
            }
        }

        let origin = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: nil, at: origin, in: sender)
    }

    @objc private func sendReview() {
        (NSApp.delegate as? AppDelegate)?.sendReview(from: self)
    }

    @objc private func submitPRReview() {
        (NSApp.delegate as? AppDelegate)?.submitPRReview(from: self)
    }

    @objc private func clearReview() {
        reviewDraft.clear()
        reviewChanged()
    }

    @objc private func editComment(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? DiffReviewComment else { return }
        promptComment(for: c.file, side: c.side, line: c.line, lineText: c.lineText)
    }

    @objc private func deleteComment(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? DiffReviewComment else { return }
        reviewDraft.remove(c)
        reviewChanged()
    }

    @objc private func openCommentFile(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? DiffReviewComment, let gitRoot else { return }
        pane?.openFileLink(path: gitRoot + "/" + c.file, line: c.side == .new ? c.line : nil)
    }
}
