import Cocoa

// The Source Control tab's index half: the commit box (message, commit button,
// its options menu), the staging gestures behind the row and section buttons,
// and the ⋯ actions menu on the sync row.
//
// It composes, it does not run. Every gesture here ends in `run(_:)`, which
// hands a `GitBranchOps.Action` to the window controller's runner — the same
// one the Files header's branch row uses — so confirmation, off-the-main-thread
// git, the failure alert and the post-action refresh exist once for both
// surfaces. The only thing this file knows about git that GitBranchOps doesn't
// is which paths are in which column, which it reads off the status monitor.
extension GitView {

    // Message box + button row, with the padding baked in. It never grows from
    // the text — a box that resized as you type would move the file list under
    // the pointer mid-edit — but the message field's height is the user's,
    // dragged on the grip below it and remembered, because a commit body written
    // through a two-line slit is the sidebar's worst edit.
    static let minCommitMessageHeight: CGFloat = 46
    static let maxCommitMessageHeight: CGFloat = 320
    // The padding above the field, the grip's gap below it, the button row, and
    // the bottom padding — everything in the box that isn't the message.
    static let commitBoxChrome: CGFloat = 6 + 6 + 22 + 6
    static let minCommitBoxHeight: CGFloat = minCommitMessageHeight + commitBoxChrome
    static let commitMessageHeightKey = "gitCommitMessageHeight"

    var commitBoxHeight: CGFloat { commitMessageHeight + Self.commitBoxChrome }

    // MARK: - Building

