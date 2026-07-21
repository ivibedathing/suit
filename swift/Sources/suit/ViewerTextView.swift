import Cocoa

// The viewer's text view: knows which content owns it, mirroring
// PaneTerminalView's pattern, so menu actions (Go to Line, fold, peek) reach the
// viewer via the responder chain. Focus visuals are the window controller's job.
//
// It is also where every input that the plain NSTextView behaviour isn't good
// enough for gets intercepted — typing (auto-close, auto-indent, several
// cursors), ⌥-click and ⌥-drag, and ⌘-hover. The rule for all of them is the
// same: ask the content whether it wants the event, and call super the moment it
// says no. Anything else and paste, IME, dictation and accessibility break in
// ways that are very hard to trace back here.
final class ViewerTextView: NSTextView {
    weak var viewerContent: FileViewerPaneContent?

    // MARK: - TextKit stack

    // Built by hand rather than taking NSTextView's default stack, because
    // folding needs a FoldingLayoutManager in it — that's the only supported
    // seam in TextKit 1 for laying text out as nothing.
    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layoutManager = FoldingLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        super.init(frame: frameRect, textContainer: container)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc func goToLine(_ sender: Any?) {
        viewerContent?.promptForLine()
    }

    // Write the editable buffer to disk (⌘S / palette).
    @objc func saveFile(_ sender: Any?) {
        viewerContent?.save()
    }

    @objc func toggleBlame(_ sender: Any?) {
        viewerContent?.toggleBlame()
    }

    @objc func showFileHistory(_ sender: Any?) {
        viewerContent?.showFileHistory()
    }

    // Scrub the open file backward through its git history.
    @objc func toggleTimeTravel(_ sender: Any?) {
        viewerContent?.toggleTimeTravel()
    }

    // Send the selection into a Claude session as a `/goal`.
    @objc func setAsGoal(_ sender: Any?) {
        viewerContent?.setSelectionAsGoal()
    }

    @objc func toggleBookmark(_ sender: Any?) {
        viewerContent?.toggleBookmarkAtCurrentLine()
    }

    // MARK: - Symbol navigation

    // The identifier under the caret / selection resolves to its definition or a
    // references list.
    @objc func goToDefinition(_ sender: Any?) {
        viewerContent?.goToDefinitionAtCaret()
    }

    @objc func findReferences(_ sender: Any?) {
        viewerContent?.findReferencesAtCaret()
    }

    // ⌥⌘J — read the definition in place instead of navigating to it.
    @objc func peekDefinition(_ sender: Any?) {
        viewerContent?.peekDefinitionAtCaret()
    }

    // ⌃⌘O — the current file’s symbols as a picker.
    @objc func goToSymbolInFile(_ sender: Any?) {
        viewerContent?.showSymbolOutline()
    }

    // MARK: - Editing commands

    @objc func indentSelection(_ sender: Any?) {
        viewerContent?.indentSelectedLines()
    }

    @objc func outdentSelection(_ sender: Any?) {
        viewerContent?.outdentSelectedLines()
    }

    @objc func toggleLineComment(_ sender: Any?) {
        viewerContent?.toggleCommentOnSelection()
    }

    @objc func selectNextOccurrence(_ sender: Any?) {
        viewerContent?.selectNextOccurrence()
    }

    @objc func selectAllOccurrences(_ sender: Any?) {
        viewerContent?.selectAllOccurrences()
    }

    // MARK: - Folding commands

    @objc func foldBlock(_ sender: Any?) {
        viewerContent?.foldAtCaret()
    }

    @objc func unfoldBlock(_ sender: Any?) {
        viewerContent?.unfoldAtCaret()
    }

    @objc func foldAllBlocks(_ sender: Any?) {
        viewerContent?.foldAll()
    }

    @objc func unfoldAllBlocks(_ sender: Any?) {
        viewerContent?.unfoldAll()
    }

    // MARK: - Typing

