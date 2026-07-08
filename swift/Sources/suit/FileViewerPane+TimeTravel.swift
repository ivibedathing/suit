import Cocoa

// The Cocoa half of the file time-travel scrubber (ROADMAP Phase 40). The pure
// timeline / git-argv / diff-parse decisions live in FileTimeTravel.swift
// (harness-tested); this drives the read-only viewer through a file's revisions
// and hosts the scrubber bar. Read-only and non-destructive — scrubbing never
// checks anything out; leaving the mode reloads the working-tree file.
extension FileViewerPaneContent {

    // View ▸ Time Travel / ⌃⌘T / palette / context menu. Enters the mode (loads
    // the file's history and pins the slider at the working tree) or, if already
    // scrubbing, leaves it and restores the working-tree view.
    func toggleTimeTravel() {
        if isTimeTraveling { exitTimeTravel() } else { enterTimeTravel() }
    }

    func enterTimeTravel() {
        guard let filePath else { NSSound.beep(); return }
        // Don't strand unsaved edits behind the read-only historical view.
        flushIfDirty()
        // History is async; build the timeline when it lands, then enter. The
        // generation guard bails if the file was reloaded meanwhile.
        let generation = loadGeneration
        GitFileHistory.compute(filePath: filePath) { [weak self] root, commits in
            guard let self, self.loadGeneration == generation, !self.isTimeTraveling else { return }
            guard let root, !commits.isEmpty else {
                self.presentNoHistory()
                return
            }
            let revisions = commits.map {
                TimeTravelRevision(sha: $0.sha, shortSha: $0.shortSha, subject: $0.subject, time: $0.time)
            }
            self.beginTimeTravel(root: root, timeline: TimeTravelTimeline(revisions: revisions))
        }
    }

    private func beginTimeTravel(root: String, timeline: TimeTravelTimeline) {
        guard let filePath else { return }
        timeTravelRoot = root
        timeTravelRelativePath = relativePath(of: filePath, root: root)
        timeTravelTimeline = timeline
        timeTravelPosition = timeline.workingTreePosition

        // Read-only while scrubbing — historical revisions can't be edited.
        textView.isEditable = false

        let bar = TimeTravelBarView(stopCount: timeline.stopCount)
        bar.onScrub = { [weak self] position in self?.scrub(to: position) }
        bar.onShowDiff = { [weak self] in self?.showTimeTravelDiff() }
        bar.onExit = { [weak self] in self?.exitTimeTravel() }
        timeTravelBar = bar
        container.topBar = bar

        applyStop()
    }

    // A slider move (integer stop). Re-applies even on the same position so a
    // click on the current tick is harmless.
    func scrub(to position: Int) {
        guard let timeline = timeTravelTimeline else { return }
        timeTravelPosition = min(max(0, position), timeline.stopCount - 1)
        applyStop()
    }

    // Loads the current stop's content + diff-to-neighbour marks. The header and
    // slider update synchronously; the git reads run off-main and drop out (via
    // loadGeneration) if the user scrubs again before they land.
    private func applyStop() {
        guard let timeline = timeTravelTimeline, let filePath,
              let root = timeTravelRoot, let relPath = timeTravelRelativePath else { return }
        let position = timeTravelPosition
        let stop = timeline.stop(at: position)
        let older = timeline.olderNeighbour(at: position)
        let now = Date().timeIntervalSince1970

        let header = TimeTravelHeader.label(for: stop, now: now)
        timeTravelBar?.update(header: header, position: position,
                              stopCount: timeline.stopCount, canDiff: stop.sha != nil)

        loadGeneration += 1
        let generation = loadGeneration
        let showArgs = TimeTravelGit.showArguments(stop: stop, relativePath: relPath)
        let diffArgs = TimeTravelGit.diffArguments(stop: stop, older: older, relativePath: relPath)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text: String
            if let showArgs {
                text = runProcess("/usr/bin/git", ["-C", root] + showArgs)
                    ?? "(this file did not exist at this revision)"
            } else {
                // Working tree: the on-disk file (rightmost stop).
                text = (try? String(contentsOfFile: filePath, encoding: .utf8)) ?? ""
            }
            var changed = IndexSet()
            if let diffArgs, let diff = runProcess("/usr/bin/git", ["-C", root] + diffArgs) {
                changed = TimeTravelDiff.changedNewLines(inDiff: diff)
            }
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == generation, self.isTimeTraveling else { return }
                self.renderTimeTravelContent(text, changedLines: changed)
            }
        }
    }

    // Puts a revision's text on screen read-only, marking its diff-to-neighbour
    // lines. Mirrors the content half of load() without touching filePath /
    // editState / mtime, so exiting cleanly reloads the working tree.
    private func renderTimeTravelContent(_ text: String, changedLines lines: IndexSet) {
        isLoadingProgrammatically = true
        textView.string = text
        isLoadingProgrammatically = false
        textView.undoManager?.removeAllActions()
        recomputeLineStarts(for: text)
        ruler.lineStarts = lineStarts
        ruler.updateThickness()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scroll(.zero)

        changedLines = lines
        ruler.changedLines = lines
        jumpMarkerLine = nil
        syntaxSpans = []
        rehighlight()
        updateMinimapMarkers()
        ruler.needsDisplay = true
    }

    // The "Show Diff" flip: that commit's per-file change in the diff pane
    // (Phase 17's openCommitDiff). No-op at the working-tree stop — there's no
    // commit to `git show`; the ordinary Show Git Diff covers uncommitted work.
    func showTimeTravelDiff() {
        guard let timeline = timeTravelTimeline, let filePath else { NSSound.beep(); return }
        guard let sha = timeline.stop(at: timeTravelPosition).sha else { NSSound.beep(); return }
        pane?.openCommitDiff(forFile: filePath, sha: sha)
    }

    // Leaves time-travel: drops the bar + timeline and reloads the working-tree
    // file, which restores editability, HEAD-vs-disk marks, blame, bookmarks and
    // the clean state — "no residue".
    func exitTimeTravel() {
        guard isTimeTraveling, let filePath else { return }
        timeTravelTimeline = nil
        timeTravelBar = nil
        timeTravelRoot = nil
        timeTravelRelativePath = nil
        container.topBar = nil
        load(path: filePath)
    }

    private func presentNoHistory() {
        NSSound.beep()
        let alert = NSAlert()
        alert.messageText = "No history to scrub"
        alert.informativeText = "This file isn’t tracked by git yet, so there are no earlier revisions to time-travel through."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // Repo-relative path for `git show <sha>:<path>` (addressed from the repo
    // root). Falls back to the base name if the file somehow sits outside root.
    private func relativePath(of path: String, root: String) -> String {
        let stdRoot = (root as NSString).standardizingPath
        let stdPath = (path as NSString).standardizingPath
        if stdPath == stdRoot { return (stdPath as NSString).lastPathComponent }
        let prefix = stdRoot.hasSuffix("/") ? stdRoot : stdRoot + "/"
        if stdPath.hasPrefix(prefix) { return String(stdPath.dropFirst(prefix.count)) }
        return (stdPath as NSString).lastPathComponent
    }
}

