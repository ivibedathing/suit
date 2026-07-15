import Foundation

// Mapping a directory back to the Autopilot that owns it. The terminal's
// context menu has to answer "is an Autopilot running on this pane's repo?" on
// every right-click, and `menu(for:)` is a hot main-thread path — so it must
// answer from paths alone. `FileIndex.gitRoot(of:)` would be the obvious
// resolver, but it shells out to `git rev-parse` per call; that cost is fine on
// click (see AppDelegate.startAutopilot(inDirectory:), which lets
// AutopilotManager.startHere resolve the root properly) and not fine on menu
// build. Containment against the roots we already have engines for needs no
// subprocess.
//
// Pure string work with no app dependencies, so it compiles standalone for the
// scratch logic tests (the RoadmapParser / AutopilotScheduler pattern).

enum AutopilotPaths {
    // Collapse the common spellings of one repo path (tilde, trailing slash) to
    // a single key so the same repo doesn't spawn two engines or two store
    // slots. Deliberately does NOT run through URL.standardizedFileURL: on macOS
    // that rewrites the `/private` symlink (`/private/tmp` → `/tmp`), which
    // would make run.worktreePath disagree with the worker shell's resolved cwd
    // and break session pinning. The root is otherwise used verbatim, exactly
    // as the old single-autopilot path did with autopilotProjectRoot.
    //
    // Lives here rather than on AutopilotManager (which re-exports it) so the
    // harness can pin that /private carve-out — it has regressed before.
    static func normalize(_ root: String) -> String {
        var expanded = (root as NSString).expandingTildeInPath
        while expanded.count > 1 && expanded.hasSuffix("/") { expanded = String(expanded.dropLast()) }
        return expanded
    }

    // Is `directory` the root itself or somewhere beneath it? Component-anchored
    // on the "/" so `/a/bc` is not read as living inside `/a/b` — a plain
    // hasPrefix would say it does. Both sides are normalized first, so a tilde
    // path and its expansion agree. An empty root contains nothing (an
    // unconfigured engine must not swallow every pane).
    static func directory(_ directory: String, isInside root: String) -> Bool {
        let dir = normalize(directory)
        let base = normalize(root)
        guard !base.isEmpty, base != "/", !dir.isEmpty else { return false }
        return dir == base || dir.hasPrefix(base + "/")
    }

    // The root that owns `directory`, or nil when none does. Longest match wins:
    // repos nest (a vendored checkout inside a parent repo), and Autopilot's own
    // worktrees live at <root>/.claude/worktrees/<slug> — a pane sitting in a
    // worker's worktree is still inside that project, and should offer to stop
    // the Autopilot driving it. Ties are impossible (equal-length roots that
    // both contain the same directory are the same root).
    static func bestRoot(for directory: String, among roots: [String]) -> String? {
        roots
            .filter { self.directory(directory, isInside: $0) }
            .max { normalize($0).count < normalize($1).count }
    }
}
