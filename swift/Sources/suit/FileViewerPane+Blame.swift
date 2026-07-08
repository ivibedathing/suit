import Cocoa

// Changed-region marks, the blame gutter + file history, and bookmarks for the
// read-only viewer (ROADMAP Phases 5, 17, 22). Split out of FileViewerPane.swift;
// stored state lives in the primary declaration.
extension FileViewerPaneContent {
    // MARK: - Changed regions (ROADMAP Phase 5)

    @objc func gitStatusChanged(_ note: Notification) {
        refreshChangedLines()
    }

    func refreshChangedLines() {
        // While scrubbing history the gutter shows the diff-to-neighbour marks
        // the scrubber computed, not HEAD-vs-disk — don't overwrite them.
        guard !isTimeTraveling else { return }
        guard let filePath else { return }
        let generation = loadGeneration
        GitChangedLines.compute(filePath: filePath) { [weak self] lines in
            guard let self, self.loadGeneration == generation else { return }
            self.changedLines = lines
            self.ruler.changedLines = lines
            self.updateMinimapMarkers()
        }
    }

    // MARK: - Blame gutter + file history (ROADMAP Phase 17)

    // View ▸ Toggle Blame / ⌃⌘B / palette. Flips the gutter column; the first
    // reveal loads blame for the current file.
    func toggleBlame() {
        blameVisible.toggle()
        ruler.blameVisible = blameVisible
        applyWrapWidth()
        if blameVisible {
            loadBlame()
        }
    }

    func loadBlame() {
        guard let filePath else { return }
        let generation = loadGeneration
        GitBlame.compute(filePath: filePath) { [weak self] lines in
            guard let self, self.loadGeneration == generation else { return }
            self.ruler.blameByLine = lines
        }
    }

    // View ▸ Show File History / palette: reveal the Git tab's File History
    // section for this file. Routed through the pane host (the window controller
    // owns the sidebar).
    func showFileHistory() {
        guard let filePath else { return }
        pane?.showFileHistory(forPath: filePath)
    }

    func openCommitDiff(sha: String) {
        guard let filePath else { return }
        pane?.openCommitDiff(forFile: filePath, sha: sha)
    }

    // MARK: - Bookmarks (ROADMAP Phase 22)

    @objc func bookmarksChanged(_ note: Notification) {
        refreshBookmarks()
    }

    // Pulls this file's bookmarked lines out of the store into the gutter and
    // minimap.
    func refreshBookmarks() {
        guard let filePath else {
            bookmarkedLines = IndexSet()
            ruler.bookmarkedLines = IndexSet()
            updateMinimapMarkers()
            return
        }
        bookmarkedLines = IndexSet(BookmarksStore.shared.lines(inFile: filePath))
        ruler.bookmarkedLines = bookmarkedLines
        updateMinimapMarkers()
    }

    // The 1-based line the caret (selection start) sits on.
    private var currentLine: Int {
        let caret = textView.selectedRange().location
        var line = 1
        for (i, start) in lineStarts.enumerated() where start <= caret {
            line = i + 1
        }
        return line
    }

    // The text of a 1-based line, trimmed of its newline — the bookmark snippet.
    private func text(ofLine line: Int) -> String {
        guard lineStarts.indices.contains(line - 1) else { return "" }
        let start = lineStarts[line - 1]
        let end = line < lineStarts.count ? lineStarts[line] : (textView.string as NSString).length
        let range = NSRange(location: start, length: max(0, end - start))
        return (textView.string as NSString).substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Add/remove the bookmark at `line` (gutter click, and the toggle command
    // via currentLine). The store posts didUpdate, which refreshes every open
    // viewer of the file — including this one.
    func toggleBookmark(atLine line: Int) {
        guard let filePath else { NSSound.beep(); return }
        BookmarksStore.shared.toggle(path: filePath, line: line, snippet: text(ofLine: line), from: self)
    }

    // ⇧⌘L / the palette / the context menu: bookmark the caret's line.
    func toggleBookmarkAtCurrentLine() {
        toggleBookmark(atLine: currentLine)
    }

    @objc func scrolled(_ note: Notification) {
        ruler.needsDisplay = true
        updateMinimapViewport()
    }
}
