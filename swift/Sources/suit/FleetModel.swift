import Foundation

// The fleet dashboard's pure projection model (no AppKit): live sessions →
// ordered FleetRows (needs-you-first, subagent tree woven in) plus the Kanban
// column mapping. Standalone so the ordering and field mapping are verifiable
// without any UI; FleetDashboard.swift holds the views and controller that
// render these rows.

// MARK: - Model

// The four steering verbs a row exposes; the controller reports which was
// tapped and the AppDelegate dispatches it against the hosting pane.
enum FleetAction {
    case focus
    case interrupt
    case cont
    case archive
}

// One dashboard row: a live session projected into display fields plus whether
// a pane actually hosts its pty (only hosted sessions can be steered — the
// others are "done" files that outlived their process, or sessions in a window
// that has since closed the tab).
struct FleetRow {
    let id: String
    let state: ClaudeSessionState
    let title: String        // current-task summary / session name
    let project: String      // git-repo name (worktree's parent), or cwd basename
    let worktree: String?    // worktree dir when the session runs in one
    let branch: String?      // resolved async off the main thread; nil until then
    let contextPct: Double?
    let costUSD: Double?
    let hosted: Bool         // some pane in some window hosts this session's pty
    // Subagent tree: indent depth (0 = a top-level session,
    // 1+ = a nested `isolation: worktree` subagent) and whether this row is a
    // bare subagent worktree with no live session (a checkout Claude Code spun
    // for a subagent but whose session file hasn't appeared / was pruned).
    var depth: Int = 0
    var isBareWorktree: Bool = false
}

// Pure projection of the monitor's sessions into ordered rows, standalone so
// the ordering + field mapping is verifiable without any AppKit. Sorted
// needs-you-first (ClaudeSessionState.sortRank), then most-recently-updated,
// matching the monitor's own sort so the dashboard and the picker agree.
enum FleetModel {
    static func rows(
        sessions: [ClaudeSession],
        hostedIds: Set<String>,
        branch: (String) -> String? = { _ in nil }
    ) -> [FleetRow] {
        sessions
            .sorted {
                ($0.state.sortRank, $1.updatedAt.timeIntervalSince1970)
                    < ($1.state.sortRank, $0.updatedAt.timeIntervalSince1970)
            }
            .map { session in
                let place = projectAndWorktree(cwd: session.cwd)
                return FleetRow(
                    id: session.id,
                    state: session.state,
                    title: session.displayName,
                    project: place.project,
                    worktree: place.worktree,
                    branch: session.cwd.flatMap(branch),
                    contextPct: session.contextPct,
                    costUSD: session.costUSD,
                    hosted: hostedIds.contains(session.id)
                )
            }
    }

    // Splits a session cwd into a repo name + optional worktree name. A task
    // worktree lives at `<repo>/.claude/worktrees/<name>`, so the repo name is
    // the segment before `.claude` and the worktree is `<name>`; anything else
    // shows its own basename as the project with no worktree line.
    static func projectAndWorktree(cwd: String?) -> (project: String, worktree: String?) {
        guard let cwd, !cwd.isEmpty else { return ("—", nil) }
        let parts = (cwd as NSString).pathComponents
        if let marker = parts.firstIndex(of: ".claude"),
           marker + 2 < parts.count,
           parts[marker + 1] == "worktrees" {
            let repo = marker > 0 ? parts[marker - 1] : "—"
            return (repo, parts[marker + 2])
        }
        return ((cwd as NSString).lastPathComponent, nil)
    }

    // Weaves the subagent tree into the flat session rows:
    // each top-level session keeps its needs-you-first order, immediately
    // followed by its nested `isolation: worktree` subagents (indented via
    // `depth`). A subagent that has its own live session reuses that session's
    // row; one without shows as a bare worktree row. Sessions rendered as a
    // nested child are not repeated at the top level; sessions the tree never
    // saw (e.g. no cwd) fall through as plain roots so none are dropped.
    static func tree(sessionRows: [FleetRow], roots: [SubagentNode]) -> [FleetRow] {
        let nestedSessionIds = Set(
            SubagentTree.flatten(roots)
                .filter { $0.depth > 0 }
                .compactMap { $0.node.sessionId }
        )
        var out: [FleetRow] = []
        for sessionRow in sessionRows {
            if nestedSessionIds.contains(sessionRow.id) { continue }
            guard let root = roots.first(where: { $0.sessionId == sessionRow.id }) else {
                out.append(withDepth(sessionRow, 0))
                continue
            }
            for entry in SubagentTree.flatten([root]) {
                if entry.depth == 0 {
                    out.append(withDepth(sessionRow, 0))
                } else if let sid = entry.node.sessionId,
                          let childRow = sessionRows.first(where: { $0.id == sid }) {
                    out.append(withDepth(childRow, entry.depth))
                } else {
                    out.append(bareRow(for: entry.node, depth: entry.depth))
                }
            }
        }
        return out
    }

    private static func withDepth(_ row: FleetRow, _ depth: Int) -> FleetRow {
        var copy = row
        copy.depth = depth
        return copy
    }

    // A subagent worktree with no live session: shown muted, unsteerable.
    private static func bareRow(for node: SubagentNode, depth: Int) -> FleetRow {
        let place = projectAndWorktree(cwd: node.path)
        return FleetRow(
            id: node.path,
            state: .done,
            title: node.name,
            project: place.project,
            worktree: place.worktree ?? node.name,
            branch: node.branch,
            contextPct: nil,
            costUSD: nil,
            hosted: false,
            depth: depth,
            isBareWorktree: true
        )
    }
}

// MARK: - Kanban

// The optional board layout (Vibe-Kanban model): one card = one worktree = one
// agent. Sessions map onto the three live columns by state; the To-do column is
// present for the model's completeness but sessions never populate it (a session
// exists only once its agent is running), so it renders empty.
enum FleetColumn: Int, CaseIterable {
    case todo
    case running
    case needsYou
    case done

    var title: String {
        switch self {
        case .todo: return "To-do"
        case .running: return "Running"
        case .needsYou: return "Needs you"
        case .done: return "Done"
        }
    }

    static func column(for state: ClaudeSessionState) -> FleetColumn {
        switch state {
        case .working: return .running
        case .needsInput: return .needsYou
        case .done: return .done
        }
    }
}
