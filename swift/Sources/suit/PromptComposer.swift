import Cocoa

// ROADMAP Phase 8 — talk back: steering Claude sessions by writing into their
// pane's pty. Text arrives as if typed (no new protocol, no Claude-side
// changes), so the app becomes a control surface for many sessions, not just
// a viewer of them.

// The pty-side send primitives shared by the quick actions, the composer, the
// prompt library, and Send Selection.
enum SessionControl {
    // Claude Code (and modern shells) run with bracketed paste on; wrapping
    // the payload keeps embedded newlines as literal input-box newlines
    // instead of submitting at the first \n.
    // submitDelay: how long the TUI gets to consume the paste before the CR;
    // Autopilot passes 0.5 s for its multi-KB worker prompts.
    static func send(text: String, to terminal: TerminalPaneContent, submit: Bool, submitDelay: TimeInterval = 0.15) {
        terminal.terminalView.send(txt: "\u{1b}[200~" + text + "\u{1b}[201~")
        if submit {
            // A beat later, so the TUI has consumed the paste before Enter.
            DispatchQueue.main.asyncAfter(deadline: .now() + submitDelay) { [weak terminal] in
                terminal?.terminalView.send(txt: "\r")
            }
        }
    }

    // Esc — interrupts whatever the session is doing, exactly like pressing
    // it in the pane.
    static func interrupt(_ terminal: TerminalPaneContent) {
        terminal.terminalView.send(txt: "\u{1b}")
    }
}

// The session quick actions surfaced in the Sessions tab's context menu and
// the command palette.
enum SessionQuickAction {
    case continueSession
    case compact
    case interrupt

    var title: String {
        switch self {
        case .continueSession: return "Continue"
        case .compact: return "/compact"
        case .interrupt: return "Interrupt (Esc)"
        }
    }

    func perform(on terminal: TerminalPaneContent) {
        switch self {
        case .continueSession: SessionControl.send(text: "continue", to: terminal, submit: true)
        case .compact: SessionControl.send(text: "/compact", to: terminal, submit: true)
        case .interrupt: SessionControl.interrupt(terminal)
        }
    }
}

// A borderless floating panel refuses key status unless told otherwise, and
// the composer's text view needs it.
private final class ComposerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// The multi-line text view: Enter sends, Shift-Enter newlines, and while the
// @-completion list is up, arrows/Tab/Enter drive it — all routed through
// doCommandBy via the owning controller.
private final class ComposerTextView: NSTextView {}

