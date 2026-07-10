import Cocoa

// The AppKit half of the command-history search: the source that feeds
// the ⌃R overlay. Two sources, merged by the pure CommandHistory core:
//
//   • shell history — $HISTFILE (or ~/.zsh_history / ~/.bash_history), read off
//     the main thread and refreshed lazily (each time the overlay opens, at most
//     once every few seconds), deduped most-recent-first.
//   • per-pane scrollback — the commands the user actually submitted in each
//     pane this session, recorded live by PaneTerminalView (see its send()
//     override) so they surface even when they haven't hit $HISTFILE yet, and so
//     a missing history file still gives ⌃R something to search.
final class CommandHistoryStore {
    static let shared = CommandHistoryStore()

    // The parsed shell history, newest-first (main-thread readable; replaced
    // wholesale by the background reload).
    private var shellCommands: [String] = []
    // Per-pane submitted commands this session, newest-first, capped. Keyed by
    // the source pane's cwd for the row hint; a nil cwd still records.
    private var paneCommands: [HistoryCommand] = []
    private static let paneCap = 400

    private var lastReload = Date.distantPast
    private var reloading = false

    private init() {}

    // The merged, deduped, newest-first corpus the overlay ranks. Cheap — the
    // heavy file read happens in reloadIfStale().
    func commands() -> [HistoryCommand] {
        CommandHistory.merged(pane: paneCommands, shell: shellCommands)
    }

    // Kick a background reload of the history file if the cache is older than a
    // few seconds. Called when the overlay is about to open, so it's fresh
    // without watching the file. `then` runs on the main thread after the
    // reload lands (or immediately when the cache is warm).
    func reloadIfStale(then: (() -> Void)? = nil) {
        if Date().timeIntervalSince(lastReload) < 3 || reloading {
            then?()
            return
        }
        reloading = true
        let path = Self.historyPath()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let parsed: [String]
            if let path, let data = FileManager.default.contents(atPath: path) {
                // zsh history is Latin-1-ish with occasional invalid UTF-8 from
                // metacharacter escaping; decode lossily so a stray byte never
                // drops the whole file.
                let text = String(decoding: data, as: UTF8.self)
                parsed = CommandHistory.parseZsh(text)
            } else {
                parsed = []
            }
            DispatchQueue.main.async {
                self?.shellCommands = parsed
                self?.lastReload = Date()
                self?.reloading = false
                then?()
            }
        }
    }

    // Record a command the user submitted in a pane (PaneTerminalView calls this
    // on Enter). Newest-first, deduped to its most-recent position, capped.
    func recordPaneCommand(_ text: String, cwd: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        paneCommands.removeAll { $0.text == trimmed }
        paneCommands.insert(HistoryCommand(text: trimmed, source: .pane(cwd: cwd)), at: 0)
        if paneCommands.count > Self.paneCap {
            paneCommands.removeLast(paneCommands.count - Self.paneCap)
        }
    }

    // $HISTFILE when the environment exports it, else the usual zsh / bash files.
    // $HOME-first so a harness could sandbox it (matching the other ~/.suit
    // readers). Returns the first existing candidate, or nil (→ scrollback only).
    private static func historyPath() -> String? {
        let env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? NSHomeDirectory()
        var candidates: [String] = []
        if let histfile = env["HISTFILE"], !histfile.isEmpty {
            candidates.append((histfile as NSString).expandingTildeInPath)
        }
        candidates.append(home + "/.zsh_history")
        candidates.append(home + "/.bash_history")
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }
}
