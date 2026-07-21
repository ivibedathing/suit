import Cocoa

// Read-only file viewing inside the pane tree: line numbers,
// go-to-line, jump-to-line from the fuzzy opener / terminal links, syntax
// highlighting and a minimap. Deliberately not an editor — selection
// and copy only.
//
// The gutter (LineNumberRulerView), the text view (ViewerTextView), and the
// root container (ViewerContainerView) live in their own files; syntax/minimap
// wiring is in FileViewerPane+Highlighting.swift and the blame gutter, file
// history and bookmarks in FileViewerPane+Blame.swift.
final class FileViewerPaneContent: NSObject, FileBackedPaneContent {
    weak var pane: Pane?
    weak var tab: Tab?

    let scrollView = NSScrollView(frame: .zero)
    let textView: ViewerTextView
    let ruler: LineNumberRulerView
    let minimap = MinimapView(frame: .zero)
    var container: ViewerContainerView!

    private(set) var filePath: String?
    var lineStarts: [Int] = [0]
    var syntaxSpans: [SyntaxSpan] = []
    var baseTextColor: NSColor = .textColor

    // MARK: - Editing

    // Saved-vs-buffer tracking; the pure decisions live in FileEdit.swift.
    var editState = FileEditState()
    // True only when a real text file is loaded — the error placeholders
    // (binary / too large / unreadable) stay read-only.
    var isEditableFile = false
    // Debounced autosave (the NotesStore pattern) and debounced re-highlight so
    // colouring doesn't run on every keystroke.
    var autosaveTimer: Timer?
    var rehighlightTimer: Timer?
    // The file's on-disk mtime at our last load/save, to detect outside edits.
    var savedModificationDate: Date?
    // Set while we assign textView.string ourselves, so a programmatic reload
    // is never mistaken for a user edit.
    var isLoadingProgrammatically = false
    // Live watch on the open file, so a rewrite by Claude / $EDITOR / a branch
    // switch lands in the tab as it happens rather than at the next app
    // activation. Re-created per load(); the reconcile it triggers is the same
    // one appBecameActive runs.
    var fileWatcher: FileWatcher?
    // True while the "changed on disk" conflict sheet is up. A live watcher can
    // fire again while the user is still deciding — without this, a file being
    // rewritten repeatedly would stack a sheet per write on top of the one
    // that's already asking about the same conflict.
    var isPresentingExternalConflict = false

    // MARK: - Find

    // The ⌘F bar, non-nil only while it's open. The logic is in
    // FileViewerPane+Find.swift; the matching itself in FindReplace.swift.
    var findBar: FindBarView?
    // Matches for the current query against the current buffer, and which one is
    // "current". Cached rather than recomputed per keystroke — but the cache is
    // only valid for the generation it was computed against: temporary highlight
    // attributes don't track edits, so a stale range is an out-of-bounds crash,
    // not a cosmetic glitch. findMatchGeneration is what makes that impossible.
    var findMatches: [NSRange] = []
    var findMatchIndex = 0
    var findMatchGeneration = -1

    // Files past this stop being useful to scroll through and start being a
    // memory problem; the viewer refuses rather than beachballing.
    private static let maxFileSize = 8 * 1024 * 1024

    var view: NSView { container }
    var focusTarget: NSView { textView }
    var defaultTitle: String { "Viewer" }

    var workingDirectory: String? {
        guard let filePath else { return nil }
        return (filePath as NSString).deletingLastPathComponent
    }

