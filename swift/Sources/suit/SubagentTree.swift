import Foundation

// Subagent tree (ROADMAP Phase 31), the UI-free, standalone-compilable core
// (the RoadmapParser / FeedbackRouting / TaskLaunch pattern, Foundation-only):
// turns the flat session map + git worktree list into a nested forest so a
// session that fans out into `isolation: worktree` subagents reads as a tree
// instead of scattering anonymous checkouts across the fleet.
//
// The nesting rule is physical containment: Claude Code creates an
// `isolation: worktree` subagent's checkout under its parent's
// `.claude/worktrees/`, so a node whose path lives under
// `<parent>/.claude/worktrees/…` is that parent's subagent. The closest
// enclosing node wins, so main → task → sub nests correctly. Pruning is
// implicit — only worktrees still in the passed-in list appear, so the tree
// drops a subagent the moment Claude Code auto-removes its finished worktree.

struct SubagentTreeSession {
    let id: String
    let cwd: String
    // The session's state label ("working" / "needs-input" / "done", or
    // whatever the caller passes — kept a plain string so the pure core stays
    // free of the ClaudeSessionState enum and its AppKit color).
    let state: String
}

struct SubagentTreeWorktree {
    let path: String
    let branch: String?
}

// One node in the tree: a checkout that is either a live session's cwd
// (`sessionId != nil`) or a bare worktree (a subagent whose session file has
// not appeared, or already been pruned). Children are the checkouts nested
// under it via `.claude/worktrees/`.
final class SubagentNode {
    let path: String
    let sessionId: String?
    let state: String?
    let branch: String?
    private(set) var children: [SubagentNode] = []

    init(path: String, sessionId: String?, state: String?, branch: String?) {
        self.path = path
        self.sessionId = sessionId
        self.state = state
        self.branch = branch
    }

    // The last path component — the worktree/checkout name shown in the tree.
    var name: String { (path as NSString).lastPathComponent }

    fileprivate func addChild(_ node: SubagentNode) { children.append(node) }
    // Children ordered by name so the render is stable across reloads.
    fileprivate func sortRecursively() {
        children.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        children.forEach { $0.sortRecursively() }
    }
}

// One flattened row for a table/list render: the node plus its indent depth
// (0 = a top-level session, 1+ = a nested subagent).
struct SubagentTreeRow {
    let node: SubagentNode
    let depth: Int
}

enum SubagentTree {
    // The marker segment a subagent checkout sits under, relative to its
    // parent. Matches WorktreeTasks.worktreesSubpath ("/.claude/worktrees/").
    static let worktreesMarker = "/.claude/worktrees/"

    // Builds the forest, anchored on sessions. Session cwds seed the nodes; a
    // worktree is kept only when it nests inside some session's checkout (a
    // subagent) — a session-less worktree that merely *contains* a session
    // (the main repo checkout) is transparent, never a node, so it can't hide
    // the session subtree beneath it. Every kept node attaches under its
    // nearest *session* ancestor; sessions with no session ancestor are roots.
    static func build(sessions: [SubagentTreeSession], worktrees: [SubagentTreeWorktree]) -> [SubagentNode] {
        var byPath: [String: SubagentNode] = [:]
        var sessionPaths: [String] = []
        for session in sessions {
            let key = normalize(session.cwd)
            byPath[key] = SubagentNode(path: key, sessionId: session.id, state: session.state, branch: nil)
            sessionPaths.append(key)
        }
        for worktree in worktrees {
            let key = normalize(worktree.path)
            if let existing = byPath[key] {
                // The worktree is a session's own checkout — adopt its branch.
                if existing.branch == nil, worktree.branch != nil {
                    byPath[key] = SubagentNode(path: key, sessionId: existing.sessionId, state: existing.state, branch: worktree.branch)
                }
            } else if nearestSessionAncestor(of: key, sessionPaths: sessionPaths) != nil {
                // A bare subagent worktree nested inside a session's checkout.
                byPath[key] = SubagentNode(path: key, sessionId: nil, state: nil, branch: worktree.branch)
            }
            // else: contains no session and isn't inside one — not part of the
            // fleet's session tree; dropped.
        }

        let nodes = Array(byPath.values)
        var roots: [SubagentNode] = []
        for node in nodes {
            if let parentPath = nearestSessionAncestor(of: node.path, sessionPaths: sessionPaths),
               let parent = byPath[parentPath] {
                parent.addChild(node)
            } else {
                roots.append(node)
            }
        }
        roots.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        roots.forEach { $0.sortRecursively() }
        return roots
    }

    // Depth-first flatten for rendering: each root, then its descendants,
    // indented by depth.
    static func flatten(_ roots: [SubagentNode]) -> [SubagentTreeRow] {
        var rows: [SubagentTreeRow] = []
        func walk(_ node: SubagentNode, _ depth: Int) {
            rows.append(SubagentTreeRow(node: node, depth: depth))
            for child in node.children { walk(child, depth + 1) }
        }
        for root in roots { walk(root, 0) }
        return rows
    }

    // The session cwd that is the longest proper ancestor of `path` under the
    // `.claude/worktrees/` marker — the session that spawned this checkout as a
    // subagent. nil when no session encloses it. `path` itself is excluded so a
    // session never parents itself.
    private static func nearestSessionAncestor(of path: String, sessionPaths: [String]) -> String? {
        var best: String?
        for candidate in sessionPaths where candidate != path {
            guard path.hasPrefix(candidate + worktreesMarker) else { continue }
            if best == nil || candidate.count > best!.count {
                best = candidate
            }
        }
        return best
    }

    // Drop a trailing slash so "/a/" and "/a" unify; leave everything else
    // verbatim (paths arrive already absolute from git / the session files).
    private static func normalize(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}
