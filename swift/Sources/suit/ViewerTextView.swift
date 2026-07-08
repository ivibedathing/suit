import Cocoa

// A read-only text view that knows which content owns it, mirroring
// PaneTerminalView's pattern, so menu actions (Go to Line) reach the viewer
// via the responder chain. Focus visuals are the window controller's job.
final class ViewerTextView: NSTextView {
    weak var viewerContent: FileViewerPaneContent?

    @objc func goToLine(_ sender: Any?) {
        viewerContent?.promptForLine()
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

    // ROADMAP Phase 33 — symbol navigation. The palette / menu-bar routes here
    // through the responder chain (like Go to Line); the identifier is the one
    // at the caret or the current selection.
    @objc func goToDefinition(_ sender: Any?) {
        viewerContent?.goToDefinitionAtCaret()
    }

    @objc func findReferences(_ sender: Any?) {
        viewerContent?.findReferencesAtCaret()
    }

    // Right-click items act on the word under the click, carried on the menu
    // item so the caret needn't move.
    @objc private func goToDefinitionAtClick(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        viewerContent?.pane?.goToDefinition(identifier: identifier, fromFile: viewerContent?.filePath)
    }

    @objc private func findReferencesAtClick(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        viewerContent?.pane?.findReferences(identifier: identifier, fromFile: viewerContent?.filePath)
    }

    // Cmd-click an identifier → go to its definition (the viewer's implicit-link
    // interception, mirroring the terminal's Cmd-click on path-shaped tokens).
    // Swallowed so it doesn't also move the selection; a plain click still
    // selects normally.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let point = convert(event.locationInWindow, from: nil)
            let index = characterIndexForInsertion(at: point)
            if let identifier = viewerContent?.identifier(atCharacterIndex: index) {
                viewerContent?.pane?.goToDefinition(identifier: identifier, fromFile: viewerContent?.filePath)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copyItem = menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        copyItem.isEnabled = selectedRange().length > 0

        // Symbol items when the click lands on an identifier (ROADMAP Phase 33).
        let point = convert(event.locationInWindow, from: nil)
        let clickIndex = characterIndexForInsertion(at: point)
        if let identifier = viewerContent?.identifier(atCharacterIndex: clickIndex) {
            menu.addItem(.separator())
            let defItem = menu.addItem(withTitle: "Go to Definition of “\(identifier)”",
                                       action: #selector(goToDefinitionAtClick(_:)), keyEquivalent: "")
            defItem.representedObject = identifier
            let refItem = menu.addItem(withTitle: "Find References to “\(identifier)”",
                                       action: #selector(findReferencesAtClick(_:)), keyEquivalent: "")
            refItem.representedObject = identifier
        }

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
