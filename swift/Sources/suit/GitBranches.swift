import Foundation

// Branch / PR overview (ROADMAP Phase 21): the shipping end of the review
// workflow. `GitBranchList` reads the repo's local branches with their
// ahead/behind vs upstream, which worktree (if any) has them checked out, and
// whether that worktree is dirty — all from plumbing git, off the main thread.
// `GitHubCLI` layers optional `gh` actions on top (PR status, create, open on
// web), degrading to a no-op when `gh` isn't installed.

// One local branch, as the Git tab lists it.
struct GitBranchInfo {
    let name: String
    let upstream: String?        // "origin/foo" or nil when no upstream is set
    let ahead: Int               // commits on this branch not on its upstream
    let behind: Int              // commits on its upstream not on this branch
    let isCurrent: Bool          // the shown root's checked-out branch
    let worktreePath: String?    // the worktree this branch is checked out in
    let isDirty: Bool            // that worktree has uncommitted changes
}

enum GitBranchList {
    private static let git = "/usr/bin/git"

    // The repo's local branches, current first, then alphabetical. Ahead/behind
    // come from `%(upstream:track)` in one for-each-ref pass rather than a
    // rev-list per branch; dirtiness is one `git status` per *worktree* (few),
    // cached so branches sharing a worktree don't re-run it.
    static func compute(root: String, currentBranch: String?) -> [GitBranchInfo] {
        guard let output = runProcess(git, [
            "-C", root, "for-each-ref",
            "--format=%(refname:short)%09%(upstream:short)%09%(upstream:track,nobracket)",
            "refs/heads",
        ]) else { return [] }

        let worktrees = worktreeBranchMap(root: root)
        var dirtyByPath: [String: Bool] = [:]
        var result: [GitBranchInfo] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let cols = line.components(separatedBy: "\t")
            guard let name = cols.first, !name.isEmpty else { continue }
            let upstream = cols.count > 1 && !cols[1].isEmpty ? cols[1] : nil
            let (ahead, behind) = parseTrack(cols.count > 2 ? cols[2] : "")
            let worktreePath = worktrees[name]
            var dirty = false
            if let worktreePath {
                if let cached = dirtyByPath[worktreePath] {
                    dirty = cached
                } else {
                    dirty = WorktreeTasks.hasUncommittedChanges(worktreePath)
                    dirtyByPath[worktreePath] = dirty
                }
            }
            result.append(GitBranchInfo(
                name: name, upstream: upstream, ahead: ahead, behind: behind,
                isCurrent: name == currentBranch, worktreePath: worktreePath, isDirty: dirty
            ))
        }
        result.sort { a, b in
            if a.isCurrent != b.isCurrent { return a.isCurrent }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return result
    }

    // "ahead 2, behind 1" / "ahead 3" / "behind 2" / "gone" / "" → counts.
    private static func parseTrack(_ track: String) -> (ahead: Int, behind: Int) {
        var ahead = 0, behind = 0
        for part in track.components(separatedBy: ",") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            if piece.hasPrefix("ahead ") { ahead = Int(piece.dropFirst(6)) ?? 0 }
            else if piece.hasPrefix("behind ") { behind = Int(piece.dropFirst(7)) ?? 0 }
        }
        return (ahead, behind)
    }

    // branch name → the worktree path it's checked out in, from
    // `git worktree list --porcelain` (blocks of "worktree <path>" then
    // "branch refs/heads/<name>").
    private static func worktreeBranchMap(root: String) -> [String: String] {
        guard let output = runProcess(git, ["-C", root, "worktree", "list", "--porcelain"]) else {
            return [:]
        }
        var map: [String: String] = [:]
        var currentPath: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("worktree ") {
                currentPath = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch refs/heads/"), let path = currentPath {
                map[String(line.dropFirst("branch refs/heads/".count))] = path
            }
        }
        return map
    }
}

// A pull request for a branch, from `gh pr list`.
struct GitPRInfo {
    enum State: String {
        case open = "OPEN"
        case merged = "MERGED"
        case closed = "CLOSED"
    }
    enum Checks {
        case passing, failing, pending
    }
    let number: Int
    let state: State
    let url: String
    let checks: Checks?
}