    // Single printable characters get the smart-typing treatment (auto-close,
    // skip-over, wrap-selection, and application at every cursor). Everything
    // else — paste, IME commits, dictation, attributed insertions — goes
    // straight to NSTextView.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let text = string as? String, text.count == 1, replacementRange.location == NSNotFound,
           let character = text.first, !character.isNewline,
           viewerContent?.handleTyping(character) == true {
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func insertNewline(_ sender: Any?) {
        // A peek is open: Return promotes it to a jump rather than typing into
        // the buffer hidden behind it.
        if viewerContent?.promotePeekToJump() == true { return }
        if viewerContent?.handleNewline() == true { return }
        super.insertNewline(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        if viewerContent?.handleDeleteBackward() == true { return }
        super.deleteBackward(sender)
    }

    // Tab over a multi-line selection indents the block; a plain Tab is still a
    // Tab, and with several cursors it types at each of them.
    override func insertTab(_ sender: Any?) {
        if viewerContent?.shouldIndentSelection() == true {
            viewerContent?.indentSelectedLines()
            return
        }
        if viewerContent?.hasMultipleCursors == true,
           viewerContent?.handleTyping("\t") == true {
            return
        }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if viewerContent?.smartTypingActive == true {
            viewerContent?.outdentSelectedLines()
            return
        }
        super.insertBacktab(sender)
    }

    // MARK: - Find

    // ⌘F / ⌘G / ⇧⌘G / ⌘E all arrive here as NSFindPanelAction tags (the standard
    // Find menu items — see AppDelegate+Menu). The viewer answers them with its
    // own themed find/replace bar rather than NSTextView's stock one, so this
    // intercepts the whole family instead of calling super. Terminals implement
    // the same selector via SwiftTerm and are untouched.
    override func performFindPanelAction(_ sender: Any?) {
        let raw = (sender as? NSMenuItem)?.tag ?? Int(NSFindPanelAction.showFindPanel.rawValue)
        guard raw >= 0, let action = NSFindPanelAction(rawValue: UInt(raw)) else { return }
        viewerContent?.performFind(action)
    }

    // ⌥⌘F. A dedicated selector rather than a find-panel tag: NSFindPanelAction
    // has no "show replace interface" case (that's NSTextFinder's vocabulary),
    // and a viewer-only selector also means the item greys out on its own when a
    // terminal is focused, with no tag validation to get right.
    @objc func showFindAndReplace(_ sender: Any?) {
        viewerContent?.showFindAndReplace()
    }

    // Esc unwinds one layer at a time, innermost first: the peek popover, then
    // extra cursors, then the find bar. Collapsing everything at once would make
    // Esc unusable for the common case of dismissing a peek you opened while
    // mid-find.
    override func cancelOperation(_ sender: Any?) {
        if viewerContent?.isPeeking == true {
            viewerContent?.dismissPeek()
        } else if viewerContent?.hasMultipleCursors == true {
            viewerContent?.collapseToSingleCursor()
        } else if viewerContent?.findBar != nil {
            viewerContent?.closeFindBar()
        } else {
            super.cancelOperation(sender)
        }
    }

    // MARK: - Mouse

    // The document character index under a mouse event.
    private func characterIndex(for event: NSEvent) -> Int {
        guard let layoutManager, let textContainer else { return 0 }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerInset.width
        point.y -= textContainerInset.height
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    // ⌘-click jumps to the definition (the semantic counterpart of the
    // terminal's ⌘-click on a path link), ⌥⌘-click peeks at it inline, and
    // ⌥-click / ⌥-drag place extra cursors or a column selection. Anything not
    // claimed falls through to normal text selection.
    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains([.command, .option]), let content = viewerContent {
            if content.peekDefinition(atCharacterOffset: characterIndex(for: event)) { return }
        }

        if flags.contains(.command), !flags.contains(.option), let content = viewerContent {
            clearCommandHover()
            if content.goToDefinition(atCharacterOffset: characterIndex(for: event)) { return }
        }

        if flags.contains(.option), !flags.contains(.command), let content = viewerContent,
           content.smartTypingActive {
            beginOptionSelection(from: event, content: content)
            return
        }

        super.mouseDown(with: event)
    }

    // ⌥-drag paints a rectangular selection. NSTextView's own mouseDown runs its
    // own tracking loop, which is why this can't just set a flag and call super.
    //
    // A bare ⌥-click used to drop an extra caret here. It can't work: AppKit
    // collapses a selectedRanges made only of zero-length ranges down to one, so
    // the extra carets never existed to begin with — the click was a no-op
    // pretending to be a feature.
    private func beginOptionSelection(from event: NSEvent, content: FileViewerPaneContent) {
        let anchor = characterIndex(for: event)

        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            content.setColumnSelection(from: anchor, to: characterIndex(for: next))
            autoscroll(with: next)
        }
    }

    // MARK: - ⌘-hover link affordance

    // The identifier currently underlined because ⌘ is held over it. Held so the
    // temporary attributes can be removed from exactly the range they were added
    // to — layout shifts under an edit, and clearing "wherever it was" is how
    // stale underlines get left behind.
    private var commandHoverRange: NSRange?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateCommandHover(at: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearCommandHover()
    }

    // ⌘ pressed or released without the pointer moving still has to light the
    // link up (or put it out) — that's the whole affordance.
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        updateCommandHover(at: event)
    }

    private func updateCommandHover(at event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.option),
              let content = viewerContent, let layoutManager else {
            clearCommandHover()
            return
        }

        // Where the pointer actually is — flagsChanged carries the modifier but
        // not a useful location, so it's read from the window either way.
        guard let windowPoint = window?.mouseLocationOutsideOfEventStream else {
            clearCommandHover()
            return
        }
        var point = convert(windowPoint, from: nil)
        guard bounds.contains(point) else { clearCommandHover(); return }
        point.x -= textContainerInset.width
        point.y -= textContainerInset.height
        guard let textContainer else { clearCommandHover(); return }

