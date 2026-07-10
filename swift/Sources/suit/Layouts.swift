import Foundation

// Saved layouts / named workspaces. State restoration
// (StateRestoration.swift) already reopens the *last* layout at quit; this
// makes layouts nameable and switchable — a "review" layout, a "debug"
// layout — on top of the same capture/replay machinery.
//
// A layout is a `SavedWindow` snapshot (the exact quit-time capture shape)
// tagged with a name + timestamp, persisted to ~/.suit/layouts.json (the
// FavoritesStore pattern: $HOME-first, atomic write, a `didUpdate`
// notification). The catalog operations and the restore-time pruning are
// UI-free (Foundation-only), so a standalone harness round-trips them without
// the app — see scripts/layouts-test.sh.

// One named layout: a captured window plus its name and when it was saved.
struct SavedLayout: Codable {
    var name: String
    var savedAt: TimeInterval
    var window: SavedWindow
}

// Pure operations over a layout list — no IO, so the store and the harness
// share one definition of save/rename/delete semantics. Names are matched
// case-insensitively (so "Review" overwrites "review") but stored verbatim.
enum LayoutCatalog {
    // The display/storage name, trimmed of surrounding whitespace.
    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // The index of an existing layout with this name (case-insensitive), or nil.
    static func index(of name: String, in layouts: [SavedLayout]) -> Int? {
        let key = normalized(name).lowercased()
        return layouts.firstIndex { $0.name.lowercased() == key }
    }

    static func named(_ name: String, in layouts: [SavedLayout]) -> SavedLayout? {
        index(of: name, in: layouts).map { layouts[$0] }
    }

    // Save under `name`, replacing any existing same-named layout (the spec's
    // overwrite) and otherwise appending. An empty name is rejected (unchanged).
    static func upsert(_ layouts: [SavedLayout], name: String, window: SavedWindow, at: TimeInterval) -> [SavedLayout] {
        let clean = normalized(name)
        guard !clean.isEmpty else { return layouts }
        var result = layouts
        let entry = SavedLayout(name: clean, savedAt: at, window: window)
        if let i = index(of: clean, in: result) {
            result[i] = entry
        } else {
            result.append(entry)
        }
        return result
    }

    // Rename `from` to `to`, no-op when `from` is absent, `to` is empty, or a
    // *different* layout already owns `to` (renaming onto oneself just changes
    // the casing).
    static func rename(_ layouts: [SavedLayout], from: String, to: String) -> [SavedLayout] {
        let clean = normalized(to)
        guard !clean.isEmpty, let i = index(of: from, in: layouts) else { return layouts }
        if let j = index(of: clean, in: layouts), j != i { return layouts }
        var result = layouts
        result[i].name = clean
        return result
    }

    static func remove(_ layouts: [SavedLayout], name: String) -> [SavedLayout] {
        guard let i = index(of: name, in: layouts) else { return layouts }
        var result = layouts
        result.remove(at: i)
        return result
    }

