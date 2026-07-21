import Cocoa

// Peek Definition: resolve the symbol under the caret (or pointer) and show its
// source inline instead of navigating to it. The lookup is the same
// SymbolIndex one go-to-definition uses — peek and jump can never disagree
// about where a symbol lives, because they ask the same question and only
// differ in what they do with the answer.
extension FileViewerPaneContent {

    // MARK: - Entry points

    func peekDefinitionAtCaret() {
        guard let symbol = symbolAtCaret() else { NSSound.beep(); return }
        presentPeek(for: symbol, anchoredAt: textView.selectedRange().location)
    }

    // ⌥⌘-click. Returns whether an identifier was actually under the pointer, so
    // the text view knows whether to swallow the click.
    @discardableResult
    func peekDefinition(atCharacterOffset offset: Int) -> Bool {
        guard let symbol = symbol(atCharacterOffset: offset) else { return false }
        presentPeek(for: symbol, anchoredAt: offset)
        return true
    }

    // MARK: - Presenting

    private func presentPeek(for symbol: String, anchoredAt offset: Int) {
        guard let directory = workingDirectory else { NSSound.beep(); return }
        let root = FileIndex.gitRoot(of: directory) ?? directory
        let definitions = SymbolIndex.shared(forDirectory: root).definitions(for: symbol)

        guard let definition = definitions.first else {
            // Nothing indexed: peek has nothing to show, and silently doing
            // nothing would read as a broken shortcut. Fall through to the
            // existing go-to-definition path, which explains itself (references
            // pane with a header note).
            pane?.goToDefinition(symbol: symbol, fromDirectory: workingDirectory)
            return
        }

        let absolute = root + "/" + definition.relativePath
        guard let excerpt = excerpt(ofFile: absolute, aroundLine: definition.lineNumber) else {
            NSSound.beep()
            return
        }

        dismissPeek()
        let peek = DefinitionPeekView()
        let others = definitions.count > 1 ? "  (+\(definitions.count - 1) more)" : ""
        peek.show(
            header: "\(definition.relativePath):\(definition.lineNumber)\(others)",
            source: excerpt.text,
            highlightedLineOffset: excerpt.highlightOffset,
            font: textView.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            textColor: baseTextColor,
            spans: SyntaxHighlighter.highlight(
                text: excerpt.text,
                language: CodeLanguage.detect(path: absolute) ?? .swift
            )
        )
        peek.onOpen = { [weak self] in
            guard let self else { return }
            self.dismissPeek()
            // Several definitions still deserve the picker — promoting a peek
            // shouldn't silently pick the first one for you.
            self.pane?.goToDefinition(symbol: symbol, fromDirectory: self.workingDirectory)
        }
        peek.onDismiss = { [weak self] in self?.dismissPeek() }

        peekView = peek
        container.peekOverlay = peek
        container.positionPeek(nearCharacterOffset: offset, in: textView)
    }

    // Return promotes the peek to a real jump — what the popover's own hint
    // ("esc to close · return to open") has always advertised.
    //
    // This has to be checked *before* the editor's newline handling. The peek
    // deliberately never takes first responder, so without this the key reaches
    // the text view and auto-indents a newline into the file behind the popover
    // — a buffer that autosaves to disk a second later. Esc was already routed
    // through cancelOperation; Return was not.
    func promotePeekToJump() -> Bool {
        guard let peek = peekView else { return false }
        peek.onOpen?()
        return true
    }

    func dismissPeek() {
        guard peekView != nil else { return }
        peekView = nil
        container.peekOverlay = nil
        // Focus goes back to the text — the peek never took first responder, but
        // a click inside its source view could have.
        textView.window?.makeFirstResponder(textView)
    }

    // MARK: - Reading the definition

    // A few lines of `path` centred on `line`, plus which line of the excerpt is
    // the declaration. Read straight from disk rather than through a tab: peek
    // must not open, dedupe or otherwise disturb the tab list, and the file is
    // small change to read.
    private func excerpt(ofFile path: String, aroundLine line: Int) -> (text: String, highlightOffset: Int)? {
        guard let data = FileManager.default.contents(atPath: path),
              data.count <= 8 * 1024 * 1024,
              !data.prefix(8192).contains(0),
              let text = String(bytes: data, encoding: .utf8) else { return nil }

        let lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line - 1) else { return nil }

        // One line of lead-in (so an attribute or doc-comment line above the
        // declaration is visible) and enough body to be worth reading.
        let before = 1
        let after = 12
        let start = max(0, line - 1 - before)
        let end = min(lines.count - 1, line - 1 + after)
        return (lines[start...end].joined(separator: "\n"), (line - 1) - start)
    }
}
