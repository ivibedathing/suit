import Cocoa

// The diff pane (ROADMAP Phase 3): renders `git diff` output side-by-side or
// unified. Heavy use comes in Phase 5's review mode - the pane is driven by
// diff *text* (see DiffParser.swift), so any producer can feed it.

// A read-only diff text view that takes review-mode keys (ROADMAP Phase 5):
// n/p walk the changed files, o opens the current file in the viewer pane.
final class DiffTextView: NSTextView {
    weak var diffContent: DiffPaneContent?

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "n":
            diffContent?.navigateFiles(1)
        case "p":
            diffContent?.navigateFiles(-1)
        case "o":
            diffContent?.openCurrentFile()
        case "c":
            diffContent?.addCommentAtCaret()
        default:
            super.keyDown(with: event)
        }
    }
}

// The diff pane: a header (mode toggle + refresh) above one unified text view
// or two side-by-side views with locked scrolling.
final class DiffPaneContent: NSObject, PaneContent {
    weak var pane: Pane?
    weak var tab: Tab?

    private let containerView = NSView(frame: .zero)
    private let modePicker = NSSegmentedControl(labels: ["Unified", "Side by Side"], trackingMode: .selectOne, target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let reviewButton = NSButton(title: "Review", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    // The review draft (ROADMAP Phase 16): comments accumulate here, render
    // inline in the unified view, and compose into one prompt sent to a session.
    let reviewDraft = DiffReviewDraft()

    // One entry per rendered content line of the *unified* view, mapping its
    // character range back to the diff line it came from — the hit-test behind
    // "add comment at caret" and the anchor comments render against.
    private struct UnifiedLineRef {
        let range: NSRange
        let file: String
        let side: DiffReviewComment.Side
        let line: Int
        let text: String
    }
    private var unifiedLineRefs: [UnifiedLineRef] = []

    private let unifiedScroll = NSScrollView(frame: .zero)
    private let unifiedText: DiffTextView
    private let leftScroll = NSScrollView(frame: .zero)
    private let leftText: DiffTextView
    private let rightScroll = NSScrollView(frame: .zero)
    private let rightText: DiffTextView

    private var diffLines: [DiffLine] = []
    private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var baseColor = NSColor.textColor
    private var background = Theme.bg
    private var syncingScroll = false

    // Review walking (ROADMAP Phase 5): each changed file's path and where its
    // header sits in the rendered unified / side-by-side texts, in diff order.
    private var changedFilePaths: [String] = []
    private var unifiedAnchors: [Int] = []
    private var sideAnchors: [Int] = []

    // Re-runs whatever produced the current diff (git diff on a root, a
    // review-set command, …); set by the loader.
    private var reload: (() -> String)?
    private(set) var gitRoot: String?

    var view: NSView { containerView }
    var focusTarget: NSView { modePicker.selectedSegment == 0 ? unifiedText : leftText }
    var defaultTitle: String { "Diff" }
    var workingDirectory: String? { gitRoot }

    var initialBackgroundColor: NSColor { background }

    override init() {
        unifiedText = DiffTextView(frame: .zero)
        leftText = DiffTextView(frame: .zero)
        rightText = DiffTextView(frame: .zero)
        super.init()

        for (textView, scroll) in [(unifiedText, unifiedScroll), (leftText, leftScroll), (rightText, rightScroll)] {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.usesFindBar = true
            textView.textContainerInset = NSSize(width: 4, height: 4)
            textView.autoresizingMask = [.width]
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.drawsBackground = true
            textView.diffContent = self
            scroll.documentView = textView
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            containerView.addSubview(scroll)
        }

        modePicker.selectedSegment = 0
        modePicker.controlSize = .small
        modePicker.target = self
        modePicker.action = #selector(modeChanged)
        containerView.addSubview(modePicker)

        refreshButton.controlSize = .small
        refreshButton.bezelStyle = .texturedRounded
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        containerView.addSubview(refreshButton)

        // The review inspector's entry point: shown only once the draft has a
        // comment (ROADMAP Phase 16). Click pops the list + Send / Clear menu.
        reviewButton.controlSize = .small
        reviewButton.bezelStyle = .texturedRounded
        reviewButton.target = self
        reviewButton.action = #selector(showReviewMenu(_:))
        reviewButton.isHidden = true
        containerView.addSubview(reviewButton)

        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = Theme.textFaint
        statusLabel.lineBreakMode = .byTruncatingTail
        containerView.addSubview(statusLabel)

        containerView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(layoutContents),
            name: NSView.frameDidChangeNotification, object: containerView
        )

        // Locked side-by-side scrolling: whichever side moves drives the other.
        for scroll in [leftScroll, rightScroll] {
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(sideScrolled(_:)),
                name: NSView.boundsDidChangeNotification, object: scroll.contentView
            )
        }

        updateModeVisibility()
    }