    // Alphabetical, case-insensitive — the stable order the picker/menu lists.
    static func sorted(_ layouts: [SavedLayout]) -> [SavedLayout] {
        layouts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// Restore-time pruning, mirroring TerminalWindowController's replay path
// (restoredContent / buildNode): a saved tab whose backing file or repo root
// is gone can't come back, so its pane collapses out of the split tree and the
// remaining tab indices renumber. The live restore achieves this implicitly
// (restoredContent returns nil → the pane is dropped in buildNode); this pure
// mirror is what the harness asserts against, and what a caller can use to tell
// whether a layout still has anything to restore.
enum LayoutRestore {
    // Whether a saved tab can be rebuilt. Terminals and SSH tabs always can (an
    // SSH tab with a missing host falls back to a plain shell); file-backed
    // kinds need their file, diff/graph tabs their repo root.
    static func isRestorable(_ tab: SavedTab, fileExists: (String) -> Bool) -> Bool {
        switch tab.kind {
        case .terminal, .ssh:
            return true
        case .viewer, .markdown, .image, .pdf:
            guard let path = tab.filePath else { return false }
            return fileExists(path)
        case .diff:
            guard let root = tab.diffRoot else { return false }
            return fileExists(root)
        case .commitGraph:
            guard let root = tab.graphRoot else { return false }
            return fileExists(root)
        }
    }

    // The window with only its restorable tabs, the split tree rewritten to the
    // new indices and collapsed where a pane's tab dropped, and mru/active
    // remapped (entries pointing at dropped tabs fall away).
    static func pruned(_ window: SavedWindow, fileExists: (String) -> Bool) -> SavedWindow {
        var newTabs: [SavedTab] = []
        var remap: [Int: Int] = [:]
        for (old, tab) in window.tabs.enumerated() where isRestorable(tab, fileExists: fileExists) {
            remap[old] = newTabs.count
            newTabs.append(tab)
        }

        func prune(_ node: SavedNode?) -> SavedNode? {
            guard let node else { return nil }
            switch node {
            case .pane(let tabIndex, let fontSize):
                guard let mapped = remap[tabIndex] else { return nil }
                return .pane(tabIndex: mapped, fontSize: fontSize)
            case .split(let vertical, let fraction, let first, let second):
                let a = prune(first)
                let b = prune(second)
                guard let a else { return b }
                guard let b else { return a }
                return .split(vertical: vertical, fraction: fraction, first: a, second: b)
            }
        }

        return SavedWindow(
            frame: window.frame,
            tabs: newTabs,
            tree: prune(window.tree),
            mru: window.mru?.compactMap { remap[$0] },
            activeTabIndex: window.activeTabIndex.flatMap { remap[$0] }
        )
    }
}

// The persisted catalog of named layouts — the FavoritesStore pattern
// (`$HOME`-first path, atomic write, a `didUpdate` post), Foundation-only so
// the harness can drive it against a scratch home.
final class LayoutStore {
    static let shared = LayoutStore()
    static let didUpdate = Notification.Name("LayoutStoreDidUpdate")

    private struct Model: Codable {
        // Optional so a layouts.json written by a future/older shape still
        // decodes (matching FavoritesStore's forgiving Model).
        var layouts: [SavedLayout]?
    }

    private var model = Model()

    // $HOME rather than NSHomeDirectory() so tests/harnesses can point the
    // store at a scratch home (same reasoning as FavoritesStore / ClaudeIntegration).
    private var fileURL: URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home + "/.suit/layouts.json")
    }

    private init() {
        load()
    }

    // The saved layouts, alphabetical — the order the picker/menu shows.
    var layouts: [SavedLayout] {
        LayoutCatalog.sorted(model.layouts ?? [])
    }

    var isEmpty: Bool {
        (model.layouts ?? []).isEmpty
    }

    func layout(named name: String) -> SavedLayout? {
        LayoutCatalog.named(name, in: model.layouts ?? [])
    }

    func exists(name: String) -> Bool {
        LayoutCatalog.index(of: name, in: model.layouts ?? []) != nil
    }

    // Save (or overwrite a same-named) layout from a captured window.
    func save(name: String, window: SavedWindow) {
        model.layouts = LayoutCatalog.upsert(
            model.layouts ?? [], name: name, window: window,
            at: Date().timeIntervalSince1970
        )
        persist()
    }

    func rename(from: String, to: String) {
        model.layouts = LayoutCatalog.rename(model.layouts ?? [], from: from, to: to)
        persist()
    }

    func remove(name: String) {
        model.layouts = LayoutCatalog.remove(model.layouts ?? [], name: name)
        persist()
    }

    // Re-read the file — the app never needs this (one process owns the store),
    // but the harness uses it to prove a save round-trips to disk.
    func reload() {
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Model.self, from: data) else { return }
        model = decoded
    }

    private func persist() {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(model) {
            try? data.write(to: fileURL, options: .atomic)
        }
        NotificationCenter.default.post(name: Self.didUpdate, object: self)
    }
}