    func setupCommitBox() {
        commitTextView.isRichText = false
        commitTextView.isAutomaticQuoteSubstitutionEnabled = false
        commitTextView.isAutomaticDashSubstitutionEnabled = false
        commitTextView.isAutomaticSpellingCorrectionEnabled = false
        commitTextView.font = .systemFont(ofSize: 11.5)
        commitTextView.textColor = Theme.textPrimary
        commitTextView.insertionPointColor = Theme.accent
        commitTextView.drawsBackground = false
        commitTextView.textContainerInset = NSSize(width: 3, height: 4)
        commitTextView.minSize = NSSize(width: 0, height: 0)
        commitTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )
        commitTextView.isVerticallyResizable = true
        commitTextView.isHorizontallyResizable = false
        commitTextView.autoresizingMask = [.width]
        commitTextView.textContainer?.widthTracksTextView = true
        commitTextView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        )
        // ⌘↩ from inside the box commits, so the whole gesture — type, commit —
        // never needs the mouse.
        commitTextView.onCommit = { [weak self] in self?.performCommit() }

        commitScroll.documentView = commitTextView
        commitScroll.hasVerticalScroller = true
        // drawsBackground stays on and the ground goes through `backgroundColor`,
        // not the layer: NSScrollView syncs its layer's background from those
        // properties on every display, so a layer color set behind its back is
        // wiped and the field renders as a hole in the sidebar. Only the corner
        // radius and the border — which it has no opinion about — live on the
        // layer.
        commitScroll.drawsBackground = true
        commitScroll.backgroundColor = Theme.raised
        commitScroll.wantsLayer = true
        commitScroll.layer?.cornerRadius = 4
        commitScroll.layer?.masksToBounds = true
        commitScroll.layer?.borderWidth = 1
        commitBox.addSubview(commitScroll)

        commitButton.bezelStyle = .texturedRounded
        commitButton.controlSize = .small
        commitButton.target = self
        commitButton.action = #selector(commitClicked)
        commitBox.addSubview(commitButton)

        commitOptionsButton.bezelStyle = .texturedRounded
        commitOptionsButton.controlSize = .small
        commitOptionsButton.bezelColor = Theme.raised
        commitOptionsButton.contentTintColor = Theme.textPrimary
        commitOptionsButton.imagePosition = .imageOnly
        commitOptionsButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Commit options")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold))
        commitOptionsButton.toolTip = "Commit options — amend, commit and push, stage all"
        commitOptionsButton.setAccessibilityLabel("Commit options")
        commitOptionsButton.target = self
        commitOptionsButton.action = #selector(openCommitOptionsMenu)
        commitBox.addSubview(commitOptionsButton)

        // The grip owns no height of its own — it sits in the gap that was
        // already between the field and the button — and it resizes nothing
        // itself: GitView holds the height, because the file list underneath has
        // to be relaid out with every point of it.
        commitResizeGrip.onDragBegin = { [weak self] in
            guard let self else { return }
            // The height on screen, not the stored one: a short window clamps the
            // box at layout time, and the drag has to continue from what the user
            // can actually see.
            commitDragStartHeight = commitScroll.frame.height
        }
        commitResizeGrip.onDrag = { [weak self] delta in
            guard let self else { return }
            commitMessageHeight = min(
                Self.maxCommitMessageHeight,
                max(Self.minCommitMessageHeight, commitDragStartHeight + delta)
            )
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        commitResizeGrip.onDragEnd = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(Double(commitMessageHeight), forKey: Self.commitMessageHeightKey)
        }
        commitBox.addSubview(commitResizeGrip)

        addSubview(commitBox)
        reapplyCommitBoxTheme()
    }

    func layoutCommitBox() {
        let padding: CGFloat = 8
        let height = commitBox.bounds.height
        guard height > 0 else { return }
        let width = max(0, commitBox.bounds.width - padding * 2)
        // Derived from the box rather than from `commitMessageHeight` directly,
        // so the clamp GitView.layout() applies in a short window lands on the
        // field too instead of overflowing it past the button row.
        let messageHeight = max(Self.minCommitMessageHeight, height - Self.commitBoxChrome)
        commitScroll.frame = NSRect(x: padding, y: height - 6 - messageHeight, width: width, height: messageHeight)
        commitResizeGrip.frame = NSRect(x: padding, y: commitScroll.frame.minY - 6, width: width, height: 6)
        window?.invalidateCursorRects(for: commitResizeGrip)
        let optionsWidth: CGFloat = 24
        commitOptionsButton.frame = NSRect(
            x: padding + width - optionsWidth, y: 6, width: optionsWidth, height: 22
        )
        commitButton.frame = NSRect(
            x: padding, y: 6, width: max(0, width - optionsWidth - 4), height: 22
        )
    }

    // The commit box's ground and border are layer properties baked in once, so
    // a theme switch has to re-read them (see GitView.reapplyTheme).
    func reapplyCommitBoxTheme() {
        commitScroll.backgroundColor = Theme.raised
        commitScroll.layer?.borderColor = Theme.hairline.cgColor
        commitOptionsButton.bezelColor = Theme.raised
        commitOptionsButton.contentTintColor = Theme.textPrimary
        commitTextView.textColor = Theme.textPrimary
        commitTextView.insertionPointColor = Theme.accent
        commitTextView.needsDisplay = true
    }

    // MARK: - State

    // Called from reload(): the button title carries what committing will do
    // right now ("Commit 3" / "Commit All 5" / "Amend Commit"), so the
    // stage-everything shortcut can't be mistaken for committing nothing.
    func refreshCommitBox() {
        let staged = stagedPaths.count
        let unstaged = unstagedPaths.count
        let title = GitBranchOps.commitButtonTitle(
            stagedCount: staged, unstagedCount: unstaged, amend: amendMode
        )
        let enabled = gitRoot != nil && (staged > 0 || unstaged > 0 || amendMode)
        commitButton.isEnabled = enabled
        // Bezel and title both come from the palette rather than from AppKit's
        // appearance: a stock bezel is drawn for the window's NSAppearance,
        // which a theme switch doesn't change, so under a light palette the
        // button faded into the sidebar. Amber title while amending, matching
        // how the rest of the app marks a mode that changes what an action does.
        commitButton.bezelColor = Theme.raised
        commitButton.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: enabled ? (amendMode ? Theme.accent : Theme.textPrimary) : Theme.textFaint,
        ])
        commitOptionsButton.isEnabled = gitRoot != nil
        commitTextView.placeholder = amendMode
            ? "Amend message (empty keeps the previous one)"
            : "Message (⌘↩ to commit)"
        commitTextView.needsDisplay = true
    }

    // MARK: - Running

    // Every git gesture in this tab funnels through here, so there is exactly
    // one place that knows the runner exists.
    func run(_ action: GitBranchOps.Action, completion: ((Bool) -> Void)? = nil) {
        guard let root = gitRoot, let onRunAction else { return }
        onRunAction(root, action, completion)
    }

    // MARK: - Staging

    func stageAll() { run(.stageAll) }
    func unstageAll() { run(.unstageAll) }

    @objc func stageFromMenu(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        run(.stage(paths: [path]))
    }

    @objc func unstageFromMenu(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        run(.unstage(paths: [path]))
    }

    // Restoring a tracked file and deleting an untracked one are different
    // commands, so which list the path belongs to decides the plan.
    @objc func discardFromMenu(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        if untrackedPaths.contains(path) {
            run(.discardPaths(tracked: [], untracked: [path]))
        } else {
            run(.discardPaths(tracked: [path], untracked: []))
        }
    }

    // MARK: - Committing

    @objc func commitClicked() {
        performCommit()
    }

    // With nothing staged, committing stages everything first — git's own
    // `commit -a` habit, except it also picks up untracked files, which is what
    // the button has been saying it would do ("Commit All 5").
    func performCommit(push: Bool = false, forceStageAll: Bool = false) {
        guard gitRoot != nil else { return }
        let message = commitTextView.string
        if let complaint = GitBranchOps.validateCommitMessage(message, amend: amendMode) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Nothing to commit yet"
            alert.informativeText = complaint
            alert.runModal()
            window?.makeFirstResponder(commitTextView)
            return
        }
        let request = GitBranchOps.CommitRequest(
            message: message,
            amend: amendMode,
            stageAll: forceStageAll || stagedPaths.isEmpty,
            push: push
        )
        run(.commit(request)) { [weak self] success in
            guard let self, success else { return }
            // Only a landed commit clears the box; a failed one (hook rejected,
            // nothing staged after all) keeps the message the user typed.
            self.commitTextView.string = ""
            self.amendMode = false
            self.refreshCommitBox()
        }
    }

    @objc func openCommitOptionsMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let staged = stagedPaths.count
        let unstaged = unstagedPaths.count

        let stagedItem = menu.addItem(
            withTitle: "Commit Staged", action: #selector(commitStagedItem), keyEquivalent: ""
        )
        stagedItem.target = self
        stagedItem.isEnabled = staged > 0

        let allItem = menu.addItem(
            withTitle: "Stage All & Commit", action: #selector(commitAllItem), keyEquivalent: ""
        )
        allItem.target = self
        allItem.isEnabled = staged + unstaged > 0

        let pushItem = menu.addItem(
            withTitle: "Commit & Push", action: #selector(commitAndPushItem), keyEquivalent: ""
        )
        pushItem.target = self
        pushItem.isEnabled = staged + unstaged > 0 || amendMode

        menu.addItem(.separator())
        let amendItem = menu.addItem(
            withTitle: "Amend Last Commit", action: #selector(toggleAmend), keyEquivalent: ""
        )
        amendItem.target = self
        amendItem.state = amendMode ? .on : .off
        amendItem.toolTip = "Fold this commit into the previous one instead of adding a new one"

        menu.addItem(.separator())
        let stageAllItem = menu.addItem(withTitle: "Stage All Changes", action: #selector(stageAllItem), keyEquivalent: "")
        stageAllItem.target = self
        stageAllItem.isEnabled = unstaged > 0
        let unstageAllItem = menu.addItem(withTitle: "Unstage Everything", action: #selector(unstageAllItem), keyEquivalent: "")
        unstageAllItem.target = self
        unstageAllItem.isEnabled = staged > 0

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: commitOptionsButton.frame.minX - 140, y: commitOptionsButton.frame.minY - 2),
            in: commitBox
        )
    }

    @objc private func commitStagedItem() { performCommit() }
    @objc private func commitAllItem() { performCommit(forceStageAll: true) }
    @objc private func commitAndPushItem() { performCommit(push: true) }
    @objc private func stageAllItem() { stageAll() }
    @objc private func unstageAllItem() { unstageAll() }

    // Turning amend on with an empty box pulls the previous message in, so the
    // common case (fix a typo in the code, keep the message) is one click and
    // the uncommon one (rewrite the message) starts from what it said.
    @objc private func toggleAmend() {
        amendMode.toggle()
        refreshCommitBox()
        guard amendMode, commitTextView.string.isEmpty, let root = gitRoot else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let previous = runProcess("/usr/bin/git", ["-C", root, "log", "-1", "--pretty=%B"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard let self, self.amendMode, let previous, !previous.isEmpty,
                      self.commitTextView.string.isEmpty else { return }
                self.commitTextView.string = previous
                self.refreshCommitBox()
            }
        }
    }

    // MARK: - Actions menu (the ⋯ on the sync row)

    // The same set the Files header offers, composed the same way: every entry
    // carries a GitBranchOps.Action, and an entry that couldn't succeed (push
    // with no upstream, pop with an empty stash) is disabled rather than hidden
    // so the menu's shape stays stable.
    @objc func openActionsMenu() {
        guard let root = gitRoot else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let branch = monitor?.currentBranch

        addAction(to: menu, title: "Fetch", action: .fetch)
        // behind == 0 is not a reason to disable Pull: the counts are only as
        // fresh as the last fetch.
        addAction(to: menu, title: "Pull", action: .pull, enabled: sync.hasUpstream && !sync.isGone)
        addAction(to: menu, title: "Pull (Rebase)", action: .pullRebase, enabled: sync.hasUpstream && !sync.isGone)
        if sync.hasUpstream && !sync.isGone {
            addAction(to: menu, title: sync.ahead > 0 ? "Push (\(sync.ahead))" : "Push", action: .push)
        } else if let branch {
            addAction(to: menu, title: "Publish Branch", action: .publish(branch: branch))
        }

        if sync.hasDifference, !sync.isGone, branch != nil {
            menu.addItem(.separator())
            let item = menu.addItem(
                withTitle: "Diff vs \(sync.upstream ?? "Upstream")",
                action: #selector(upstreamDiffItem), keyEquivalent: ""
            )
            item.target = self
        }

        menu.addItem(.separator())
        addAction(to: menu, title: "Stash Changes", action: .stash, enabled: hasLocalChanges)
        addAction(
            to: menu, title: stashCount > 0 ? "Pop Stash (\(stashCount))" : "Pop Stash",
            action: .stashPop, enabled: stashCount > 0
        )
        addAction(to: menu, title: "Discard All Changes…", action: .discardAll, enabled: hasLocalChanges)

        menu.addItem(.separator())
        let newItem = menu.addItem(withTitle: "New Branch…", action: #selector(newBranchItem), keyEquivalent: "")
        newItem.target = self
        addDeleteBranchItem(to: menu, root: root, current: branch)

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: actionsButton.frame.minX - 160, y: actionsButton.frame.minY - 2),
            in: self
        )
    }

    private func addAction(to menu: NSMenu, title: String, action: GitBranchOps.Action, enabled: Bool = true) {
        let item = menu.addItem(withTitle: title, action: #selector(runActionItem(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = BoxedGitAction(action)
        item.isEnabled = enabled
    }

    // Only the branches git would actually let us delete — never the
    // checked-out one, never one another worktree holds — and only the safe
    // `-d`; the force variant is reached by escalation from the failure alert.
    private func addDeleteBranchItem(to menu: NSMenu, root: String, current: String?) {
        let claimed = Set(WorktreeSwitcher.worktrees(root: root).compactMap { $0.branch })
        let deletable = GitBranchOps.deletableBranches(
            all: WorktreeSwitcher.branches(root: root), current: current, checkedOutElsewhere: claimed
        )
        let parent = menu.addItem(withTitle: "Delete Branch", action: nil, keyEquivalent: "")
        guard !deletable.isEmpty else {
            parent.isEnabled = false
            return
        }
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for name in deletable {
            addAction(to: submenu, title: name, action: .deleteBranch(name: name, force: false))
        }
        parent.submenu = submenu
    }

    @objc private func runActionItem(_ sender: NSMenuItem) {
        guard let boxed = sender.representedObject as? BoxedGitAction else { return }
        run(boxed.action)
    }

    @objc private func newBranchItem() {
        guard let root = gitRoot else { return }
        onNewBranch?(root)
    }

    @objc private func upstreamDiffItem() {
        guard let root = gitRoot, let branch = monitor?.currentBranch, sync.hasUpstream else { return }
        onShowUpstreamDiff?(root, branch)
    }
}

