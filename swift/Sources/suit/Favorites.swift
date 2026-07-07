import Cocoa

// Recently shown project roots backing the sidebar's bottom project switcher
// (RecentFoldersView). Stored in ~/.suit/favorites.json (like notes and
// session files) so the list survives rebuilds and is shared across windows.
// The name is historical: the file once also held the removed Favorites tab's
// starred paths and file recents, and keeping the store/file name keeps
// existing recent-folder lists decoding.
final class FavoritesStore {
    static let shared = FavoritesStore()
    static let didUpdate = Notification.Name("FavoritesStoreDidUpdate")

    private static let maxRecentFolders = 8

    private struct Model: Codable {
        // Optional so a favorites.json written before the sidebar's project
        // switcher existed still decodes.
        var recentFolders: [Recent]?
    }

    struct Recent: Codable {
        let path: String
        let at: TimeInterval
    }

    private var model = Model()

    // $HOME rather than NSHomeDirectory() so tests/harnesses can point the
    // store at a scratch home (same reasoning as ClaudeIntegration).
    private var fileURL: URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home + "/.suit/favorites.json")
    }

    private init() {
        load()
    }

    // Recently shown project roots (pinned folders and followed pane
    // projects), newest first — the sidebar's bottom project switcher.
    var recentFolders: [String] {
        (model.recentFolders ?? []).map(\.path)
    }

    func noteRecentFolder(_ path: String) {
        // A shell parked in the home directory isn't a project.
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        if path == home { return }
        var folders = model.recentFolders ?? []
        if folders.first?.path == path { return }
        folders.removeAll { $0.path == path }
        folders.insert(Recent(path: path, at: Date().timeIntervalSince1970), at: 0)
        if folders.count > Self.maxRecentFolders {
            folders.removeLast(folders.count - Self.maxRecentFolders)
        }
        model.recentFolders = folders
        save()
    }

    func removeRecentFolder(_ path: String) {
        model.recentFolders?.removeAll { $0.path == path }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Model.self, from: data) else { return }
        model = decoded
        // Paths can vanish between launches (deleted files, removed
        // worktrees); drop them on load rather than showing dead rows.
        model.recentFolders?.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
    }

    private func save() {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(model) {
            try? data.write(to: fileURL, options: .atomic)
        }
        NotificationCenter.default.post(name: Self.didUpdate, object: self)
    }
}
