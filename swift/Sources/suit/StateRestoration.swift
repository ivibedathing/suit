import Cocoa

// State restoration (cross-cutting ROADMAP principle): reopen with the same
// windows, tabs, and layout. Captured at quit (applicationWillTerminate) and
// replayed on the next launch.
//
// The browser-tab model's snapshot: each window saves its ordered tab list
// (the strip), the split tree whose leaves reference tab indices (which tabs
// were visible in panes), the MRU order, and the active tab.
//
// What restores and what doesn't:
// - Terminal tabs come back as fresh shells in their old cwd — processes
//   don't survive a relaunch.
// - Viewer tabs re-open their file at the old scroll position (skipped when
//   the file is gone); diff tabs re-run `git diff HEAD` for their old root.
// - Transcript tabs are skipped: their session is gone by the next launch.
// A pane whose tab was skipped collapses out of the split; a window with no
// restorable tabs restores as a plain shell.

struct SavedTab: Codable {
    enum Kind: String, Codable {
        case terminal, viewer, diff, ssh, markdown, image, pdf, commitGraph
    }

    var kind: Kind
    var cwd: String?             // terminal: where the fresh shell starts
    var filePath: String?        // viewer / markdown / image / PDF
    var firstVisibleLine: Int?   // viewer scroll position
    var diffRoot: String?        // diff: the project root it was showing
    var graphRoot: String? = nil // commitGraph: the repo root it was showing
    var reviewComments: [DiffReviewComment]? = nil  // diff: review draft
    var isPreview = false
    var isPinned: Bool? = nil
    var customTitle: String? = nil
    // ssh: the saved host to reconnect to (command pre-typed, not submitted).
    // A deleted host falls back to a plain terminal in `cwd`. Never a password.
    var sshHostId: String? = nil
    // Preview-tab scroll/zoom, restored after the window reaches full size
    //: markdown scroll fraction, image zoom, PDF page.
    var scrollFraction: Double? = nil
    var imageActualSize: Bool? = nil
    var pdfPage: Int? = nil
}

indirect enum SavedNode: Codable {
    // A viewport displaying tabs[tabIndex]; fontSize is the per-pane
    // Cmd-=/Cmd-- override (nil = global font).
    case pane(tabIndex: Int, fontSize: Double?)
    case split(vertical: Bool, fraction: Double, first: SavedNode, second: SavedNode)
}

struct SavedWindow: Codable {
    var frame: NSRect
    var tabs: [SavedTab]
    var tree: SavedNode?
    var mru: [Int]? = nil          // indices into tabs, most recent first
    var activeTabIndex: Int? = nil
}

struct SavedAppState: Codable {
    var windows: [SavedWindow]

    private static let defaultsKey = "savedAppStateV2"
    private static let legacyDefaultsKey = "savedAppState"

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        // Note: the legacy snapshot is intentionally NOT removed here. It's the
        // migration fallback, and dropping it on the first V2 *write* would leave
        // nothing to fall back to if that V2 blob later fails to decode. It's
        // cleared instead the first time a V2 blob decodes successfully in load().
    }

    static func load() -> SavedAppState? {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let state = try? JSONDecoder().decode(SavedAppState.self, from: data),
           !state.windows.isEmpty {
            // A V2 blob decoded — the legacy fallback has served its purpose.
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
            return state
        }
        // First launch after the browser-tab rebuild: migrate the per-pane
        // snapshot the previous version saved.
        guard let data = UserDefaults.standard.data(forKey: legacyDefaultsKey),
              let legacy = try? JSONDecoder().decode(LegacyAppState.self, from: data),
              !legacy.windows.isEmpty else { return nil }
        let migrated = SavedAppState(windows: legacy.windows.map { $0.migrated() })
        return migrated.windows.isEmpty ? nil : migrated
    }
}

// Decode windows one at a time so a single corrupt or forward-incompatible
// window (a truncated blob, a renamed non-optional field in a future build) is
// dropped rather than throwing and discarding the *entire* saved session —
// best-effort restore instead of all-or-nothing. Defined in an extension so the
// memberwise `init(windows:)` used by the migration path is preserved, and the
// synthesized `encode(to:)` is kept.
extension SavedAppState {
    private enum CodingKeys: String, CodingKey { case windows }

    // A window slot that never throws: a window that fails to decode becomes nil
    // and is compacted out, while the array decode still advances past it.
    private struct LenientWindow: Decodable {
        let window: SavedWindow?
        init(from decoder: Decoder) throws {
            window = try? SavedWindow(from: decoder)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let slots = try container.decodeIfPresent([LenientWindow].self, forKey: .windows) ?? []
        self.windows = slots.compactMap { $0.window }
    }
}

// MARK: - Legacy (pre-browser-tabs) snapshot, kept only to migrate

// Mirrors the old synthesized-Codable shapes exactly, so the previous
// version's JSON decodes unchanged.
private struct LegacyTab: Codable {
    enum Kind: String, Codable { case terminal, viewer, diff }
    var kind: Kind
    var cwd: String?
    var filePath: String?
    var firstVisibleLine: Int?
    var diffRoot: String?
    var isPreview = false

    func migrated(customTitle: String?) -> SavedTab {
        SavedTab(
            kind: SavedTab.Kind(rawValue: kind.rawValue) ?? .terminal,
            cwd: cwd, filePath: filePath, firstVisibleLine: firstVisibleLine,
            diffRoot: diffRoot, isPreview: isPreview, isPinned: false,
            customTitle: customTitle
        )
    }
}

private struct LegacyPane: Codable {
    var tabs: [LegacyTab]
    var selectedIndex: Int
    var customTitle: String?
    var fontSize: Double? = nil
}

private indirect enum LegacyNode: Codable {
    case pane(LegacyPane)
    case split(vertical: Bool, fraction: Double, first: LegacyNode, second: LegacyNode)
}

private struct LegacyWindow: Codable {
    var frame: NSRect
    var tree: LegacyNode

    // Flatten every pane's tabs into one window tab list; each pane's
    // *selected* tab becomes that leaf's visible tab, the rest background.
    func migrated() -> SavedWindow {
        var tabs: [SavedTab] = []

        func migrate(_ node: LegacyNode) -> SavedNode? {
            switch node {
            case .pane(let pane):
                guard !pane.tabs.isEmpty else { return nil }
                let base = tabs.count
                for (i, tab) in pane.tabs.enumerated() {
                    // The old custom title was pane-level; it labeled whatever
                    // the pane showed, so it lands on the selected tab.
                    tabs.append(tab.migrated(customTitle: i == pane.selectedIndex ? pane.customTitle : nil))
                }
                let selected = min(max(0, pane.selectedIndex), pane.tabs.count - 1)
                return .pane(tabIndex: base + selected, fontSize: pane.fontSize)
            case .split(let vertical, let fraction, let first, let second):
                let a = migrate(first)
                let b = migrate(second)
                guard let a else { return b }
                guard let b else { return a }
                return .split(vertical: vertical, fraction: fraction, first: a, second: b)
            }
        }

        let tree = migrate(self.tree)
        return SavedWindow(frame: frame, tabs: tabs, tree: tree, mru: nil, activeTabIndex: nil)
    }
}

private struct LegacyAppState: Codable {
    var windows: [LegacyWindow]
}
