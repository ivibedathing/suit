import Foundation

// Shared worktree/branch enumeration for the switcher menus. The Files-tab git
// footer (FileBrowserView) and the Git tab's header dropdown both build their
// switcher from these, so the two never disagree about a repo's worktrees or
// branches. Pure git reads — the menus and their actions live in the views.
enum WorktreeSwitcher {
    // `git worktree list --porcelain`: blocks of "worktree <path>" followed by
    // "branch refs/heads/<name>" or "detached".
    static func worktrees(root: String) -> [(path: String, branch: String?)] {
        guard case .success(let output) = WorktreeTasks.runGit(root, ["worktree", "list", "--porcelain"]) else {
            return []
        }
        var result: [(path: String, branch: String?)] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("worktree ") {
                result.append((path: String(line.dropFirst("worktree ".count)), branch: nil))
            } else if line.hasPrefix("branch refs/heads/"), !result.isEmpty {
                result[result.count - 1].branch = String(line.dropFirst("branch refs/heads/".count))
            }
        }
        return result
    }

    static func branches(root: String) -> [String] {
        guard case .success(let output) = WorktreeTasks.runGit(root, ["for-each-ref", "--format=%(refname:short)", "refs/heads"]) else {
            return []
        }
        return output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
