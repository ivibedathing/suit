import Cocoa

// The browser-tab model: one window-level ordered list of tabs owns every
// open thing — terminals, file viewers, diffs, transcripts. Panes are just
// viewports that display at most one tab each (see Pane.display); tabs not
// shown in any pane run on in the background. The strip (TabStripView)
// renders this store; TerminalWindowController orchestrates both.

// What kind of content a tab holds — drives the strip/header icon. New
// PaneContent kinds get a case here and nothing else changes.
enum TabKind {
    case terminal
    case ssh
    case viewer
    case markdown
    case image
    case pdf
    case diff
    case transcript

    var symbolName: String {
        switch self {
        case .terminal: return "terminal"
        case .ssh: return "network"
        case .viewer: return "doc.text"
        case .markdown: return "doc.richtext"
        case .image: return "photo"
        case .pdf: return "doc.text.image"
        case .diff: return "plus.forwardslash.minus"
        case .transcript: return "text.bubble"
        }
    }
}

// One tab: a full PaneContent plus everything the strip needs to draw it and
// the window controller needs to route it. This replaces the old per-pane
// PaneTab — the tab now belongs to the window's TabStore, and `pane` points
// at whichever viewport is currently displaying it (nil = background).
final class Tab {
    // Identifies this tab on the drag pasteboard and across windows.
    let id = UUID().uuidString
    let content: PaneContent
    weak var store: TabStore?

    // The viewport currently showing this tab; nil while backgrounded.
    weak var pane: Pane?

    var contentTitle: String?
    var customTitle: String?
    var exitStatus: ProcessExitStatus?
    // Preview tab (VS Code open semantics): openFile/⌘P/search reuse this tab
    // for the next file instead of stacking tabs. "Keep" (double-click) pins
    // its content in place. At most one per window, enforced by the store.
    var isPreview = false
    // Pinned tabs render icon-only, stay in the strip's left prefix, and have
    // no close box — for the daemon shell or claude session you never close.
    var isPinned = false
    // The Claude session running in this tab's terminal, if any — kept per
    // tab so attention routes through background tabs (strip dot pulses).
    var claudeSession: ClaudeSession?

    init(content: PaneContent) {
        self.content = content
        content.tab = self
    }

    var kind: TabKind {
        switch content {
        // Before the default arm: SSHPaneContent is a TerminalPaneContent.
        case is SSHPaneContent: return .ssh
        case is MarkdownPaneContent: return .markdown
        case is ImagePaneContent: return .image
        case is PDFPaneContent: return .pdf
        case is FileViewerPaneContent: return .viewer
        case is DiffPaneContent: return .diff
        case is TranscriptPaneContent: return .transcript
        default: return .terminal
        }
    }

    var title: String { customTitle ?? contentTitle ?? content.defaultTitle }

    // The session state this tab should advertise; nil once its shell is gone
    // (the exit indicator takes over then).
    var liveSessionState: ClaudeSessionState? {
        exitStatus == nil ? claudeSession?.state : nil
    }

    var failed: Bool { exitStatus.map { !$0.isClean } ?? false }

    // Non-nil while something the user launched runs in the foreground of a
    // terminal tab; close paths warn before killing it.
    var runningProcessName: String? {
        guard exitStatus == nil else { return nil }
        return (content as? TerminalPaneContent)?.runningProcessName
    }

    // MARK: - Content callbacks (routed here, not through Pane, so background
    // tabs keep reporting — a hidden claude tab's title change or exit must
    // still reach the strip).

    func contentTitleDidChange(_ title: String) {
        contentTitle = title
        store?.tabDidChange(self)
    }

    func contentProcessDidExit(_ status: ProcessExitStatus?) {
        exitStatus = status
        store?.tabProcessDidExit(self)
    }

    func wantsAttention() {
        store?.tabWantsAttention(self)
    }
}

// What the store reports back to its owner (TerminalWindowController).
protocol TabStoreDelegate: AnyObject {
    // Title/status/session visuals changed — refresh strip, header, window title.
    func tabDidChange(_ tab: Tab)
    // The tab's process exited; owner decides (clean → auto-close, else mark red).
    func tabProcessDidExit(_ tab: Tab)
    // Bell in a background tab — pulse its strip item.
    func tabWantsAttention(_ tab: Tab)
}

// The window's ordered tab list plus MRU order and the reopen stack. Pure
// model: no views, no tree surgery — TerminalWindowController owns policy.
final class TabStore {
    private(set) var tabs: [Tab] = []
    // Most-recently-used tab ids, most recent first — drives ⌃Tab switching
    // and the fallback a pane shows when its tab closes.
    private(set) var mruIds: [String] = []
    // Recently closed tabs, most recent first, for ⇧⌘T (capped).
    private(set) var closedTabs: [SavedTab] = []
    private static let closedTabsCap = 12