// The optional GitHub layer. Every entry point is a no-op / graceful failure
// when `gh` isn't installed, so the Git tab works identically without it.
enum GitHubCLI {
    // gh lives in Homebrew's bin, which isn't on a GUI app's minimal PATH — so
    // probe the known install locations directly rather than trusting $PATH.
    // Resolved once (nil = not installed); the result is stable for a session.
    private static let resolvedPath: String? = {
        for candidate in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh", "/run/current-system/sw/bin/gh"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        // Last resort: let the login shell resolve it.
        if let found = runProcess("/bin/zsh", ["-l", "-c", "command -v gh"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !found.isEmpty,
           FileManager.default.isExecutableFile(atPath: found) {
            return found
        }
        return nil
    }()

    static var isAvailable: Bool { resolvedPath != nil }

    // All PRs (any state) for the repo, keyed by their branch (headRefName). A
    // branch with several PRs keeps its open one, else the most recent. Returns
    // empty on any failure (gh missing, no remote, not authed, offline) — the
    // caller just shows branches without PR badges.
    static func pullRequests(root: String) -> [String: GitPRInfo] {
        guard let gh = resolvedPath,
              case .success(let output) = run(gh, cwd: root, [
                  "pr", "list", "--state", "all", "--limit", "100",
                  "--json", "number,headRefName,state,url,statusCheckRollup",
              ]),
              let data = output.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [:] }

        var result: [String: GitPRInfo] = [:]
        for entry in array {
            guard let branch = entry["headRefName"] as? String,
                  let number = entry["number"] as? Int,
                  let stateRaw = entry["state"] as? String,
                  let state = GitPRInfo.State(rawValue: stateRaw),
                  let url = entry["url"] as? String
            else { continue }
            let checks = summarizeChecks(entry["statusCheckRollup"] as? [[String: Any]])
            let pr = GitPRInfo(number: number, state: state, url: url, checks: checks)
            // Prefer an open PR over a stale merged/closed one for the branch.
            if let existing = result[branch], existing.state == .open, state != .open { continue }
            result[branch] = pr
        }
        return result
    }

    // statusCheckRollup mixes CheckRun (status/conclusion) and StatusContext
    // (state) entries; collapse to one traffic light.
    private static func summarizeChecks(_ rollup: [[String: Any]]?) -> GitPRInfo.Checks? {
        guard let rollup, !rollup.isEmpty else { return nil }
        var anyPending = false
        for check in rollup {
            let conclusion = (check["conclusion"] as? String)?.uppercased() ?? ""
            let state = (check["state"] as? String)?.uppercased() ?? ""
            let status = (check["status"] as? String)?.uppercased() ?? ""
            if ["FAILURE", "TIMED_OUT", "CANCELLED", "ERROR", "ACTION_REQUIRED"].contains(conclusion)
                || ["FAILURE", "ERROR"].contains(state) {
                return .failing
            }
            if (status != "COMPLETED" && !status.isEmpty) || state == "PENDING"
                || (conclusion.isEmpty && state.isEmpty && status.isEmpty) {
                anyPending = true
            }
        }
        return anyPending ? .pending : .passing
    }

    // The repo's default branch ("main"/"master"), from origin/HEAD when set.
    private static func defaultBranch(root: String) -> String? {
        if let head = runProcess("/usr/bin/git", ["-C", root, "symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty {
            return (head as NSString).lastPathComponent
        }
        for candidate in ["main", "master"] {
            if runProcess("/usr/bin/git", ["-C", root, "rev-parse", "--verify", "-q", candidate]) != nil {
                return candidate
            }
        }
        return nil
    }

    // A best-effort PR body: the branch's commit subjects that aren't on the
    // default branch, one bullet each (empty when the base can't be resolved).
    static func commitBody(root: String, branch: String) -> String {
        guard let base = defaultBranch(root: root), base != branch,
              let log = runProcess("/usr/bin/git", ["-C", root, "log", "--format=%s", "\(base)..\(branch)"])
        else { return "" }
        let subjects = log.split(separator: "\n", omittingEmptySubsequences: true).map { "- \($0)" }
        return subjects.joined(separator: "\n")
    }

    // `gh pr create` for the branch. Returns the new PR's URL (gh prints it on
    // the last stdout line) or gh's own error text — shown verbatim so an
    // unpushed branch / missing auth explains itself.
    static func createPR(root: String, branch: String, title: String, body: String) -> Result<String, WorktreeTaskError> {
        guard let gh = resolvedPath else { return .failure(WorktreeTaskError(message: "The gh CLI isn’t installed.")) }
        let result = run(gh, cwd: root, ["pr", "create", "--head", branch, "--title", title, "--body", body])
        switch result {
        case .success(let out):
            let url = out.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init) ?? ""
            return .success(url.trimmingCharacters(in: .whitespaces))
        case .failure(let error):
            return .failure(error)
        }
    }

    // Opens the branch on GitHub: the PR page when one exists, otherwise the
    // "create PR" compare page — both in the browser (gh handles auth). Runs
    // detached; failures are silent (best-effort convenience action).
    static func openWeb(root: String, branch: String, hasPR: Bool) {
        guard let gh = resolvedPath else { return }
        let args = hasPR
            ? ["pr", "view", branch, "--web"]
            : ["pr", "create", "--head", branch, "--web"]
        DispatchQueue.global(qos: .userInitiated).async { _ = run(gh, cwd: root, args) }
    }

    // gh with stdout/stderr captured; stderr's first line is the error message.
    // gh has no `-C` flag (that's a git-ism) — it's pointed at a repo by its
    // working directory instead.
    private static func run(_ executable: String, cwd: String, _ arguments: [String]) -> Result<String, WorktreeTaskError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // gh reads config/creds relative to $HOME; keep the inherited env.
        do {
            try process.run()
        } catch {
            return .failure(WorktreeTaskError(message: error.localizedDescription))
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            return .success(String(decoding: outData, as: UTF8.self))
        }
        let message = String(decoding: errData, as: UTF8.self)
            .split(separator: "\n").first.map(String.init)
            ?? "gh exited \(process.terminationStatus)"
        return .failure(WorktreeTaskError(message: message.trimmingCharacters(in: .whitespaces)))
    }
}