// The scrubber strip across the top of the viewer while time-traveling: the
// current revision's header on the left, a slider over every stop in the
// middle, and Diff / Exit buttons on the right. Oldest is left, the working
// tree is the far-right stop.
final class TimeTravelBarView: NSView {
    private let headerLabel = NSTextField(labelWithString: "")
    private let positionLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider()
    private let diffButton = NSButton(title: "Diff", target: nil, action: nil)
    private let exitButton = NSButton(title: "Exit", target: nil, action: nil)

    var onScrub: ((Int) -> Void)?
    var onShowDiff: (() -> Void)?
    var onExit: (() -> Void)?

    private let stopCount: Int

    init(stopCount: Int) {
        self.stopCount = max(1, stopCount)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.barChrome.cgColor

        headerLabel.font = .systemFont(ofSize: 11, weight: .medium)
        headerLabel.textColor = Theme.textPrimary
        headerLabel.lineBreakMode = .byTruncatingTail
        addSubview(headerLabel)

        positionLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        positionLabel.textColor = Theme.textFaint
        positionLabel.alignment = .right
        addSubview(positionLabel)

        slider.minValue = 0
        slider.maxValue = Double(max(0, self.stopCount - 1))
        slider.numberOfTickMarks = self.stopCount
        slider.allowsTickMarkValuesOnly = self.stopCount > 1
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderMoved)
        addSubview(slider)

        for button in [diffButton, exitButton] {
            button.controlSize = .small
            button.bezelStyle = .texturedRounded
            button.target = self
            addSubview(button)
        }
        diffButton.action = #selector(diffClicked)
        exitButton.action = #selector(exitClicked)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Reflects the current stop: header text, slider knob, the "3 / 8" caption,
    // and whether Diff is available (a working-tree stop has no commit to show).
    func update(header: String, position: Int, stopCount: Int, canDiff: Bool) {
        headerLabel.stringValue = header
        slider.doubleValue = Double(position)
        let isWorkingTree = position >= stopCount - 1
        positionLabel.stringValue = isWorkingTree ? "working tree" : "\(position + 1) / \(stopCount)"
        diffButton.isEnabled = canDiff
        needsLayout = true
    }

    @objc private func sliderMoved() {
        onScrub?(Int(slider.doubleValue.rounded()))
    }

    @objc private func diffClicked() { onShowDiff?() }
    @objc private func exitClicked() { onExit?() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let midY = (bounds.height - 20) / 2
        exitButton.sizeToFit()
        exitButton.frame = NSRect(x: bounds.width - exitButton.frame.width - 8, y: midY,
                                  width: exitButton.frame.width, height: 20)
        diffButton.sizeToFit()
        diffButton.frame = NSRect(x: exitButton.frame.minX - diffButton.frame.width - 6, y: midY,
                                  width: diffButton.frame.width, height: 20)

        let posWidth: CGFloat = 78
        positionLabel.frame = NSRect(x: diffButton.frame.minX - posWidth - 8, y: midY + 3,
                                     width: posWidth, height: 14)

        // The header gets the left third; the slider fills the gap to the caption.
        let headerWidth = min(280, max(120, bounds.width * 0.34))
        headerLabel.frame = NSRect(x: 8, y: midY + 2, width: headerWidth, height: 16)
        let sliderX = headerLabel.frame.maxX + 12
        let sliderRight = positionLabel.frame.minX - 12
        slider.frame = NSRect(x: sliderX, y: midY, width: max(0, sliderRight - sliderX), height: 20)
    }

    // A hairline under the bar so it reads as chrome above the text.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Theme.hairline.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