    weak var delegate: TabStoreDelegate?

    var pinnedCount: Int {
        tabs.prefix(while: { $0.isPinned }).count
    }

    func tab(withId id: String) -> Tab? {
        tabs.first { $0.id == id }
    }

    func index(of tab: Tab) -> Int? {
        tabs.firstIndex { $0 === tab }
    }

    // Inserts at `index` (nil = append), clamped so pinned tabs stay a prefix.
    func insert(_ tab: Tab, at index: Int? = nil) {
        tab.store = self
        // At most one preview tab per window.
        if tab.isPreview, let old = tabs.first(where: { $0.isPreview }) {
            old.isPreview = false
        }
        var clamped = min(max(index ?? tabs.count, 0), tabs.count)
        if tab.isPinned {
            clamped = min(clamped, pinnedCount)
        } else {
            clamped = max(clamped, pinnedCount)
        }
        tabs.insert(tab, at: clamped)
        touchMRU(tab)
    }

    // Removes without teardown — the caller owns what happens to the content
    // (close teardown, move to another window, tear-off).
    func remove(_ tab: Tab) {
        tabs.removeAll { $0 === tab }
        mruIds.removeAll { $0 == tab.id }
        if tab.store === self { tab.store = nil }
    }

    // Reorder within the strip; `to` is an insertion index in the pre-removal
    // ordering (what a drop location naturally yields). Crossing the pin
    // boundary pins/unpins, browser-style.
    func move(_ tab: Tab, toInsertionIndex to: Int) {
        guard let from = index(of: tab) else { return }
        var destination = min(max(to, 0), tabs.count)
        if destination > from { destination -= 1 }
        tabs.remove(at: from)
        // Recompute against the post-removal pin prefix.
        let boundary = pinnedCount
        tab.isPinned = destination < boundary || (destination == boundary && tab.isPinned)
        // Pinning is a keep-forever gesture: it also ends preview-ness, or the
        // next openFile would silently replace the pinned tab's content.
        if tab.isPinned { tab.isPreview = false }
        tabs.insert(tab, at: min(max(destination, tab.isPinned ? 0 : boundary), tabs.count))
    }

    func setPinned(_ pinned: Bool, for tab: Tab) {
        guard tab.isPinned != pinned, let from = index(of: tab) else { return }
        tabs.remove(at: from)
        tab.isPinned = pinned
        tab.isPreview = tab.isPreview && !pinned
        tabs.insert(tab, at: pinnedCount)
    }

    func touchMRU(_ tab: Tab) {
        mruIds.removeAll { $0 == tab.id }
        mruIds.insert(tab.id, at: 0)
    }

    // Tabs in most-recently-used order (ids that no longer resolve are skipped).
    func tabsInMRUOrder() -> [Tab] {
        var seen = Set<String>()
        var result: [Tab] = []
        for id in mruIds {
            if let tab = tab(withId: id) { result.append(tab); seen.insert(id) }
        }
        result.append(contentsOf: tabs.filter { !seen.contains($0.id) })
        return result
    }

    // The tab a pane should fall back to when its displayed tab goes away:
    // the most recently used tab that isn't visible in any pane.
    func mruBackgroundTab(excluding excluded: Tab? = nil) -> Tab? {
        tabsInMRUOrder().first { $0.pane == nil && $0 !== excluded }
    }

    // The window's single preview tab of a given content kind, if any.
    func previewTab(where matches: (PaneContent) -> Bool) -> Tab? {
        tabs.first { $0.isPreview && matches($0.content) }
    }

    // MARK: - Reopen stack (⇧⌘T)

    func rememberClosed(_ saved: SavedTab?) {
        guard let saved else { return }
        closedTabs.insert(saved, at: 0)
        if closedTabs.count > Self.closedTabsCap {
            closedTabs.removeLast(closedTabs.count - Self.closedTabsCap)
        }
    }

    func popClosed() -> SavedTab? {
        closedTabs.isEmpty ? nil : closedTabs.removeFirst()
    }

    // Restore-time MRU seeding.
    func setMRUOrder(_ orderedTabs: [Tab]) {
        mruIds = orderedTabs.map { $0.id }
    }

    // MARK: - Delegate forwarding (Tab calls these)

    func tabDidChange(_ tab: Tab) { delegate?.tabDidChange(tab) }
    func tabProcessDidExit(_ tab: Tab) { delegate?.tabProcessDidExit(tab) }
    func tabWantsAttention(_ tab: Tab) { delegate?.tabWantsAttention(tab) }
}
