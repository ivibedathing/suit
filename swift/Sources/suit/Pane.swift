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

    // Shared with Pane+BackgroundColor and Pane+Screensaver.
    static let presetColors: [(String, NSColor)] = [
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

    // Shared with Pane+Screensaver.
    static let screensaverFontColors: [(String, NSColor)] = [
        ("White", NSColor.white),
        ("Cyan", NSColor(calibratedRed: 0.35, green: 0.75, blue: 0.95, alpha: 1)),
        ("Matrix Green", NSColor(calibratedRed: 0.2, green: 1.0, blue: 0.4, alpha: 1)),
        ("Amber", NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.2, alpha: 1)),
        ("Hot Pink", NSColor(calibratedRed: 1.0, green: 0.4, blue: 0.7, alpha: 1)),
    ]
    static let screensaverFontSizes: [(String, CGFloat)] = [
        ("Small", 10), ("Medium", 13), ("Large", 16), ("Extra Large", 20),
    ]
    static let screensaverSpeeds: [(String, CGFloat)] = [
        ("Slow", 0.5), ("Normal", 1), ("Fast", 2), ("Very Fast", 4),
    ]
    static let screensaverTransparencies: [(String, CGFloat)] = [
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

    // Read by Pane+BackgroundColor's color-panel action.
    var backgroundRGB: NSColor
    private var backgroundAlpha: CGFloat = 1
    // Managed by Pane+Screensaver; torn down here in teardown().
    var screensaverView: PaneScreensaverView?

    // Screensaver customization, kept here (rather than on PaneScreensaverView)
    // because `setScreensaver(_:)` creates a fresh view every time the kind
    // changes — these values survive that and get reapplied to the new view.
    // Mutated from Pane+Screensaver.
    var screensaverFontColor = Pane.screensaverFontColors[0].1
    var screensaverBackgroundColor = NSColor.black
    var screensaverBackgroundAlpha: CGFloat = 1
    var screensaverFontSize: CGFloat = 13
    var screensaverSpeed: CGFloat = 1

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

    // Shared by the background-color and screensaver menus (both in extensions).
    static func swatchImage(for color: NSColor) -> NSImage {
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
}
