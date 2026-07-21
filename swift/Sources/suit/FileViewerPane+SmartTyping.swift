import Cocoa

// The typing intelligence the viewer gained when it stopped being read-only:
// auto-indent on Return, bracket/quote auto-close (with skip-over, wrap-selection
// and pair-delete), indent/outdent (⌃⌘] / ⌃⌘[) and comment toggling (⌘/).
//
// Every decision here is made by EditorOps, which is Foundation-only and
// harness-tested; this file's job is strictly to ask the right question, route
// the answer through editAtAllCursors so it applies at every cursor as one undo
// step, and hand anything it doesn't claim back to NSTextView unchanged. The
// "hand it back" half matters: the moment smart typing swallows an input it
// didn't understand, IME, dictation and paste all break in ways that are very
// hard to attribute.
extension FileViewerPaneContent {

    // The language of the open file, for indent width, comment marker and brace
    // style. Recomputed per keystroke rather than cached — it's a string switch
    // on the extension, and caching it means a stale answer after a rename.
    var editorLanguage: EditorLanguage {
        EditorLanguage.detect(path: filePath ?? "")
    }

    // Whether the smart-typing layer should act at all. Read-only buffers (a
    // time-travel revision, the binary placeholder) type nothing, and the find
    // bar's own fields are separate views, so this is the only gate needed.
    var smartTypingActive: Bool { isEditableFile && textView.isEditable }

    // MARK: - Character input

    // Returns true when this input was fully handled here. Called from
    // ViewerTextView.insertText for single printable characters only — multi-
    // character input (paste, IME commit, dictation) always falls through, since
    // pairing a bracket in the middle of a pasted blob is never what's wanted.
    func handleTyping(_ character: Character) -> Bool {
        guard smartTypingActive else { return false }
        let text = textView.string
        let ranges = cursorRanges

        // With a selection, an opener wraps it rather than replacing it.
        if ranges.contains(where: { $0.length > 0 }) {
            guard let sample = ranges.first(where: { $0.length > 0 }),
                  EditorOps.wrap((text as NSString).substring(with: sample), with: character) != nil else {
                return false
            }
            return editAtAllCursors { range in
                let selected = (text as NSString).substring(with: range)
                guard let wrapped = EditorOps.wrap(selected, with: character) else { return nil }
                // Caret after the wrapped text, so typing another opener wraps
                // again — `((foo))` in two keystrokes.
                return (range, wrapped, (wrapped as NSString).length)
            }
        }

        // Bare carets: ask per cursor, because the same keystroke can legitimately
        // pair at one caret and skip over a closer at another.
        var actions: [Int: EditorOps.TypingAction] = [:]
        for range in ranges {
            actions[range.location] = EditorOps.typingAction(
                text: text, offset: range.location, character: character, language: editorLanguage
            )
        }
        // Nothing clever to do anywhere — let NSTextView insert it, so undo
        // coalescing and typing attributes stay exactly as they always were.
        guard actions.values.contains(where: { $0 != .insert(String(character)) }) else { return false }

        return editAtAllCursors { range in
            switch actions[range.location] ?? .insert(String(character)) {
            case .insert(let s):
                return (range, s, (s as NSString).length)
            case .insertPair(let pair):
                return (range, pair, 1)                // caret between the halves
            case .skipOver:
                // Insert nothing and step the caret past the closer that's
                // already there.
                return (range, "", 1)
            }
        }
    }

    // MARK: - Return

    func handleNewline() -> Bool {
        guard smartTypingActive else { return false }
        let text = textView.string

        return editAtAllCursors { range in
            let decision = EditorOps.newlineIndent(
                text: text, offset: range.location, language: self.editorLanguage
            )
            let opened = "\n" + decision.indent
            guard let closing = decision.closingLine else {
                return (range, opened, (opened as NSString).length)
            }
            // `{|}` — open a blank indented line and push the closer down. The
            // caret stays on the new blank line, not after the closer.
            let full = opened + "\n" + closing
            return (range, full, (opened as NSString).length)
        }
    }

    // MARK: - Backspace

