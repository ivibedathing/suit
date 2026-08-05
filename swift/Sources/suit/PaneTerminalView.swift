import Cocoa

// A terminal view that knows which Pane owns it, so AppDelegate can map
// `window.firstResponder` back to the Pane that should be split or closed.
// (Focus visuals are derived from window.firstResponder by the window
// controller — no responder overrides here; see firstResponderDidChange.)
final class PaneTerminalView: LocalProcessTerminalView {
    weak var pane: Pane?
    // The tab hosting this terminal — the attention route that still works
    // while the tab is backgrounded (no pane): bells pulse the strip item.
    weak var owningTab: Tab?

    // Host-output tap for content-level sniffers (SSH auto-auth watches for
    // the password prompt here). Nil for ordinary terminals, so the hot path
    // costs one nil check. Runs on the main queue (LocalProcess's default
    // dispatch queue) with the raw pty bytes.
    var outputSniffer: ((ArraySlice<UInt8>) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        // Anything the shell draws can move the cursor off the end of the echo
        // the warm-up gate is holding, which decides whether that echo is still
        // ours to erase at handover. Same main queue as the gate's timer.
        if warmup != nil { warmupShellRedrew = true }
        super.dataReceived(slice: slice)
        outputSniffer?(slice)
    }

    // One-shot: fires when the user commits a line (CR) — SSH tabs restored
    // with a pre-typed, un-submitted command arm their password matcher only
    // when the user actually reconnects.
    var userReturnHook: (() -> Void)?

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // Shell still warming up with nobody editing input? Hold the keystrokes
        // and draw them ourselves rather than let the tty driver echo raw bytes
        // (see ShellWarmup.swift). Both hooks below run on the flush instead,
        // when the same bytes come back through this method disarmed.
        if warmupIsBuffering, let warmup {
            let response = warmup.accept(data)
            if !response.echo.isEmpty {
                feed(byteArray: response.echo[...])
                warmupShellRedrew = false
            }
            if !response.passthrough.isEmpty { super.send(source: source, data: response.passthrough[...]) }
            return
        }
        if userReturnHook != nil, data.contains(0x0D) {
            let hook = userReturnHook
            userReturnHook = nil
            hook?()
        }
        recordTypedInput(data)
        super.send(source: source, data: data)
    }

    // Per-pane command recorder: reconstruct the line the
    // user is typing from the bytes headed to the pty, and on Return hand a
    // clean single-line command to CommandHistoryStore so ⌃R can find commands
    // run in this pane — including before they reach $HISTFILE, and when there
    // is no history file at all. Best-effort: anything with an escape sequence
    // (arrow-key line editing, a bracketed paste, history recall) marks the line
    // dirty so only plainly-typed commands are recorded.
    private var typedLine: [UInt8] = []
    private var typedLineDirty = false

    private func recordTypedInput(_ data: ArraySlice<UInt8>) {
        for byte in data {
            switch byte {
            case 0x0D, 0x0A:   // Return — commit the line
                commitTypedLine()
            case 0x7F, 0x08:   // Backspace / Delete
                if !typedLine.isEmpty { typedLine.removeLast() } else { typedLineDirty = true }
            case 0x03, 0x15, 0x0C:   // Ctrl-C / Ctrl-U / Ctrl-L — abandon the line
                typedLine.removeAll(); typedLineDirty = false
            case 0x09, 0x1B:   // Tab completion / any escape sequence — not plain typing
                typedLineDirty = true
            case 0x00..<0x20:  // other control bytes — treat as non-plain input
                typedLineDirty = true
            default:
                typedLine.append(byte)
            }
        }
    }

    private func commitTypedLine() {
        defer { typedLine.removeAll(); typedLineDirty = false }
        guard !typedLineDirty, !typedLine.isEmpty else { return }
        let command = String(decoding: typedLine, as: UTF8.self)
        CommandHistoryStore.shared.recordPaneCommand(command, cwd: pane?.workingDirectory)
    }

    // MARK: - Shell warm-up typeahead

    // Live only for the first seconds of a shell's life; see ShellWarmup.swift
    // for what the window is and why the driver's echo is wrong inside it.
    private var warmup: ShellWarmupTypeahead?
    private var warmupTimer: Timer?
    private var warmupIsBuffering = false
    // Has the shell drawn anything since we last echoed? See flush(shellRedrew:).
    private var warmupShellRedrew = false

    // Poll rather than wait for an event: the transition we care about is the
    // shell calling tcsetattr, which produces no output and no signal. 25ms is
    // an ioctl per frame for about a second — cheap next to being one redraw
    // late in handing zle the line.
    private static let warmupPollInterval: TimeInterval = 0.025
    // A shell that never reaches a line editor (a login that hangs, a tab
    // running one long command) shouldn't swallow input forever.
    private static let warmupDeadline: TimeInterval = 10

    func beginShellWarmup() {
        endShellWarmup(flush: false)
        warmup = ShellWarmupTypeahead()
        warmupShellRedrew = false
        let started = Date()
        let timer = Timer(timeInterval: Self.warmupPollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            switch ShellWarmupTTY.mode(of: self.process.childfd) {
            case .cooked:
                // Canonical: the driver echoes and erases correctly on its own.
                self.warmupIsBuffering = false
            case .rawEcho:
                self.warmupIsBuffering = true
            case .lineEditor:
                self.endShellWarmup(flush: true)
            case nil:
                self.endShellWarmup(flush: false)   // the shell is gone
            }
            if Date().timeIntervalSince(started) > Self.warmupDeadline {
                self.endShellWarmup(flush: true)
            }
        }
        // .common so a scroll or a live resize doesn't stall the handover.
        RunLoop.main.add(timer, forMode: .common)
        warmupTimer = timer
    }

    // Ends the window: takes our stand-in echo back off the screen and, when
    // there is still a shell to receive them, replays the held keystrokes
    // through send() so the line editor renders them and the history recorder
    // and Return hook see them exactly as if they had just been typed.
    func endShellWarmup(flush: Bool) {
        warmupTimer?.invalidate()
        warmupTimer = nil
        warmupIsBuffering = false
        guard let warmup else { return }
        self.warmup = nil
        guard flush else { return warmup.discard() }
        let held = warmup.flush(shellRedrew: warmupShellRedrew)
        if !held.erase.isEmpty { feed(byteArray: held.erase[...]) }
        if !held.bytes.isEmpty { send(source: self, data: held.bytes[...]) }
    }

    // The Edit menu owns ⌘Z/⇧⌘Z/⌘X/⌘A app-wide — right for text views,
    // wrong for a TUI that negotiated the kitty keyboard protocol: that
    // negotiation is precisely a request for modified keys (super included)
    // as escape codes, and menu dispatch consumes the chord before keyDown
    // ever runs. Views get performKeyEquivalent ahead of the menu bar, so
    // the focused terminal claims these chords here and pushes them down the
    // kitty path. ⌘C/⌘V deliberately stay with the menu: the clipboard is
    // the terminal emulator's own affordance, the same line kitty and
    // Ghostty draw. Without kitty flags nothing changes — the menu keeps
    // every chord, as it should for a plain shell.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control),
              !terminal.keyboardEnhancementFlags.isEmpty,
              window?.firstResponder === self,
              let key = event.charactersIgnoringModifiers?.lowercased(),
              key == "z" || key == "x" || key == "a"
        else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        // The menu is rebuilt on every right-click, so the isEnabled values
        // below are current — but only with auto-validation off. Left on,
        // NSMenu's own validation pass re-enables every item whose action the
        // responder chain answers, overwriting these before they are seen, and
        // a selection-less Copy would sit enabled and silently do nothing.
        menu.autoenablesItems = false

        let copyItem = menu.addItem(withTitle: "Copy", action: #selector(PaneTerminalView.copy(_:)), keyEquivalent: "")
        copyItem.isEnabled = selectionActive

        let noteItem = menu.addItem(withTitle: "Create Note from Selection", action: #selector(PaneTerminalView.createNoteFromSelection(_:)), keyEquivalent: "")
        noteItem.isEnabled = selectionActive

        // Send the selection into a Claude session as a `/goal` — the picker
        // handles which session when several are live.
        let goalItem = menu.addItem(withTitle: "Set Selection as Goal", action: #selector(PaneTerminalView.setSelectionAsGoal(_:)), keyEquivalent: "")
        goalItem.isEnabled = selectionActive

        // Pipe the selection into a Claude session: opens
        // the prompt composer prefilled, so one line of context + Enter sends
        // an error, diff hunk, or log line without touching that pane.
        let sessions = ClaudeSessionMonitor.shared.sessions
        if selectionActive, !sessions.isEmpty {
            let sendItem = menu.addItem(withTitle: "Send Selection to Claude Session", action: nil, keyEquivalent: "")
            let sendMenu = NSMenu()
            for session in sessions {
                let project = (session.cwd as NSString?)?.lastPathComponent ?? ""
                let item = sendMenu.addItem(
                    withTitle: "\(session.displayName)\(project.isEmpty ? "" : " · \(project)") — \(session.state.label)",
                    action: #selector(PaneTerminalView.sendSelectionToSession(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = session.id
            }
            sendItem.submenu = sendMenu
        }

        menu.addItem(withTitle: "Paste", action: #selector(PaneTerminalView.paste(_:)), keyEquivalent: "")

        menu.addItem(.separator())

        // Re-docks this pane as a full-width strip along the bottom of the window;
        // checked (and a no-op) once it's already there.
        let footerItem = menu.addItem(withTitle: "Make Footer", action: #selector(Pane.makeFooter(_:)), keyEquivalent: "")
        footerItem.target = pane
        footerItem.state = (pane?.isFooter == true) ? .on : .off

        // Background-task monitor for this pane's shell.
        let tasksItem = menu.addItem(withTitle: "Show Background Tasks", action: #selector(Pane.showBackgroundTasks(_:)), keyEquivalent: "")
        tasksItem.target = pane

        // Only offered inside a task worktree.
        if WorktreeTasks.isTaskWorktree(pane?.workingDirectory) {
            let finishItem = menu.addItem(withTitle: "Finish Claude Task…", action: #selector(Pane.finishClaudeTask(_:)), keyEquivalent: "")
            finishItem.target = pane
        }

        menu.addItem(.separator())

        let backgroundItem = NSMenuItem(title: "Background Color", action: nil, keyEquivalent: "")
        backgroundItem.submenu = pane?.backgroundColorMenu()
        menu.addItem(backgroundItem)

        let screensaverItem = NSMenuItem(title: "Screensaver", action: nil, keyEquivalent: "")
        screensaverItem.submenu = pane?.screensaverMenu()
        menu.addItem(screensaverItem)

        return menu
    }

    // TerminalView.bell(source:) is the only bell hook that's actually an overridable
    // class method here — TerminalViewDelegate.bell (the one LocalProcessTerminalView
    // routes through `terminalDelegate`) is satisfied by that protocol's own default
    // extension (a plain NSSound.beep()), which a subclass can't intercept since
    // LocalProcessTerminalView never declares its own `bell` to override.
    override func bell(source: Terminal) {
        super.bell(source: source)
        let appDelegate = NSApp.delegate as? AppDelegate
        // A bell while Suit is in the background bounces the Dock icon once
        // (.informational = single bounce; AppKit drops the request the moment
        // the app activates, and it's inert while already active). Both
        // responses are settings-window toggles; the strip pulse for
        // backgrounded tabs always runs — it's how a hidden tab is found.
        if !NSApp.isActive, appDelegate?.bellDockBounceEnabled ?? true {
            NSApp.requestUserAttention(.informationalRequest)
        }
        if let pane {
            if appDelegate?.bellFlashEnabled ?? true {
                pane.flashForBell()
            }
        } else {
            // Backgrounded tab: pulse its strip item instead.
            owningTab?.wantsAttention()
        }
    }

    // OSC 52 "set clipboard" (remote/tmux sessions copying into the local macOS
    // pasteboard) already works out of the box: LocalProcessTerminalView.clipboardCopy
    // is inherited as-is and really does write to NSPasteboard.general.
    //
    // OSC 52 "read clipboard" queries are a different story — LocalProcessTerminalView's
    // inherited clipboardRead hands back the pasteboard's contents to *any* program
    // running in this pane, local or remote, with no confirmation at all. That's a
    // silent clipboard-exfiltration path (password managers, etc. land on the
    // clipboard), and it contradicts TerminalViewDelegate.clipboardRead's own doc
    // comment, which specifies denying by default for exactly this reason. Deny it.
    override func clipboardRead(source: TerminalView) -> Data? {
        nil
    }

    // A multi-line paste runs every line as its own command the instant it lands
    // (there's no chance to review before Enter fires), and a curl/wget-into-a-shell
    // one-liner runs unread code just as fast — both are exactly what shows up when
    // copying "quick install" snippets from a webpage. Warn before either goes through.
    private static let pipeToShellPattern = try? NSRegularExpression(
        pattern: #"\b(curl|wget)\b[^\n]*\|\s*(sudo\s+)?(sh|bash|zsh|python[0-9.]*|perl|ruby|node)\b"#,
        options: [.caseInsensitive]
    )

    private static func pasteSafetyWarning(for text: String) -> String? {
        if let pipeToShellPattern, pipeToShellPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            return "This looks like it downloads and immediately runs a script (curl/wget piped into a shell)."
        }
        if text.contains("\n") {
            return "This paste has multiple lines, which will be sent to the shell one after another as soon as you paste."
        }
        return nil
    }

    private func confirmPaste(text: String, reason: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Paste into Terminal?"
        let preview = text.count > 280 ? String(text.prefix(280)) + "…" : text
        alert.informativeText = "\(reason)\n\n\(preview)"
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    override func paste(_ sender: Any) {
        if let text = NSPasteboard.general.string(forType: .string),
           let reason = Self.pasteSafetyWarning(for: text) {
            guard confirmPaste(text: text, reason: reason) else { return }
        }
        super.paste(sender)
    }

    @objc func createNoteFromSelection(_ sender: Any?) {
        guard let text = getSelection(), let path = NotesStore.shared.addNoteFromSelection(text) else { return }
        // The capture is a file now, so show it the way any other file opens —
        // in a tab, editable, where the user can title and trim it right away.
        (NSApp.delegate as? AppDelegate)?.activeWindowController()?.openFile(atPath: path, line: nil)
    }

    // Opens the composer prefilled with the selection, aimed at the session
    // picked from the context-menu submenu.
    @objc func sendSelectionToSession(_ sender: NSMenuItem) {
        guard let text = getSelection(), let sessionId = sender.representedObject as? String else { return }
        (NSApp.delegate as? AppDelegate)?.composePrompt(forSessionId: sessionId, prefill: "\n```\n\(text)\n```")
    }

    // Sends the selection into a Claude session as a `/goal`.
    @objc func setSelectionAsGoal(_ sender: Any?) {
        guard let text = getSelection() else { return }
        (NSApp.delegate as? AppDelegate)?.setSelectionAsGoal(text)
    }

    // MARK: - File-path links (terminal → viewer)

    // SwiftTerm's implicit link detection (the ghostty-style regex in
    // Terminal.swift) already finds path-shaped runs and underlines them on
    // Cmd-hover; by default a Cmd-click hands the text to NSWorkspace, which
    // silently fails on anything that isn't a real URL. Intercept the click
    // first: if the text resolves to an actual file (relative paths against
    // this pane's cwd, an optional trailing :line[:col] split off), open it in
    // a viewer pane instead. Everything else — real URLs, non-existent paths —
    // falls through to SwiftTerm's own handling.
    private static let urlSchemePrefixes = [
        "http://", "https://", "mailto:", "ftp://", "file:", "ssh:", "git://",
        "tel:", "magnet:", "ipfs://", "ipns://", "gemini://", "gopher://", "news:",
    ]

    override func mouseUp(with event: NSEvent) {
        let hit = calculateMouseHit(with: event).grid
        if let result = linkForClick(at: hit, hasCommandModifier: event.modifierFlags.contains(.command)),
           let target = resolveFileLink(result.link) {
            didSelectionDrag = false
            pane?.openFileLink(path: target.path, line: target.line)
            return
        }
        super.mouseUp(with: event)
    }

    func resolveFileLink(_ link: String) -> (path: String, line: Int?)? {
        let lowercased = link.lowercased()
        guard !Self.urlSchemePrefixes.contains(where: { lowercased.hasPrefix($0) }) else { return nil }

        // Compiler/grep-style suffixes: path:12 and path:12:34.
        var parts = link.components(separatedBy: ":")
        var numbers: [Int] = []
        while parts.count > 1, numbers.count < 2, let n = Int(parts.last ?? ""), n > 0 {
            numbers.insert(n, at: 0)
            parts.removeLast()
        }
        let line = numbers.first

        for (candidate, candidateLine) in [(parts.joined(separator: ":"), line), (link, nil)] {
            let expanded = (candidate as NSString).expandingTildeInPath
            let absolute: String
            if expanded.hasPrefix("/") {
                absolute = expanded
            } else if let cwd = pane?.workingDirectory ?? owningTab?.content.workingDirectory {
                absolute = cwd + "/" + expanded
            } else {
                continue
            }
            let standardized = (absolute as NSString).standardizingPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: standardized, isDirectory: &isDirectory), !isDirectory.boolValue {
                return (standardized, candidateLine)
            }
        }
        return nil
    }
}