// NSMenuItem.representedObject is `Any?`, and an enum with associated values
// doesn't survive that round trip as cleanly as a class reference — box it so
// the cast back is unambiguous. (ProjectHeaderView has its own private twin;
// this one is shared by the Source Control tab's two menus.)
final class BoxedGitAction {
    let action: GitBranchOps.Action
    init(_ action: GitBranchOps.Action) { self.action = action }
}

// The commit message field: a plain multi-line text view with two additions a
// commit box needs and NSTextView doesn't have — a placeholder (an empty box
// has to say what it is, and there is no room for a label above it) and ⌘↩ to
// commit, caught in performKeyEquivalent because Cmd-Return has no standard
// text-view binding and would otherwise just beep.
// The drag grip under the commit message field: the 6pt gap that was already
// between the field and the Commit button, turned into a hit target with a
// resize cursor and a short centered bar to say so. It reports the drag and
// nothing else — the height lives on GitView, which is the only place that can
// relayout the file list along with it.
final class CommitResizeGrip: NSView {
    var onDragBegin: (() -> Void)?
    // The distance dragged since mouse-down, positive downward.
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?

    private var dragStartY: CGFloat?
    private var hovering = false
    private var tracking: NSTrackingArea?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        dragStartY = event.locationInWindow.y
        onDragBegin?()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        // Measured in window coordinates: the grip moves down with the box it is
        // growing, so a delta taken against its own bounds would chase itself.
        guard let dragStartY else { return }
        onDrag?(dragStartY - event.locationInWindow.y)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartY != nil else { return }
        dragStartY = nil
        onDragEnd?()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let active = hovering || dragStartY != nil
        let barWidth: CGFloat = 28
        let bar = NSRect(
            x: (bounds.width - barWidth) / 2, y: (bounds.height - 2) / 2,
            width: min(barWidth, bounds.width), height: 2
        )
        (active ? Theme.textDim : Theme.hairline).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
    }
}

final class CommitMessageTextView: NSTextView {
    var placeholder: String = ""
    var onCommit: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers == "\r",
           window?.firstResponder === self {
            onCommit?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let inset = textContainerInset
        let origin = NSPoint(x: inset.width + 5, y: inset.height)
        placeholder.draw(at: origin, withAttributes: [
            .font: font ?? NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: Theme.textFaint,
        ])
    }

    // The placeholder has to disappear on the first keystroke and come back on
    // the last delete; NSTextView only redraws the changed glyph range.
    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