    @objc private func layoutContents() {
        let bounds = containerView.bounds
        let headerHeight: CGFloat = 30
        let contentHeight = max(0, bounds.height - headerHeight)

        modePicker.sizeToFit()
        modePicker.frame.origin = NSPoint(x: 8, y: contentHeight + (headerHeight - modePicker.frame.height) / 2)
        refreshButton.sizeToFit()
        refreshButton.frame.origin = NSPoint(x: bounds.width - refreshButton.frame.width - 8, y: contentHeight + (headerHeight - refreshButton.frame.height) / 2)

        var rightEdge = refreshButton.frame.minX
        if !reviewButton.isHidden {
            reviewButton.sizeToFit()
            reviewButton.frame.origin = NSPoint(x: rightEdge - reviewButton.frame.width - 6, y: contentHeight + (headerHeight - reviewButton.frame.height) / 2)
            rightEdge = reviewButton.frame.minX
        }

        let statusX = modePicker.frame.maxX + 10
        statusLabel.frame = NSRect(
            x: statusX, y: contentHeight + 8,
            width: max(0, rightEdge - statusX - 8), height: 14
        )

        unifiedScroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: contentHeight)
        let half = (bounds.width / 2).rounded(.down)
        leftScroll.frame = NSRect(x: 0, y: 0, width: half, height: contentHeight)
        rightScroll.frame = NSRect(x: half + 1, y: 0, width: max(0, bounds.width - half - 1), height: contentHeight)
    }

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

    @objc private func refresh(_ sender: Any?) {
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

    @objc private func modeChanged(_ sender: Any?) {
        updateModeVisibility()
        if let window = containerView.window, window.firstResponder === unifiedText || window.firstResponder === leftText {
            window.makeFirstResponder(focusTarget)
        }
    }

    private func updateModeVisibility() {
        let unified = modePicker.selectedSegment == 0
        unifiedScroll.isHidden = !unified
        leftScroll.isHidden = unified
        rightScroll.isHidden = unified
    }

    // MARK: - Rendering

    private struct DiffPalette {
        let addition: NSColor
        let deletion: NSColor
        let additionBackground: NSColor
        let deletionBackground: NSColor
        let header: NSColor
        let meta: NSColor
        let fillerBackground: NSColor
    }

    private var palette: DiffPalette {
        DiffPalette(
            addition: NSColor(calibratedRed: 0.55, green: 0.85, blue: 0.55, alpha: 1),
            deletion: NSColor(calibratedRed: 0.94, green: 0.52, blue: 0.50, alpha: 1),
            additionBackground: NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.25, alpha: 0.22),
            deletionBackground: NSColor(calibratedRed: 0.70, green: 0.20, blue: 0.18, alpha: 0.22),
            header: NSColor(calibratedRed: 0.42, green: 0.78, blue: 0.86, alpha: 1),
            meta: NSColor(calibratedWhite: 0.55, alpha: 1),
            fillerBackground: NSColor(calibratedWhite: 0.5, alpha: 0.06)
        )
    }

    private func render() {
        renderUnified()
        renderSideBySide()
    }

    private func attributes(color: NSColor, background: NSColor? = nil) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if let background {
            attrs[.backgroundColor] = background
        }
        return attrs
    }

    private func renderUnified() {
        let palette = palette
        let output = NSMutableAttributedString()
        unifiedAnchors = []
        unifiedLineRefs = []
        var currentFile: String?
        let commentAttrs = attributes(color: Theme.accent, background: Theme.accent.withAlphaComponent(0.09))

        if diffLines.isEmpty {
            output.append(NSAttributedString(string: "No changes.", attributes: attributes(color: palette.meta)))
        }
        for line in diffLines {
            let text: String
            let attrs: [NSAttributedString.Key: Any]
            // The (side, line) this content row anchors a comment to, if any.
            var anchor: (DiffReviewComment.Side, Int)?
            switch line.kind {
            case .fileHeader:
                currentFile = Self.fileFromHeader(line.text)
                unifiedAnchors.append(output.length + 1) // past the blank spacer line
                text = "\n" + line.text
                attrs = attributes(color: palette.header)
            case .hunkHeader:
                text = line.text
                attrs = attributes(color: palette.meta)
            case .meta:
                text = line.text
                attrs = attributes(color: palette.meta)
            case .context:
                text = "  " + line.text
                attrs = attributes(color: baseColor)
                if let n = line.newLine { anchor = (.new, n) }
            case .addition:
                text = "+ " + line.text
                attrs = attributes(color: palette.addition, background: palette.additionBackground)
                if let n = line.newLine { anchor = (.new, n) }
            case .deletion:
                text = "- " + line.text
                attrs = attributes(color: palette.deletion, background: palette.deletionBackground)
                if let n = line.oldLine { anchor = (.old, n) }
            }

            let start = output.length
            output.append(NSAttributedString(string: text + "\n", attributes: attrs))

            // Record the hit-test map and render any attached comment inline
            // right under the line it belongs to (amber, gutter-ticked).
            if let file = currentFile, let (side, num) = anchor {
                unifiedLineRefs.append(UnifiedLineRef(
                    range: NSRange(location: start, length: output.length - start),
                    file: file, side: side, line: num, text: line.text
                ))
                if let comment = reviewDraft.comment(file: file, side: side, line: num) {
                    output.append(NSAttributedString(string: "    ▎ " + comment.text + "\n", attributes: commentAttrs))
                }
            }
        }
        unifiedText.textStorage?.setAttributedString(output)
    }

    // The b/ path out of a "diff --git a/x b/x" header — matches
    // UnifiedDiffParser.changedPaths so anchors line up with review-walk paths.
    private static func fileFromHeader(_ raw: String) -> String? {
        guard let range = raw.range(of: " b/") else { return nil }
        return String(raw[range.upperBound...])
    }

    // Aligns deletions and additions within each hunk into left/right rows,
    // padding the shorter run with filler lines, so changed regions sit next
    // to each other.
    private func renderSideBySide() {
        let palette = palette
        let left = NSMutableAttributedString()
        let right = NSMutableAttributedString()
        sideAnchors = []

        func appendRow(_ leftLine: (String, [NSAttributedString.Key: Any]), _ rightLine: (String, [NSAttributedString.Key: Any])) {
            left.append(NSAttributedString(string: leftLine.0 + "\n", attributes: leftLine.1))
            right.append(NSAttributedString(string: rightLine.0 + "\n", attributes: rightLine.1))
        }

        let filler = ("", attributes(color: baseColor, background: palette.fillerBackground))

        var pendingDeletions: [DiffLine] = []
        var pendingAdditions: [DiffLine] = []

        func flushPending() {
            let rows = max(pendingDeletions.count, pendingAdditions.count)
            for i in 0..<rows {
                let leftLine = i < pendingDeletions.count
                    ? (pendingDeletions[i].text, attributes(color: palette.deletion, background: palette.deletionBackground))
                    : filler
                let rightLine = i < pendingAdditions.count
                    ? (pendingAdditions[i].text, attributes(color: palette.addition, background: palette.additionBackground))
                    : filler
                appendRow(leftLine, rightLine)
            }
            pendingDeletions = []
            pendingAdditions = []
        }

        if diffLines.isEmpty {
            left.append(NSAttributedString(string: "No changes.", attributes: attributes(color: palette.meta)))
        }
        for line in diffLines {
            switch line.kind {
            case .deletion:
                pendingDeletions.append(line)
            case .addition:
                pendingAdditions.append(line)
            case .fileHeader:
                flushPending()
                sideAnchors.append(left.length + 1) // past the blank spacer line
                appendRow(("\n" + line.text, attributes(color: palette.header)), ("\n" + line.text, attributes(color: palette.header)))
            case .hunkHeader, .meta:
                flushPending()
                appendRow((line.text, attributes(color: palette.meta)), (line.text, attributes(color: palette.meta)))
            case .context:
                flushPending()
                appendRow((line.text, attributes(color: baseColor)), (line.text, attributes(color: baseColor)))
            }
        }
        flushPending()

        leftText.textStorage?.setAttributedString(left)
        rightText.textStorage?.setAttributedString(right)
    }

    @objc private func sideScrolled(_ note: Notification) {
        guard !syncingScroll, let moved = note.object as? NSClipView else { return }
        let other = moved === leftScroll.contentView ? rightScroll : leftScroll
        syncingScroll = true
        other.contentView.scroll(to: NSPoint(x: other.contentView.bounds.origin.x, y: moved.bounds.origin.y))
        other.reflectScrolledClipView(other.contentView)
        syncingScroll = false
    }

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
    @objc private func showReviewMenu(_ sender: NSButton) {
        let menu = NSMenu()

        let send = menu.addItem(withTitle: "Send Review to Session…", action: #selector(sendReview), keyEquivalent: "")
        send.target = self
        send.isEnabled = !reviewDraft.isEmpty

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

    // MARK: - Appearance

    func applyFont(_ newFont: NSFont) {
        font = newFont
        render()
    }

    func applyTextColor(_ color: NSColor) {
        baseColor = color
        render()
    }

    func applyBackground(_ color: NSColor) {
        background = color
        for textView in [unifiedText, leftText, rightText] {
            textView.backgroundColor = color
        }
    }

    func teardown() {
        NotificationCenter.default.removeObserver(self)
    }
}
