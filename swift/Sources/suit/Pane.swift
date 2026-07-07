import Cocoa

// Identifies a pane on the drag pasteboard so panes can be rearranged by
// dragging their title bars onto one another. The payload is Pane.dragID,
// which only resolves within the window controller that owns the pane, so
// drags across windows/tabs are rejected rather than half-applied.
// (Tabs travel on .suitTab — see TabStripView — and do work across windows.)
extension NSPasteboard.PasteboardType {
    static let suitPane = NSPasteboard.PasteboardType("dev.kosych.suit.pane")
}

// Where a dragged pane will land relative to the pane it's dropped on: one of
// the four edge halves (re-inserted as a split on that side) or the center
// (the two panes swap places).
enum PaneDropZone {
    case left
    case right
    case top
    case bottom
    case swap
}

// Where a dragged *tab* lands on a pane: shown in that pane's viewport
// (header or body center), or split out into a new pane on that edge.
enum TabDropTarget {
    case show
    case edge(PaneDropZone)
}

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
        super.dataReceived(slice: slice)
        outputSniffer?(slice)
    }

    // One-shot: fires when the user commits a line (CR) — SSH tabs restored
    // with a pre-typed, un-submitted command arm their password matcher only
    // when the user actually reconnects.
    var userReturnHook: (() -> Void)?

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if userReturnHook != nil, data.contains(0x0D) {
            let hook = userReturnHook
            userReturnHook = nil
            hook?()
        }
        super.send(source: source, data: data)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()

        let copyItem = menu.addItem(withTitle: "Copy", action: #selector(PaneTerminalView.copy(_:)), keyEquivalent: "")
        copyItem.isEnabled = selectionActive

        let noteItem = menu.addItem(withTitle: "Create Note from Selection", action: #selector(PaneTerminalView.createNoteFromSelection(_:)), keyEquivalent: "")
        noteItem.isEnabled = selectionActive

        // Send the selection into a Claude session as a `/goal` (ROADMAP
        // Phase 18) — the picker handles which session when several are live.
        let goalItem = menu.addItem(withTitle: "Set Selection as Goal", action: #selector(PaneTerminalView.setSelectionAsGoal(_:)), keyEquivalent: "")
        goalItem.isEnabled = selectionActive

        // Pipe the selection into a Claude session (ROADMAP Phase 8): opens
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

        // Only offered inside a task worktree (ROADMAP Phase 5).
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
        guard let text = getSelection() else { return }
        NotesStore.shared.addNoteFromSelection(text)
    }

    // Opens the composer prefilled with the selection, aimed at the session
    // picked from the context-menu submenu (ROADMAP Phase 8).
    @objc func sendSelectionToSession(_ sender: NSMenuItem) {
        guard let text = getSelection(), let sessionId = sender.representedObject as? String else { return }
        (NSApp.delegate as? AppDelegate)?.composePrompt(forSessionId: sessionId, prefill: "\n```\n\(text)\n```")
    }

    // Sends the selection into a Claude session as a `/goal` (ROADMAP Phase 18).
    @objc func setSelectionAsGoal(_ sender: Any?) {
        guard let text = getSelection() else { return }
        (NSApp.delegate as? AppDelegate)?.setSelectionAsGoal(text)
    }

    // MARK: - File-path links (terminal → viewer, ROADMAP Phase 1)

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

// Draws the focus border and lays out the header above the content view,
// both inset so the border is never painted over by the terminal's own
// (possibly Metal-backed) rendering.
final class PaneContainerView: NSView {
    static let inset: CGFloat = 3
    static let titleBarHeight = Theme.Metrics.paneHeaderHeight

    let titleBar = PaneTitleBarView(frame: .zero)
    weak var pane: Pane?
    private var content: NSView
    private let flashOverlay = NSView(frame: .zero)
    private let dropIndicator = NSView(frame: .zero)
    private var screensaver: NSView?

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        addSubview(content)
        addSubview(titleBar)

        flashOverlay.wantsLayer = true
        flashOverlay.layer?.backgroundColor = NSColor.white.cgColor
        flashOverlay.alphaValue = 0
        flashOverlay.isHidden = true
        addSubview(flashOverlay)

        // Topmost overlay: previews where a title-bar-dragged pane (or a
        // strip-dragged tab) will land.
        dropIndicator.wantsLayer = true
        dropIndicator.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.25).cgColor
        dropIndicator.layer?.borderColor = Theme.accent.cgColor
        dropIndicator.layer?.borderWidth = 2
        dropIndicator.layer?.cornerRadius = Theme.Metrics.paneCornerRadius
        dropIndicator.isHidden = true
        addSubview(dropIndicator)

        registerForDraggedTypes([.suitPane, .suitTab])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let insetRect = NSRect(origin: .zero, size: newSize).insetBy(dx: Self.inset, dy: Self.inset)
        titleBar.frame = NSRect(x: insetRect.minX, y: insetRect.maxY - Self.titleBarHeight, width: insetRect.width, height: Self.titleBarHeight)
        let contentFrame = NSRect(x: insetRect.minX, y: insetRect.minY, width: insetRect.width, height: insetRect.height - Self.titleBarHeight)
        content.frame = contentFrame
        screensaver?.frame = contentFrame
        flashOverlay.frame = bounds
    }

    // Swaps which tab's view fills the container (below the title bar,
    // screensaver, flash, and drop overlays).
    func setContentView(_ newView: NSView) {
        guard newView !== content else { return }
        let frame = content.frame
        content.removeFromSuperview()
        content = newView
        newView.frame = frame
        addSubview(newView, positioned: .below, relativeTo: nil)
    }

    // Shown/hidden above the terminal content, below the title bar and bell flash,
    // so toggling a pane's screensaver never hides its title or exit-status dot.
    func setScreensaverView(_ newView: NSView?) {
        screensaver?.removeFromSuperview()
        screensaver = newView
        guard let newView else { return }
        newView.frame = content.frame
        addSubview(newView, positioned: .above, relativeTo: content)
    }

    // A brief full-pane white flash for the terminal bell — visible regardless of
    // the pane's own background color, and useful for noticing a bell in an
    // unfocused pane/window without relying on the (often muted/disabled) system beep.
    func flashForBell() {
        flashOverlay.isHidden = false
        flashOverlay.layer?.removeAllAnimations()
        flashOverlay.alphaValue = 0.35
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            flashOverlay.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.flashOverlay.isHidden = true
        })
    }

    // MARK: - Drop target (panes and tabs)

    // The dragged pane's dragID, but only if this pane can actually accept it
    // (it resolves to another pane in the same window's tree).
    private func acceptableDragID(_ sender: NSDraggingInfo) -> String? {
        guard let pane,
              let id = sender.draggingPasteboard.string(forType: .suitPane),
              pane.canAcceptDrop(ofPaneWithDragID: id) else { return nil }
        return id
    }

    // The dragged tab's id, if this pane can accept it.
    private func acceptableTabId(_ sender: NSDraggingInfo) -> String? {
        guard let pane,
              let id = sender.draggingPasteboard.string(forType: .suitTab),
              pane.canAcceptDrop(ofTabWithId: id) else { return nil }
        return id
    }

    // A tab dropped on the screen replaces what it shows (Chrome/VS Code
    // rule) — .show is the dominant target everywhere, including the header.
    // Only a slim band along each edge still splits the tab out, so splitting
    // stays available but deliberate.
    private func tabDropTarget(at point: NSPoint) -> TabDropTarget {
        if titleBar.frame.contains(point) {
            return .show
        }
        guard bounds.width > 0, bounds.height > 0 else { return .show }
        let band = min(60, min(bounds.width, bounds.height) * 0.2)
        let xDist = min(point.x, bounds.width - point.x)
        let yDist = min(point.y, bounds.height - point.y)
        if xDist > band && yDist > band {
            return .show
        }
        // Inside a band: whichever edge is actually nearest (not flipped, so
        // y grows upward — .top is the maxY side).
        if xDist <= yDist {
            return .edge(point.x < bounds.width / 2 ? .left : .right)
        }
        return .edge(point.y < bounds.height / 2 ? .bottom : .top)
    }

    private func indicatorFrame(forTabTarget target: TabDropTarget) -> NSRect {
        switch target {
        case .show:
            return bounds.insetBy(dx: Self.inset, dy: Self.inset)
        case .edge(let zone):
            return indicatorFrame(for: zone)
        }
    }

    // Not flipped, so y grows upward: .top is the half at maxY.
    private func dropZone(at point: NSPoint) -> PaneDropZone {
        guard bounds.width > 0, bounds.height > 0 else { return .swap }
        let fx = point.x / bounds.width
        let fy = point.y / bounds.height
        if (0.3...0.7).contains(fx) && (0.3...0.7).contains(fy) {
            return .swap
        }
        // Outside the swap region: whichever edge is nearest, in normalized
        // coordinates so wide-but-short panes don't over-favor top/bottom.
        let nearest = min(fx, 1 - fx, fy, 1 - fy)
        if nearest == fx { return .left }
        if nearest == 1 - fx { return .right }
        if nearest == fy { return .bottom }
        return .top
    }

    private func indicatorFrame(for zone: PaneDropZone) -> NSRect {
        let area = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        switch zone {
        case .swap:
            return area
        case .left:
            return NSRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height)
        case .right:
            return NSRect(x: area.midX, y: area.minY, width: area.width / 2, height: area.height)
        case .bottom:
            return NSRect(x: area.minX, y: area.minY, width: area.width, height: area.height / 2)
        case .top:
            return NSRect(x: area.minX, y: area.midY, width: area.width, height: area.height / 2)
        }
    }

    private func updateDropPreview(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        if acceptableTabId(sender) != nil {
            dropIndicator.frame = indicatorFrame(forTabTarget: tabDropTarget(at: point))
            dropIndicator.isHidden = false
            return .generic
        }
        guard acceptableDragID(sender) != nil else {
            dropIndicator.isHidden = true
            return []
        }
        dropIndicator.frame = indicatorFrame(for: dropZone(at: point))
        dropIndicator.isHidden = false
        return .generic
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropPreview(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropPreview(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropIndicator.isHidden = true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropIndicator.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropIndicator.isHidden = true
        guard let pane else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        if let tabId = acceptableTabId(sender) {
            return pane.acceptDrop(ofTabWithId: tabId, target: tabDropTarget(at: point))
        }
        guard let id = acceptableDragID(sender) else { return false }
        return pane.acceptDrop(ofPaneWithDragID: id, zone: dropZone(at: point))
    }
}

// The slim viewport header (browser-tab model): icon + title on the left,
// Claude session dot and context % on the right. It labels what the pane is
// showing — the strip is the single source of tabs — and doubles as the drag
// handle for rearranging whole panes.
final class PaneTitleBarView: NSView, NSDraggingSource {
    weak var pane: Pane?
    private let iconView = NSImageView(frame: .zero)
    private let label = NSTextField(labelWithString: "")
    private let statusDot = NSView(frame: .zero)
    private let contextLabel = NSTextField(labelWithString: "")
    private var mouseDownLocation: NSPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Flat bar chrome (Phase 11), replacing the .titlebar vibrancy.
        wantsLayer = true
        layer?.backgroundColor = Theme.barChrome.cgColor
        layer?.cornerRadius = Theme.Metrics.paneCornerRadius
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = Theme.textDim
        addSubview(iconView)

        label.font = Theme.paneHeaderFont
        label.textColor = Theme.textDim
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3
        statusDot.isHidden = true
        addSubview(statusDot)

        contextLabel.font = Theme.contextFont
        contextLabel.textColor = Theme.textFaint
        contextLabel.isHidden = true
        addSubview(contextLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var title: String = "" {
        didSet { label.stringValue = title }
    }

    var icon: NSImage? {
        didSet { iconView.image = icon }
    }

    // Set once the pane's shell process has exited; nil while it's still running.
    var exitStatus: ProcessExitStatus? {
        didSet { updateStatusDot() }
    }

    // The Claude session state of the tab shown here (ROADMAP Phase 4's
    // attention routing): ● busy (orange), ◐ needs-input (yellow, pulsing so
    // it's findable at a glance without stealing focus), ✓ done (green). The
    // exit-status dot wins once the shell is gone.
    var sessionState: ClaudeSessionState? {
        didSet {
            if sessionState != oldValue { updateStatusDot() }
        }
    }

    // Context-window fill of the Claude session in this pane (ROADMAP Phase 7):
    // the "should I /compact or let it ride" glance. Colored like a fuel gauge
    // as compaction nears; hidden when no session reports it.
    var contextPct: Double? {
        didSet {
            guard contextPct != oldValue else { return }
            if let pct = contextPct {
                contextLabel.stringValue = "\(Int(pct.rounded()))%"
                contextLabel.textColor = Theme.contextLevelColor(pct)
                contextLabel.isHidden = false
            } else {
                contextLabel.isHidden = true
            }
            needsLayout = true
            setFrameSize(frame.size)
        }
    }

    private func updateStatusDot() {
        statusDot.layer?.removeAnimation(forKey: "suit.pulse")
        if let exitStatus {
            statusDot.isHidden = false
            statusDot.layer?.backgroundColor = (exitStatus.isClean ? Theme.sessionDone : Theme.failed).cgColor
            toolTip = exitStatus.shortLabel
            return
        }
        guard let sessionState else {
            statusDot.isHidden = true
            toolTip = nil
            return
        }
        statusDot.isHidden = false
        statusDot.layer?.backgroundColor = sessionState.color.cgColor
        toolTip = "claude: \(sessionState.label)"
        if sessionState == .needsInput, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.25
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            statusDot.layer?.add(pulse, forKey: "suit.pulse")
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutBar()
    }

    private func layoutBar() {
        let iconSize: CGFloat = 12
        iconView.frame = NSRect(x: 8, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)

        var right = bounds.width - 8
        if !contextLabel.isHidden {
            let size = contextLabel.intrinsicContentSize
            contextLabel.frame = NSRect(x: right - size.width, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            right = contextLabel.frame.minX - 5
        }
        let dotSize: CGFloat = 6
        statusDot.frame = NSRect(x: right - dotSize, y: (bounds.height - dotSize) / 2, width: dotSize, height: dotSize)
        if !statusDot.isHidden {
            right = statusDot.frame.minX - 6
        }

        let left = iconView.frame.maxX + 6
        label.frame = NSRect(x: left, y: (bounds.height - 14) / 2, width: max(0, right - left), height: 14)
    }

    // MARK: - Pane drag source

    // The labels cover most of the bar and would swallow mouseDown, so claim
    // every hit for the bar itself — a click focuses the pane, a drag moves it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
    }

    // Only reached for plain clicks: once mouseDragged starts a drag session,
    // AppKit routes the rest of the gesture (including the mouse-up) there.
    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil }
        guard mouseDownLocation != nil, let pane else { return }
        window?.makeFirstResponder(pane.focusTarget)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pane, let start = mouseDownLocation else { return }
        // A few points of slop so a sloppy click doesn't become a drag.
        guard hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        mouseDownLocation = nil

        let item = NSPasteboardItem()
        item.setString(pane.dragID, forType: .suitPane)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        // Drag just the title bar's own snapshot — small enough not to hide the
        // drop preview underneath the cursor, but still labeled with the title.
        draggingItem.setDraggingFrame(bounds, contents: snapshotImage(of: self))
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func snapshotImage(of view: NSView) -> NSImage {
        let image = NSImage(size: view.bounds.size)
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .generic : []
    }
}

// What a Pane needs from whatever owns its pane tree — implemented by
// TerminalWindowController. Kept as a protocol (rather than a direct
// TerminalWindowController reference) purely so Pane.swift doesn't need to
// know that type exists.
protocol PaneHost: AnyObject {
    func paneTitleChanged(_ pane: Pane)
    func canMovePane(withDragID id: String, onto target: Pane) -> Bool
    func movePane(withDragID id: String, onto target: Pane, zone: PaneDropZone) -> Bool
    func paneRequestedFooter(_ pane: Pane)
    func paneIsFooter(_ pane: Pane) -> Bool
    func paneRequestedOpenFile(path: String, line: Int?)
    func paneRequestedOpenCommitDiff(forFile path: String, sha: String)
    func paneRequestedShowFileHistory(forPath path: String)
    func paneFinishedTask(_ pane: Pane)
    // Tab-grain drag & drop (browser-tab model): a strip-dragged tab dropped
    // on this pane — shown in its viewport, or split out onto an edge. The
    // host owns the store and the tree.
    func canDropTab(withId id: String, onto target: Pane) -> Bool
    func dropTab(withId id: String, onto target: Pane, drop: TabDropTarget) -> Bool
}

// Owns one pane: a viewport in the split tree. The pane displays exactly one
// Tab from the window's TabStore (see `display`); everything here is
// content-agnostic chrome — focus border, header, drag & drop, background
// color, screensaver.
final class Pane: NSObject {
    // Phase 11: 1pt amber at 70% when focused, hairline otherwise.
    private static let focusedBorder = Theme.focusBorder.cgColor
    private static let unfocusedBorder = Theme.hairline.cgColor

    private static let presetColors: [(String, NSColor)] = [
        // "Midnight" is the terminal ground — a step darker than the chrome —
        // and the default for terminal panes. "Slate" is the chrome ground
        // itself for anyone who wants the Phase 11 one-surface look back.
        ("Midnight", Theme.terminalBg),
        ("Slate", Theme.bg),
        ("Charcoal", NSColor(calibratedRed: 0.118, green: 0.118, blue: 0.118, alpha: 1)),
        ("Dracula", NSColor(calibratedRed: 0.157, green: 0.165, blue: 0.212, alpha: 1)),
        ("Nord", NSColor(calibratedRed: 0.180, green: 0.204, blue: 0.251, alpha: 1)),
        ("Solarized Dark", NSColor(calibratedRed: 0.000, green: 0.169, blue: 0.212, alpha: 1)),
        ("Deep Plum", NSColor(calibratedRed: 0.102, green: 0.078, blue: 0.137, alpha: 1)),
    ]

    private static let screensaverFontColors: [(String, NSColor)] = [
        ("White", NSColor.white),
        ("Cyan", NSColor(calibratedRed: 0.35, green: 0.75, blue: 0.95, alpha: 1)),
        ("Matrix Green", NSColor(calibratedRed: 0.2, green: 1.0, blue: 0.4, alpha: 1)),
        ("Amber", NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.2, alpha: 1)),
        ("Hot Pink", NSColor(calibratedRed: 1.0, green: 0.4, blue: 0.7, alpha: 1)),
    ]
    private static let screensaverFontSizes: [(String, CGFloat)] = [
        ("Small", 10), ("Medium", 13), ("Large", 16), ("Extra Large", 20),
    ]
    private static let screensaverSpeeds: [(String, CGFloat)] = [
        ("Slow", 0.5), ("Normal", 1), ("Fast", 2), ("Very Fast", 4),
    ]
    private static let screensaverTransparencies: [(String, CGFloat)] = [
        ("25%", 0.25), ("50%", 0.5), ("75%", 0.75), ("100%", 1),
    ]

    // The tab this viewport is displaying. Always set; swapped by display(_:).
    private(set) var tab: Tab
    // The displayed tab's content — call sites mean "whatever this pane is
    // showing right now".
    var content: PaneContent { tab.content }

    let container: PaneContainerView
    private weak var host: PaneHost?

    // The last appearance pushed by the window controller, replayed onto
    // tabs displayed here later. The font is readable so the per-pane
    // Cmd-=/Cmd-- size adjustment can step from what the pane actually shows.
    private(set) var appliedFont: NSFont?
    private var appliedTextColor: NSColor?

    // Identifies this pane on the drag pasteboard (which can only carry plist
    // types, not object references) when its title bar is dragged.
    let dragID = UUID().uuidString

    private var backgroundRGB: NSColor
    private var backgroundAlpha: CGFloat = 1
    private var screensaverView: PaneScreensaverView?

    // Screensaver customization, kept here (rather than on PaneScreensaverView)
    // because `setScreensaver(_:)` creates a fresh view every time the kind
    // changes — these values survive that and get reapplied to the new view.
    private var screensaverFontColor = Pane.screensaverFontColors[0].1
    private var screensaverBackgroundColor = NSColor.black
    private var screensaverBackgroundAlpha: CGFloat = 1
    private var screensaverFontSize: CGFloat = 13
    private var screensaverSpeed: CGFloat = 1

    var displayTitle: String { tab.title }

    // The displayed tab's exit status: set once that tab's shell process exits.
    var exitStatus: ProcessExitStatus? { tab.exitStatus }

    // Conveniences so callers don't have to reach through `content` for the
    // things every pane kind answers.
    var focusTarget: NSView { content.focusTarget }
    var workingDirectory: String? { content.workingDirectory }
    var terminalContent: TerminalPaneContent? { content as? TerminalPaneContent }
    var runningProcessName: String? { tab.runningProcessName }

    init(host: PaneHost, tab: Tab) {
        self.host = host
        self.tab = tab
        let content = tab.content
        backgroundRGB = content.initialBackgroundColor

        container = PaneContainerView(content: content.view)
        container.wantsLayer = true
        container.layer?.borderWidth = 0
        container.layer?.cornerRadius = Theme.Metrics.paneCornerRadius
        container.layer?.borderColor = Pane.unfocusedBorder
        // The 3pt content inset shows the container itself; ground it in the
        // chrome color so the outline reads as one hairline (Phase 15) —
        // never the window backdrop (or black, in offscreen renders).
        container.layer?.backgroundColor = Theme.bg.cgColor

        super.init()

        tab.pane = self
        content.pane = self
        container.pane = self
        container.titleBar.pane = self
        refreshChrome()
    }

    // MARK: - Viewport

    // Points this viewport at another (background) tab. The displaced tab
    // stays alive in the store — just no longer on screen. The caller
    // (TerminalWindowController) guarantees `newTab` isn't displayed by any
    // other pane.
    func display(_ newTab: Tab) {
        guard newTab !== tab else { return }
        let old = tab
        if old.pane === self {
            old.pane = nil
            old.content.pane = nil
        }
        tab = newTab
        newTab.pane = self
        newTab.content.pane = self
        // A (re-)displayed tab picks up the appearance this pane already wears.
        if let appliedFont { newTab.content.applyFont(appliedFont) }
        if let appliedTextColor { newTab.content.applyTextColor(appliedTextColor) }
        newTab.content.applyBackground(backgroundRGB.withAlphaComponent(backgroundAlpha))
        container.setContentView(newTab.content.view)
        refreshChrome()
        host?.paneTitleChanged(self)
    }

    // Refreshes the header from the displayed tab (title, icon, dots).
    func refreshChrome() {
        container.titleBar.title = displayTitle
        container.titleBar.icon = NSImage(systemSymbolName: tab.kind.symbolName, accessibilityDescription: nil)
        container.titleBar.exitStatus = tab.exitStatus
        container.titleBar.sessionState = tab.liveSessionState
        container.titleBar.contextPct = tab.exitStatus == nil ? tab.claudeSession?.contextPct : nil
    }

    // MARK: - Drag & drop rearrangement (forwarded to the host, which owns the tree)

    func canAcceptDrop(ofPaneWithDragID id: String) -> Bool {
        host?.canMovePane(withDragID: id, onto: self) ?? false
    }

    func acceptDrop(ofPaneWithDragID id: String, zone: PaneDropZone) -> Bool {
        host?.movePane(withDragID: id, onto: self, zone: zone) ?? false
    }

    func canAcceptDrop(ofTabWithId id: String) -> Bool {
        host?.canDropTab(withId: id, onto: self) ?? false
    }

    func acceptDrop(ofTabWithId id: String, target: TabDropTarget) -> Bool {
        host?.dropTab(withId: id, onto: self, drop: target) ?? false
    }

    // Purely visual; the window controller derives who's focused from
    // window.firstResponder and repaints every pane (firstResponderDidChange).
    func setFocused(_ focused: Bool) {
        container.layer?.borderColor = focused ? Pane.focusedBorder : Pane.unfocusedBorder
    }

    // The border is only meaningful once there's more than one pane to distinguish.
    func setBorderVisible(_ visible: Bool) {
        container.layer?.borderWidth = visible ? Theme.Metrics.focusBorderWidth : 0
    }

    func flashForBell() {
        container.flashForBell()
    }

    var isFooter: Bool { host?.paneIsFooter(self) ?? false }

    @objc func makeFooter(_ sender: Any?) {
        host?.paneRequestedFooter(self)
    }

    // Finish this pane's task worktree (ROADMAP Phase 5): merge or discard the
    // branch, remove the worktree, and close the pane.
    @objc func finishClaudeTask(_ sender: Any?) {
        guard let path = workingDirectory, WorktreeTasks.isTaskWorktree(path) else { return }
        let branch = WorktreeTasks.currentBranch(path) ?? "the task branch"
        let alert = NSAlert()
        alert.messageText = "Finish Claude Task?"
        alert.informativeText = "“Merge & Remove” merges \(branch) into the main checkout, then deletes the worktree and branch. “Discard & Remove” deletes both without merging.\n\n\(path)"
        alert.addButton(withTitle: "Merge & Remove")
        alert.addButton(withTitle: "Discard & Remove")
        alert.addButton(withTitle: "Cancel")
        let merge: Bool
        switch alert.runModal() {
        case .alertFirstButtonReturn: merge = true
        case .alertSecondButtonReturn: merge = false
        default: return
        }
        if let error = WorktreeTasks.finish(worktreePath: path, merge: merge) {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = "Finish Claude Task"
            failure.informativeText = error
            failure.runModal()
            return
        }
        host?.paneFinishedTask(self)
    }

    // A file-path link clicked inside this pane's content (terminal output);
    // the host owns the viewer tab it opens into.
    func openFileLink(path: String, line: Int?) {
        host?.paneRequestedOpenFile(path: path, line: line)
    }

    // Blame/history chaining (ROADMAP Phase 17): the viewer routes a clicked
    // blame sha or a "Show File History" request through the host, which owns
    // the diff tab / sidebar.
    func openCommitDiff(forFile path: String, sha: String) {
        host?.paneRequestedOpenCommitDiff(forFile: path, sha: sha)
    }

    func showFileHistory(forPath path: String) {
        host?.paneRequestedShowFileHistory(forPath: path)
    }

    // The pane is going away for good (its tab closed with it). Contents are
    // torn down by the tab-close path; this only stops pane-owned extras.
    // A screensaver's repeating Timer is kept alive by the run loop itself, not
    // by this pane, so it must be stopped explicitly or it fires forever.
    func teardown() {
        screensaverView?.stop()
    }

    // MARK: - Screensaver

    func screensaverMenu() -> NSMenu {
        let menu = NSMenu()

        let noneItem = NSMenuItem(title: "None", action: #selector(pickScreensaver(_:)), keyEquivalent: "")
        noneItem.target = self
        noneItem.state = screensaverView == nil ? .on : .off
        menu.addItem(noneItem)

        menu.addItem(.separator())

        for kind in [PaneScreensaverKind.waves, .stars, .matrix] {
            let item = NSMenuItem(title: kind.rawValue, action: #selector(pickScreensaver(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind
            item.state = (screensaverView?.kind == kind) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let fontColorItem = NSMenuItem(title: "Font Color", action: nil, keyEquivalent: "")
        fontColorItem.submenu = screensaverFontColorMenu()
        menu.addItem(fontColorItem)

        let fontSizeItem = NSMenuItem(title: "Font Size", action: nil, keyEquivalent: "")
        fontSizeItem.submenu = screensaverFontSizeMenu()
        menu.addItem(fontSizeItem)

        let backgroundColorItem = NSMenuItem(title: "Background Color", action: nil, keyEquivalent: "")
        backgroundColorItem.submenu = screensaverBackgroundColorMenu()
        menu.addItem(backgroundColorItem)

        let transparencyItem = NSMenuItem(title: "Transparency", action: nil, keyEquivalent: "")
        transparencyItem.submenu = screensaverTransparencyMenu()
        menu.addItem(transparencyItem)

        let speedItem = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
        speedItem.submenu = screensaverSpeedMenu()
        menu.addItem(speedItem)

        return menu
    }

    @objc private func pickScreensaver(_ sender: NSMenuItem) {
        setScreensaver(sender.representedObject as? PaneScreensaverKind)
    }

    private func setScreensaver(_ kind: PaneScreensaverKind?) {
        screensaverView?.stop()
        guard let kind else {
            container.setScreensaverView(nil)
            screensaverView = nil
            return
        }
        let overlay = PaneScreensaverView(frame: .zero)
        overlay.kind = kind
        overlay.fontColor = screensaverFontColor
        overlay.fontSize = screensaverFontSize
        overlay.backgroundColor = screensaverBackgroundColor
        overlay.backgroundAlpha = screensaverBackgroundAlpha
        overlay.speed = screensaverSpeed
        container.setScreensaverView(overlay)
        overlay.start()
        screensaverView = overlay
    }

    // MARK: - Screensaver customization

    private func screensaverFontColorMenu() -> NSMenu {
        let menu = NSMenu()
        for (name, color) in Pane.screensaverFontColors {
            let item = NSMenuItem(title: name, action: #selector(pickScreensaverFontColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = color
            item.image = Pane.swatchImage(for: color)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let customItem = NSMenuItem(title: "Custom Color…", action: #selector(openScreensaverFontColorPanel(_:)), keyEquivalent: "")
        customItem.target = self
        menu.addItem(customItem)
        return menu
    }

    @objc private func pickScreensaverFontColor(_ sender: NSMenuItem) {
        guard let color = sender.representedObject as? NSColor else { return }
        setScreensaverFontColor(color)
    }

    @objc private func openScreensaverFontColorPanel(_ sender: Any?) {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(screensaverFontColorPanelChanged(_:)))
        panel.color = screensaverFontColor
        panel.showsAlpha = false
        panel.orderFront(nil)
    }

    @objc private func screensaverFontColorPanelChanged(_ sender: NSColorPanel) {
        setScreensaverFontColor(sender.color)
    }

    private func setScreensaverFontColor(_ color: NSColor) {
        screensaverFontColor = color
        screensaverView?.fontColor = color
    }

    private func screensaverBackgroundColorMenu() -> NSMenu {
        let menu = NSMenu()
        for (name, color) in Pane.presetColors {
            let item = NSMenuItem(title: name, action: #selector(pickScreensaverBackgroundColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = color
            item.image = Pane.swatchImage(for: color)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let customItem = NSMenuItem(title: "Custom Color…", action: #selector(openScreensaverBackgroundColorPanel(_:)), keyEquivalent: "")
        customItem.target = self
        menu.addItem(customItem)
        return menu
    }

    @objc private func pickScreensaverBackgroundColor(_ sender: NSMenuItem) {
        guard let color = sender.representedObject as? NSColor else { return }
        setScreensaverBackgroundColor(color)
    }

    @objc private func openScreensaverBackgroundColorPanel(_ sender: Any?) {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(screensaverBackgroundColorPanelChanged(_:)))
        panel.color = screensaverBackgroundColor
        panel.showsAlpha = false
        panel.orderFront(nil)
    }

    @objc private func screensaverBackgroundColorPanelChanged(_ sender: NSColorPanel) {
        setScreensaverBackgroundColor(sender.color)
    }

    private func setScreensaverBackgroundColor(_ color: NSColor) {
        screensaverBackgroundColor = color
        screensaverView?.backgroundColor = color
    }

    private func screensaverFontSizeMenu() -> NSMenu {
        let menu = NSMenu()
        for (name, size) in Pane.screensaverFontSizes {
            let item = NSMenuItem(title: name, action: #selector(pickScreensaverFontSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = size
            item.state = screensaverFontSize == size ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func pickScreensaverFontSize(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? CGFloat else { return }
        screensaverFontSize = size
        screensaverView?.fontSize = size
    }

    private func screensaverTransparencyMenu() -> NSMenu {
        let menu = NSMenu()
        for (name, alpha) in Pane.screensaverTransparencies {
            let item = NSMenuItem(title: name, action: #selector(pickScreensaverTransparency(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = alpha
            item.state = screensaverBackgroundAlpha == alpha ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func pickScreensaverTransparency(_ sender: NSMenuItem) {
        guard let alpha = sender.representedObject as? CGFloat else { return }
        screensaverBackgroundAlpha = alpha
        screensaverView?.backgroundAlpha = alpha
    }

    private func screensaverSpeedMenu() -> NSMenu {
        let menu = NSMenu()
        for (name, speed) in Pane.screensaverSpeeds {
            let item = NSMenuItem(title: name, action: #selector(pickScreensaverSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = speed
            item.state = screensaverSpeed == speed ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func pickScreensaverSpeed(_ sender: NSMenuItem) {
        guard let speed = sender.representedObject as? CGFloat else { return }
        screensaverSpeed = speed
        screensaverView?.speed = speed
    }

    // MARK: - Background color

    func setBackgroundColor(_ color: NSColor) {
        backgroundRGB = color
        applyBackgroundColor()
    }

    func setBackgroundAlpha(_ alpha: CGFloat) {
        backgroundAlpha = alpha
        applyBackgroundColor()
    }

    private func applyBackgroundColor() {
        content.applyBackground(backgroundRGB.withAlphaComponent(backgroundAlpha))
    }

    func setFont(_ font: NSFont) {
        appliedFont = font
        content.applyFont(font)
    }

    func setTextColor(_ color: NSColor) {
        appliedTextColor = color
        content.applyTextColor(color)
    }

    func backgroundColorMenu() -> NSMenu {
        let menu = NSMenu()
        for (name, color) in Pane.presetColors {
            let item = NSMenuItem(title: name, action: #selector(pickBackgroundColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = color
            item.image = Pane.swatchImage(for: color)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let customItem = NSMenuItem(title: "Custom Color…", action: #selector(openColorPanel(_:)), keyEquivalent: "")
        customItem.target = self
        menu.addItem(customItem)
        return menu
    }

    private static func swatchImage(for color: NSColor) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size)
        image.lockFocus()
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        color.setFill()
        path.fill()
        // A thin border so very dark swatches stay visible against a dark menu background.
        Theme.hairline.setStroke()
        path.lineWidth = 0.5
        path.stroke()
        image.unlockFocus()
        return image
    }

    @objc private func pickBackgroundColor(_ sender: NSMenuItem) {
        guard let color = sender.representedObject as? NSColor else { return }
        setBackgroundColor(color)
    }

    @objc private func openColorPanel(_ sender: Any?) {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.color = backgroundRGB
        panel.showsAlpha = false
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        setBackgroundColor(sender.color)
    }
}