    override init() {
        textView = ViewerTextView(frame: .zero)
        // Read-only until a real text file loads (load() flips this
        // on for editable content, off for binary/too-large/error placeholders).
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        // NSTextView's stock find bar is off: the viewer answers ⌘F with its own
        // themed find/replace widget instead (ViewerTextView.performFindPanelAction
        // → FileViewerPane+Find). isIncrementalSearchingEnabled is NSTextFinder-only
        // and would be dead weight with the finder disabled.
        textView.usesFindBar = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.drawsBackground = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        super.init()
        textView.viewerContent = self
        textView.delegate = self
        container = ViewerContainerView(scrollView: scrollView, minimap: minimap)

        // Gutter click toggles the bookmark on that line.
        ruler.onToggleLine = { [weak self] line in
            self?.toggleBookmark(atLine: line)
        }

        // A click in the fold column collapses or expands that block.
        ruler.onToggleFold = { [weak self] line in
            self?.toggleFold(atLine: line)
        }

        // The outline and breadcrumb are built from the project's ctags index,
        // which finishes (and refreshes) asynchronously.
        NotificationCenter.default.addObserver(
            self, selector: #selector(symbolIndexChanged),
            name: SymbolIndex.didUpdate, object: nil
        )

        minimap.onJump = { [weak self] fraction in
            self?.scroll(toFraction: fraction)
        }

        // Chaining: clicking a blame line's sha opens that
        // commit's per-file diff.
        ruler.onBlameClick = { [weak self] blame in
            self?.openCommitDiff(sha: blame.sha)
        }

        // The gutter and minimap viewport track scrolling and text relayout.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        // Changed-region marks refresh when any repo's status changes (the
        // handler filters to this file's repo).
        NotificationCenter.default.addObserver(
            self, selector: #selector(gitStatusChanged),
            name: GitStatusMonitor.didUpdate, object: nil
        )
        // Bookmarks changing anywhere (another window, the sidebar list)
        // refresh this file's gutter/minimap ticks.
        NotificationCenter.default.addObserver(
            self, selector: #selector(bookmarksChanged),
            name: BookmarksStore.didUpdate, object: nil
        )
        // Editable viewer: when the app regains focus, check whether
        // the open file was rewritten underneath us (Claude / $EDITOR) and
        // reconcile — a clean buffer reloads, a dirty one prompts.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil
        )
    }

    // MARK: - Code folding

    // Foldable regions for the current buffer (recomputed with re-highlighting)
    // and the start lines currently folded. See FileViewerPane+Folding.swift for
    // why the fold set is start lines rather than ranges.
    var foldRegions: [FoldRegion] = []
    var foldedStarts: Set<Int> = []

    // MARK: - Symbol outline & breadcrumb

    // This file's symbols, from the project's SymbolIndex, in line order.
    // Rebuilt when the index updates or the file reloads — never per keystroke.
    var outlineEntries: [OutlineEntry] = []
    var breadcrumbBar: BreadcrumbBarView?

    // MARK: - Peek definition

    // The inline definition popover (⌥⌘J / ⌥⌘-click), non-nil only while open.
    var peekView: DefinitionPeekView?
    var isPeeking: Bool { peekView != nil }

    // MARK: - Changed regions

    var changedLines = IndexSet()
    var jumpMarkerLine: Int?

    // MARK: - Blame gutter + file history

    var blameVisible = false

    // MARK: - Bookmarks

    var bookmarkedLines = IndexSet()

    // MARK: - Time-travel scrubber

    // Non-nil while scrubbing a file's history: the timeline of revisions, the
    // current slider position, and the scrubber bar. Leaving the mode
    // (exitTimeTravel) drops all three and reloads the working-tree file.
    var timeTravelTimeline: TimeTravelTimeline?
    var timeTravelPosition = 0
    var timeTravelBar: TimeTravelBarView?
    var timeTravelRelativePath: String?
    var timeTravelRoot: String?
    var isTimeTraveling: Bool { timeTravelTimeline != nil }

    // MARK: - Loading

    // Bumped per load; async highlight results from a superseded load drop out.
    var loadGeneration = 0

    func load(path: String, line: Int? = nil) {
        let standardized = (path as NSString).standardizingPath
        filePath = standardized
        loadGeneration += 1

        let text: String
        // Only real, in-bounds text is editable; the placeholders below stay
        // read-only so a save can never write a "Binary file" stub over a file.
        var editable = false
        if let data = FileManager.default.contents(atPath: standardized) {
            if data.count > Self.maxFileSize {
                text = "\(standardized)\n\nFile is too large for the viewer (\(data.count / (1024 * 1024)) MB)."
            } else if data.prefix(8192).contains(0) {
                text = "\(standardized)\n\nBinary file (\(data.count) bytes)."
            } else if let utf8 = String(bytes: data, encoding: .utf8) {
                text = utf8
                editable = true
            } else {
                // Not valid UTF-8 (e.g. Latin-1 / Windows-1252, no NUL bytes so
                // the binary guard above misses it). Show a best-effort lossy
                // decode but keep it READ-ONLY: our writer emits UTF-8, so saving
                // would rewrite every non-UTF-8 byte as U+FFFD and corrupt bytes
                // the user never touched.
                text = String(decoding: data, as: UTF8.self)
                editable = false
            }
        } else {
            text = "\(standardized)\n\nCould not read file."
        }

        // Editing state: the loaded text becomes the clean baseline;
        // record the file's mtime so an outside rewrite is detectable.
        isEditableFile = editable
        textView.isEditable = editable
        editState.markLoaded(text)
        savedModificationDate = modificationDate(ofPath: standardized)
        autosaveTimer?.invalidate(); autosaveTimer = nil
        rehighlightTimer?.invalidate(); rehighlightTimer = nil
        startWatchingFile(standardized)

        isLoadingProgrammatically = true
        textView.string = text
        isLoadingProgrammatically = false
        // Fresh document — don't let undo reach back into a previous file's edits.
        textView.undoManager?.removeAllActions()
        recomputeLineStarts(for: text)
        ruler.lineStarts = lineStarts
        ruler.updateThickness()
        ruler.needsDisplay = true
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scroll(.zero)

        // A new file means new blocks and a new outline; a fold set carried over
        // from the previous file would hide arbitrary lines of this one.
        foldedStarts = []
        foldRegions = []
        dismissPeek()
        refreshFoldRegions()
        refreshOutline()

        syntaxSpans = []
        changedLines = IndexSet()
        jumpMarkerLine = nil
        ruler.changedLines = IndexSet()
        ruler.blameByLine = [:]
        minimap.setMarkers([])
        rehighlight()
        refreshChangedLines()
        if blameVisible {
            loadBlame()
        }
        refreshBookmarks()

        tab?.contentTitleDidChange((standardized as NSString).lastPathComponent)
        // A reload starts clean — drop any leftover dirty indicator.
        tab?.contentDirtyDidChange(false)
        pane?.refreshChrome()

        // A different file (or the working tree returning after time-travel) means
        // different matches and possibly different editability; an open find bar
        // re-derives both rather than pointing into the old buffer.
        refreshFindEditability()

        if let line {
            jump(toLine: line)
        }
    }

    func recomputeLineStarts(for text: String) {
        var starts = [0]
        let ns = text as NSString
        var index = 0
        while index < ns.length {
            let range = ns.range(of: "\n", options: [], range: NSRange(location: index, length: ns.length - index))
            if range.location == NSNotFound { break }
            starts.append(range.location + 1)
            index = range.location + 1
        }
        lineStarts = starts
    }

    // MARK: - Jumping

    func jump(toLine line: Int) {
        guard !lineStarts.isEmpty else { return }
        let clamped = min(max(line, 1), lineStarts.count)
        // A jump must never land on a line a fold is hiding — expand whatever
        // covers it first, so go-to-definition, a bookmark and a search hit all
        // arrive somewhere the reader can actually see.
        revealLine(clamped)
        let start = lineStarts[clamped - 1]
        let end = clamped < lineStarts.count ? lineStarts[clamped] : (textView.string as NSString).length
        let range = NSRange(location: start, length: max(0, end - start))

        textView.setSelectedRange(NSRange(location: start, length: 0))
        textView.scrollRangeToVisible(range)

        // The jump target is marked on the minimap so "where did that link
        // take me" stays answerable after scrolling away.
        jumpMarkerLine = clamped
        updateMinimapMarkers()

        // A brief highlight so the eye lands on the right line, then fades out
        // of the way (temporary attributes never touch the document).
        guard let layoutManager = textView.layoutManager else { return }
        layoutManager.addTemporaryAttribute(
            .backgroundColor,
            value: Theme.accent.withAlphaComponent(0.3),
            forCharacterRange: range
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak layoutManager] in
            layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
    }

    // MARK: - Scroll persistence (state restoration)

    // The 1-based line at the top of the visible rect — captured at quit so
    // the next launch can put the viewer back where it was.
    var firstVisibleLine: Int {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              lineStarts.count > 1 else { return 1 }
        let top = NSPoint(x: 0, y: max(0, scrollView.contentView.bounds.minY - textView.textContainerInset.height) + 1)
        let glyph = layoutManager.glyphIndex(for: top, in: textContainer)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyph)
        for (i, start) in lineStarts.enumerated() where start > charIndex {
            return max(1, i)
        }
        return lineStarts.count
    }

    // jump(toLine:) with the attention-grabbing parts (selection move,
    // highlight, minimap marker) left out — restoring scroll shouldn't look
    // like a navigation event.
    func scrollTo(firstVisibleLine line: Int) {
        guard lineStarts.indices.contains(line - 1),
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let glyph = layoutManager.glyphIndexForCharacter(at: lineStarts[line - 1])
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY + textView.textContainerInset.height)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func promptForLine() {
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = "1 – \(lineStarts.count)"
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, let line = Int(field.stringValue) else { return }
        jump(toLine: line)
    }

    // Hand the current selection to AppDelegate as a Claude
    // goal, tagged with this file and the selection's line span so provenance
    // (when enabled) reads `From <file>:<start>-<end>:`.
    func setSelectionAsGoal() {
        let range = textView.selectedRange()
        guard range.length > 0 else { NSSound.beep(); return }
        let text = (textView.string as NSString).substring(with: range)
        let start = lineNumber(forCharacterAt: range.location)
        let end = lineNumber(forCharacterAt: range.location + range.length - 1)
        (NSApp.delegate as? AppDelegate)?.setSelectionAsGoal(text, file: filePath, startLine: start, endLine: end)
    }

    // The 1-based line owning a character offset (last line start ≤ offset),
    // by binary search over lineStarts — mirrors the gutter's own lookup.
    private func lineNumber(forCharacterAt offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low + 1
    }

    // MARK: - Word wrap (View ▸ Word Wrap, global setting owned by AppDelegate)

    private var wordWrap = true

    func setWordWrap(_ wrap: Bool) {
        guard wrap != wordWrap else { return }
        wordWrap = wrap
        scrollView.hasHorizontalScroller = !wrap
        textView.isHorizontallyResizable = !wrap
        if wrap {
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
            applyWrapWidth()
        } else {
            textView.autoresizingMask = []
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
            )
        }
        ruler.needsDisplay = true
    }

    // Sizes the wrap width to the clip area minus the gutter — used when word
    // wrap turns on and whenever the gutter's thickness changes (blame toggle),
    // so wrapped text reflows to the space the gutter leaves.
    func applyWrapWidth() {
        guard wordWrap else {
            ruler.needsDisplay = true
            return
        }
        // Re-tile first: hiding the horizontal scroller / a thickness change
        // resizes the clip view, and the wrap width must match the new size. The
        // gutter shares the clip area, so its thickness comes out of the wrap
        // width (matching what autoresizing produces on window resize).
        scrollView.tile()
        let width = max(0, scrollView.contentView.bounds.width - ruler.ruleThickness)
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
        ruler.needsDisplay = true
    }

    // MARK: - Appearance (shared with terminals — see PaneContent)

    var initialBackgroundColor: NSColor {
        Theme.bg
    }

    func applyFont(_ font: NSFont) {
        textView.font = font
        ruler.updateThickness()
        ruler.needsDisplay = true
    }

    func applyTextColor(_ color: NSColor) {
        baseTextColor = color
        textView.textColor = color
        textView.insertionPointColor = color
        ruler.textColor = color.withAlphaComponent(0.4)
        ruler.needsDisplay = true
        // textColor repaints the whole document in the base color; put the
        // syntax colors back on top.
        applySyntaxAttributes()
        rebuildMinimap()
    }

    func applyBackground(_ color: NSColor) {
        textView.backgroundColor = color
        ruler.gutterBackground = color
        ruler.needsDisplay = true
        minimap.backgroundColor = color
    }

    func teardown() {
        dismissPeek()
        autosaveTimer?.invalidate()
        rehighlightTimer?.invalidate()
        fileWatcher?.stop()
        fileWatcher = nil
        NotificationCenter.default.removeObserver(self)
    }
}
