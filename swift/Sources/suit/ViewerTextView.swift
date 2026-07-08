import Cocoa

// A read-only text view that knows which content owns it, mirroring
// PaneTerminalView's pattern, so menu actions (Go to Line) reach the viewer
// via the responder chain. Focus visuals are the window controller's job.
final class ViewerTextView: NSTextView {
    weak var viewerContent: FileViewerPaneContent?

    @objc func goToLine(_ sender: Any?) {
        viewerContent?.promptForLine()
    }

    // ROADMAP Phase 37 — write the editable buffer to disk (⌘S / palette).
    @objc func saveFile(_ sender: Any?) {
        viewerContent?.save()
    }

    @objc func toggleBlame(_ sender: Any?) {
        viewerContent?.toggleBlame()
    }

    @objc func showFileHistory(_ sender: Any?) {
        viewerContent?.showFileHistory()
    }

    // ROADMAP Phase 18 — send the selection into a Claude session as a `/goal`.
    @objc func setAsGoal(_ sender: Any?) {
        viewerContent?.setSelectionAsGoal()
    }

    @objc func toggleBookmark(_ sender: Any?) {
        viewerContent?.toggleBookmarkAtCurrentLine()
    }

    // Symbol navigation (ROADMAP Phase 33): the identifier under the caret /
    // selection resolves to its definition or a references list.
    @objc func goToDefinition(_ sender: Any?) {
        viewerContent?.goToDefinitionAtCaret()
    }

    @objc func findReferences(_ sender: Any?) {
        viewerContent?.findReferencesAtCaret()
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

    // Grey out File ▸ Save unless there's an editable file with unsaved edits
    // (Phase 37). Other actions keep NSTextView's own validation.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(saveFile(_:)) {
            return viewerContent?.canSave ?? false
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
        return menu
    }
}