// The prompt composer (ROADMAP Phase 8): the command-palette machinery grown
// a multi-line text view, targeting a chosen session. "@" completes over the
// project's FileIndex and inserts repo-relative paths.
final class PromptComposerController: NSObject, NSWindowDelegate, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: ComposerPanel
    private let targetLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "Enter sends · ⇧Enter newline · @ completes file paths · Esc closes")
    private let textView = ComposerTextView(frame: .zero)
    private let textScroll = NSScrollView(frame: .zero)
    private let suggestionTable = NSTableView(frame: .zero)
    private let suggestionScroll = NSScrollView(frame: .zero)

    private var terminal: TerminalPaneContent?
    private var fileIndex: FileIndex?
    private var suggestions: [String] = []
    // The "@token" character range the accepted suggestion replaces.
    private var completionRange: NSRange?

    private static let panelWidth: CGFloat = 560
    private static let headerHeight: CGFloat = 30
    private static let textHeight: CGFloat = 96
    private static let hintHeight: CGFloat = 22
    private static let suggestionRowHeight: CGFloat = 20

    override init() {
        panel = ComposerPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false

        super.init()

        panel.delegate = self

        // Flat overlay surface (Phase 11), replacing the .menu vibrancy.
        let effect = NSView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 100))
        effect.wantsLayer = true
        effect.layer?.backgroundColor = Theme.overlay.cgColor
        effect.layer?.cornerRadius = Theme.Metrics.overlayRadius
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = Theme.hairline.cgColor
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        panel.contentView = effect

        targetLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        targetLabel.textColor = Theme.textDim
        targetLabel.lineBreakMode = .byTruncatingTail
        effect.addSubview(targetLabel)

        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.delegate = self
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.drawsBackground = false
        textView.drawsBackground = false
        effect.addSubview(textScroll)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        suggestionTable.addTableColumn(column)
        suggestionTable.headerView = nil
        suggestionTable.rowHeight = Self.suggestionRowHeight
        suggestionTable.backgroundColor = .clear
        suggestionTable.dataSource = self
        suggestionTable.delegate = self
        suggestionTable.target = self
        suggestionTable.action = #selector(suggestionClicked)
        suggestionScroll.documentView = suggestionTable
        suggestionScroll.hasVerticalScroller = true
        suggestionScroll.drawsBackground = false
        suggestionScroll.isHidden = true
        effect.addSubview(suggestionScroll)

        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = Theme.textFaint
        effect.addSubview(hintLabel)
    }

    // Shows the composer aimed at `session`'s terminal. `prefill` seeds the
    // text (Send Selection pipes the selection in this way) with the caret at
    // the start so context can be typed in front of it.
    func show(
        target session: ClaudeSession,
        terminal: TerminalPaneContent,
        fileIndex: FileIndex?,
        relativeTo window: NSWindow?,
        prefill: String = ""
    ) {
        self.terminal = terminal
        self.fileIndex = fileIndex
        let project = (session.cwd as NSString?)?.lastPathComponent ?? ""
        targetLabel.stringValue = "To: \(session.displayName)\(project.isEmpty ? "" : " · \(project)") — \(session.state.label)"
        textView.string = prefill
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        hideSuggestions()

        layoutPanel()
        if let window {
            let frame = window.frame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - Self.panelWidth / 2,
                y: frame.midY - panel.frame.height / 2 + 80
            ))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
    }

    func windowDidResignKey(_ notification: Notification) {
        panel.orderOut(nil)
    }

    private func layoutPanel() {
        let suggestionsHeight: CGFloat = suggestionScroll.isHidden
            ? 0
            : min(CGFloat(suggestions.count), 8) * Self.suggestionRowHeight + 4
        let height = Self.headerHeight + Self.textHeight + suggestionsHeight + Self.hintHeight
        let origin = panel.frame.origin
        let oldHeight = panel.frame.height
        panel.setFrame(
            NSRect(x: origin.x, y: origin.y + oldHeight - height, width: Self.panelWidth, height: height),
            display: true
        )

        targetLabel.frame = NSRect(x: 16, y: height - Self.headerHeight + 6, width: Self.panelWidth - 32, height: 18)
        textScroll.frame = NSRect(x: 8, y: height - Self.headerHeight - Self.textHeight, width: Self.panelWidth - 16, height: Self.textHeight)
        suggestionScroll.frame = NSRect(x: 8, y: Self.hintHeight, width: Self.panelWidth - 16, height: suggestionsHeight)
        hintLabel.frame = NSRect(x: 16, y: 4, width: Self.panelWidth - 32, height: 14)
    }

    // MARK: - Sending

    private func sendAndClose() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let terminal, !text.isEmpty else {
            NSSound.beep()
            return
        }
        SessionControl.send(text: text, to: terminal, submit: true)
        panel.orderOut(nil)
    }

    // MARK: - @-completion over FileIndex

    // The "@word" token the caret is currently inside, if any.
    private func completionToken() -> (range: NSRange, query: String)? {
        let text = textView.string as NSString
        let caret = textView.selectedRange().location
        guard caret <= text.length else { return nil }
        var start = caret
        while start > 0 {
            let ch = text.character(at: start - 1)
            if let scalar = Unicode.Scalar(ch), CharacterSet.whitespacesAndNewlines.contains(scalar) { break }
            start -= 1
        }
        guard start < caret, text.character(at: start) == UInt16(UnicodeScalar("@").value) else { return nil }
        let range = NSRange(location: start, length: caret - start)
        return (range, text.substring(with: NSRange(location: start + 1, length: caret - start - 1)))
    }

    private func refreshSuggestions() {
        guard let fileIndex, let token = completionToken() else {
            hideSuggestions()
            return
        }
        let scored: [(String, Int)] = fileIndex.files.compactMap { path in
            fuzzyScore(query: token.query, candidate: path).map { (path, $0) }
        }
        suggestions = scored.sorted { $0.1 > $1.1 }.prefix(8).map { $0.0 }
        completionRange = token.range
        guard !suggestions.isEmpty else {
            hideSuggestions()
            return
        }
        suggestionScroll.isHidden = false
        suggestionTable.reloadData()
        suggestionTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        layoutPanel()
    }

    private func hideSuggestions() {
        suggestions = []
        completionRange = nil
        if !suggestionScroll.isHidden {
            suggestionScroll.isHidden = true
            layoutPanel()
        }
    }

    private func acceptSuggestion(at row: Int) {
        guard suggestions.indices.contains(row), let completionRange else { return }
        let path = suggestions[row]
        if textView.shouldChangeText(in: completionRange, replacementString: path) {
            textView.replaceCharacters(in: completionRange, with: path + " ")
            textView.didChangeText()
        }
        hideSuggestions()
    }

    @objc private func suggestionClicked() {
        let row = suggestionTable.clickedRow
        guard row >= 0 else { return }
        acceptSuggestion(at: row)
        panel.makeFirstResponder(textView)
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        refreshSuggestions()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let suggesting = !suggestionScroll.isHidden
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if suggesting {
                acceptSuggestion(at: max(0, suggestionTable.selectedRow))
                return true
            }
            // Shift-Enter keeps the newline; plain Enter sends.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                return false
            }
            sendAndClose()
            return true
        case #selector(NSResponder.insertTab(_:)) where suggesting:
            acceptSuggestion(at: max(0, suggestionTable.selectedRow))
            return true
        case #selector(NSResponder.moveUp(_:)) where suggesting:
            let row = max(0, suggestionTable.selectedRow - 1)
            suggestionTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            suggestionTable.scrollRowToVisible(row)
            return true
        case #selector(NSResponder.moveDown(_:)) where suggesting:
            let row = min(suggestions.count - 1, suggestionTable.selectedRow + 1)
            suggestionTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            suggestionTable.scrollRowToVisible(row)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if suggesting {
                hideSuggestions()
            } else {
                panel.orderOut(nil)
            }
            return true
        default:
            return false
        }
    }

    // MARK: - Suggestion table

    func numberOfRows(in tableView: NSTableView) -> Int {
        suggestions.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("suggestionRow")
        let label: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            label = reused
        } else {
            label = NSTextField(labelWithString: "")
            label.identifier = identifier
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            label.lineBreakMode = .byTruncatingHead
        }
        label.stringValue = suggestions[row]
        return label
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ThemedTableRowView()
    }
}
