import Cocoa

// A read-only text view that knows which content owns it, mirroring
// PaneTerminalView's pattern, so menu actions (Go to Line) reach the viewer
// via the responder chain. Focus visuals are the window controller's job.
final class ViewerTextView: NSTextView {
    weak var viewerContent: FileViewerPaneContent?

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

    // Symbol navigation: the identifier under the caret /
    // selection resolves to its definition or a references list.
    @objc func goToDefinition(_ sender: Any?) {
        viewerContent?.goToDefinitionAtCaret()
    }

    @objc func findReferences(_ sender: Any?) {
        viewerContent?.findReferencesAtCaret()
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

    // Esc closes the bar from the text as well as from its fields — once you've
    // clicked back into the document, Esc is still the key that means "done
    // finding", and the stock bar behaves this way too.
    override func cancelOperation(_ sender: Any?) {
        if viewerContent?.findBar != nil {
            viewerContent?.closeFindBar()
        } else {
            super.cancelOperation(sender)
        }
    }

    // Cmd-click resolves the identifier under the pointer to its definition,
    // the semantic counterpart of the terminal's Cmd-click on a path link. Only
    // swallow the click when it actually landed on a symbol; otherwise fall
    // through to normal text selection.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let content = viewerContent,
           let layoutManager, let textContainer {
            var point = convert(event.locationInWindow, from: nil)
            point.x -= textContainerInset.width
            point.y -= textContainerInset.height
            let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
            let charIndex = layoutManager.characterIndexForGlyph(at: glyph)
            if content.goToDefinition(atCharacterOffset: charIndex) { return }
        }
        super.mouseDown(with: event)
    }

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
        return super.validateUserInterfaceItem(item)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copyItem = menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        copyItem.isEnabled = selectedRange().length > 0
        menu.addItem(withTitle: "Go to Definition", action: #selector(goToDefinition(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Find References", action: #selector(findReferences(_:)), keyEquivalent: "")
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