    func handleDeleteBackward() -> Bool {
        guard smartTypingActive else { return false }
        let text = textView.string
        let ranges = cursorRanges

        // Only claim backspace when it's a pair-delete at *some* caret, or when
        // there are several cursors (NSTextView would only delete at one).
        let anyPair = ranges.contains {
            $0.length == 0 && EditorOps.shouldDeletePair(text: text, offset: $0.location)
        }
        guard anyPair || hasMultipleCursors else { return false }

        return editAtAllCursors { range in
            // A selection deletes itself, at every cursor that has one.
            if range.length > 0 { return (range, "", 0) }
            guard range.location > 0 else { return nil }
            // Between the halves of an empty pair: take both.
            if EditorOps.shouldDeletePair(text: text, offset: range.location) {
                return (NSRange(location: range.location - 1, length: 2), "", 0)
            }
            return (NSRange(location: range.location - 1, length: 1), "", 0)
        }
    }

    // MARK: - Indent / outdent / comment

    // Tab with a multi-line selection (or several cursors) indents the block;
    // otherwise Tab is still just a tab.
    func shouldIndentSelection() -> Bool {
        guard smartTypingActive else { return false }
        if hasMultipleCursors { return false }          // Tab types at every caret instead
        let range = textView.selectedRange()
        guard range.length > 0 else { return false }
        return EditorOps.lineIndices(touching: range, lineStarts: lineStarts).count > 1
    }

    func indentSelectedLines() { rewriteSelectedLines { EditorOps.indent(lines: $0, language: $1) } }
    func outdentSelectedLines() { rewriteSelectedLines { EditorOps.outdent(lines: $0, language: $1) } }

    func toggleCommentOnSelection() {
        rewriteSelectedLines { EditorOps.toggleComment(lines: $0, language: $1) }
    }

    // The shared shape of every whole-line rewrite: take the lines the selection
    // touches, hand them to a pure transform, splice the result back as one
    // undoable edit, and keep the selection over the same text.
    private func rewriteSelectedLines(_ transform: ([String], EditorLanguage) -> EditorOps.LineRewrite?) {
        guard smartTypingActive, let storage = textView.textStorage else { NSSound.beep(); return }

        let ns = textView.string as NSString
        let selection = textView.selectedRange()
        let indices = EditorOps.lineIndices(touching: selection, lineStarts: lineStarts)
        guard let firstLine = indices.first, let lastLine = indices.last,
              let firstRange = EditorOps.lineRange(firstLine, lineStarts: lineStarts, length: ns.length),
              let lastRange = EditorOps.lineRange(lastLine, lineStarts: lineStarts, length: ns.length)
        else { NSSound.beep(); return }

        // The block's full range, and its lines with newlines stripped — the
        // transform works on bare lines so it never has to think about whether
        // the file ends in one.
        let blockRange = NSRange(location: firstRange.location,
                                 length: NSMaxRange(lastRange) - firstRange.location)
        var block = ns.substring(with: blockRange)
        let hadTrailingNewline = block.hasSuffix("\n")
        if hadTrailingNewline { block = String(block.dropLast()) }
        let lines = block.components(separatedBy: "\n")

        guard let rewrite = transform(lines, editorLanguage) else { NSSound.beep(); return }
        var replacement = rewrite.lines.joined(separator: "\n")
        if hadTrailingNewline { replacement += "\n" }

        guard textView.shouldChangeText(in: blockRange, replacementString: replacement) else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: blockRange,
                                  with: NSAttributedString(string: replacement, attributes: textView.typingAttributes))
        storage.endEditing()
        textView.didChangeText()

        // Keep the same text selected. A caret (no selection) just shifts with
        // its own line; a range grows or shrinks by the total delta.
        if selection.length == 0 {
            let moved = max(firstRange.location, selection.location + rewrite.firstLineDelta)
            textView.setSelectedRange(NSRange(location: min(moved, (textView.string as NSString).length), length: 0))
        } else {
            let start = max(firstRange.location, selection.location + rewrite.firstLineDelta)
            let length = max(0, selection.length + rewrite.totalDelta - rewrite.firstLineDelta)
            let clamped = min(length, (textView.string as NSString).length - start)
            textView.setSelectedRange(NSRange(location: start, length: max(0, clamped)))
        }
    }
}