        // glyphIndex(for:) clamps to the nearest glyph, so a pointer in the empty
        // space right of a short line would "hover" its last word. Requiring the
        // point to actually fall inside the glyph's rect is what keeps the
        // underline honest.
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
        let bounding = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard bounding.contains(point) else { clearCommandHover(); return }

        let offset = layoutManager.characterIndexForGlyph(at: glyph)
        guard let range = content.symbolRange(atCharacterOffset: offset) else {
            clearCommandHover()
            return
        }
        guard range != commandHoverRange else {
            NSCursor.pointingHand.set()
            return
        }

        clearCommandHover()
        layoutManager.addTemporaryAttributes([
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: Theme.accent,
            .foregroundColor: Theme.accent,
        ], forCharacterRange: range)
        commandHoverRange = range
        NSCursor.pointingHand.set()
    }

    func clearCommandHover() {
        guard let range = commandHoverRange else { return }
        commandHoverRange = nil
        let length = (string as NSString).length
        if NSMaxRange(range) <= length {
            layoutManager?.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
            layoutManager?.removeTemporaryAttribute(.underlineColor, forCharacterRange: range)
            layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        }
        // Put the syntax colour back — removeTemporaryAttribute drops our accent
        // but the document attribute underneath is what the character should be.
        viewerContent?.applySyntaxAttributes()
        NSCursor.iBeam.set()
    }

    // MARK: - Validation

    // Grey out File ▸ Save unless there's an editable file with unsaved edits.
    // Other actions keep NSTextView's own validation.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(saveFile(_:)) {
            return viewerContent?.canSave ?? false
        }
        // Time-travel needs a real file; reflect the active state as a check.
        if item.action == #selector(toggleTimeTravel(_:)) {
            (item as? NSMenuItem)?.state = (viewerContent?.isTimeTraveling ?? false) ? .on : .off
            return viewerContent?.filePath != nil
        }
        // Find must be validated explicitly: NSTextView disables the find actions
        // whenever usesFindBar is false, which it is here (we answer ⌘F with our
        // own bar). Falling through to super would grey out the entire Find menu
        // in the viewer.
        if item.action == #selector(performFindPanelAction(_:)) {
            return true
        }
        // Replace needs somewhere to write: read-only revisions and the
        // binary/too-large placeholders can be searched but not edited.
        if item.action == #selector(showFindAndReplace(_:)) {
            return isEditable
        }
        // Editing commands need a writable buffer.
        if item.action == #selector(indentSelection(_:)) || item.action == #selector(outdentSelection(_:))
            || item.action == #selector(toggleLineComment(_:)) || item.action == #selector(selectNextOccurrence(_:))
            || item.action == #selector(selectAllOccurrences(_:)) {
            return viewerContent?.smartTypingActive ?? false
        }
        // Folding is a view state, so it works in read-only buffers too — but
        // only where something is actually foldable.
        if item.action == #selector(foldBlock(_:)) || item.action == #selector(foldAllBlocks(_:)) {
            return !(viewerContent?.foldRegions.isEmpty ?? true)
        }
        if item.action == #selector(unfoldBlock(_:)) || item.action == #selector(unfoldAllBlocks(_:)) {
            return !(viewerContent?.foldedStarts.isEmpty ?? true)
        }
        if item.action == #selector(goToSymbolInFile(_:)) || item.action == #selector(peekDefinition(_:)) {
            return viewerContent?.filePath != nil
        }
        return super.validateUserInterfaceItem(item)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copyItem = menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        copyItem.isEnabled = selectedRange().length > 0
        menu.addItem(withTitle: "Go to Definition", action: #selector(goToDefinition(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Peek Definition", action: #selector(peekDefinition(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Find References", action: #selector(findReferences(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Go to Symbol in File…", action: #selector(goToSymbolInFile(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Toggle Comment", action: #selector(toggleLineComment(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select Next Occurrence", action: #selector(selectNextOccurrence(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Fold Block", action: #selector(foldBlock(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Unfold Block", action: #selector(unfoldBlock(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Go to Line…", action: #selector(goToLine(_:)), keyEquivalent: "")
        let goalItem = menu.addItem(withTitle: "Set as Goal", action: #selector(setAsGoal(_:)), keyEquivalent: "")
        goalItem.isEnabled = selectedRange().length > 0
        menu.addItem(withTitle: "Toggle Bookmark", action: #selector(toggleBookmark(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let blameItem = menu.addItem(withTitle: "Toggle Blame", action: #selector(toggleBlame(_:)), keyEquivalent: "")
        blameItem.state = (viewerContent?.blameVisible ?? false) ? .on : .off
        menu.addItem(withTitle: "Show File History", action: #selector(showFileHistory(_:)), keyEquivalent: "")
        let timeTravelItem = menu.addItem(withTitle: "Time Travel", action: #selector(toggleTimeTravel(_:)), keyEquivalent: "")
        timeTravelItem.state = (viewerContent?.isTimeTraveling ?? false) ? .on : .off
        return menu
    }
}
