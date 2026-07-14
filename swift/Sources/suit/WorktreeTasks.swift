import Foundation

// Worktree orchestration: the CLAUDE.md "one worktree per
// task" discipline as one-keystroke product features. "New Claude Task" makes
// a worktree + branch and opens a pane running claude inside it; "Finish"
// merges (or discards) the branch and removes the worktree.
struct WorktreeTaskError: Error {
    let message: String
}

enum WorktreeTasks {
    static let worktreesSubpath = ".claude/worktrees"

    // Task names become branch/directory slugs.
    static func slug(from name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = name.lowercased().map { char -> Character in
            char.unicodeScalars.allSatisfy { allowed.contains($0) } ? char : "-"
        }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return String(collapsed.prefix(48))
    }

    static func isTaskWorktree(_ path: String?) -> Bool {
        path?.contains("/" + worktreesSubpath + "/") == true
    }

    // Creates the worktree (branch task/<slug>, from the project's HEAD) and
    // returns its absolute path.
    static func createTask(projectRoot: String, name: String) -> Result<String, WorktreeTaskError> {
        let slug = slug(from: name)
        guard !slug.isEmpty else { return .failure(WorktreeTaskError(message: "Task name is empty.")) }
        guard FileIndex.gitRoot(of: projectRoot) != nil else {
            return .failure(WorktreeTaskError(message: "\((projectRoot as NSString).lastPathComponent) is not a git repository."))
        }
        let directory = projectRoot + "/" + worktreesSubpath + "/" + slug
        guard !FileManager.default.fileExists(atPath: directory) else {
            return .failure(WorktreeTaskError(message: "A worktree named “\(slug)” already exists."))
        }
        let branch = "task/" + slug
        switch runGit(projectRoot, ["worktree", "add", "-b", branch, directory, "HEAD"]) {
        case .success:
            return .success(directory)
        case .failure(let error):
            return .failure(error)
        }
    }

    // The repo's main checkout, from inside any of its worktrees: the first
    // "worktree " entry of `git worktree list --porcelain` is always the main
    // working tree.
    static func mainRoot(ofWorktree path: String) -> String? {
        guard let output = runProcess("/usr/bin/git", ["-C", path, "worktree", "list", "--porcelain"]) else {
            return nil
        }
        for line in output.split(separator: "\n") where line.hasPrefix("worktree ") {
            return String(line.dropFirst("worktree ".count))
        }
        return nil
    }

    static func currentBranch(_ path: String) -> String? {
        runProcess("/usr/bin/git", ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hasUncommittedChanges(_ path: String) -> Bool {
        guard let output = runProcess("/usr/bin/git", ["-C", path, "status", "--porcelain"]) else {
            return false
        }
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Finishes a task worktree: optionally merges its branch into the main
    // checkout's current branch, then removes worktree + branch. Returns nil
    // on success, an error message otherwise.
    static func finish(worktreePath: String, merge: Bool) -> String? {
        guard isTaskWorktree(worktreePath) else {
            return "\(worktreePath) is not a task worktree."
        }
        guard let root = mainRoot(ofWorktree: worktreePath) else {
            return "Could not find the main checkout for this worktree."
        }
        guard let branch = currentBranch(worktreePath), branch != "HEAD" else {
            return "Could not determine the worktree's branch."
        }
        if merge {
            if hasUncommittedChanges(worktreePath) {
                return "The worktree has uncommitted changes — commit (or discard) them first."
            }
            if case .failure(let error) = runGit(root, ["merge", "--no-ff", branch, "-m", "Merge \(branch)"]) {
                return "Merge failed: \(error.message)"
            }
        }
        var removeArgs = ["worktree", "remove", worktreePath]
        if !merge {
            removeArgs.insert("--force", at: 2)
        }
        if case .failure(let error) = runGit(root, removeArgs) {
            return "Could not remove the worktree: \(error.message)"
        }
        if case .failure(let error) = runGit(root, ["branch", merge ? "-d" : "-D", branch]) {
            return "Worktree removed, but deleting branch \(branch) failed: \(error.message)"
        }
        return nil
    }

    // Cleanup after a *remote* merge (Autopilot's PR flow):
    // the branch already landed via gh, so nothing merges locally — just
    // remove the worktree (--force: the build gate leaves an untracked build/
    // dir that a plain remove refuses; safe post-merge), delete the local
    // branch, and best-effort delete the remote one. Returns nil on success,
    // an error message otherwise.
    static func removeAfterRemoteMerge(worktreePath: String) -> String? {
        guard isTaskWorktree(worktreePath) else {
            return "\(worktreePath) is not a task worktree."
        }
        guard let root = mainRoot(ofWorktree: worktreePath) else {
            return "Could not find the main checkout for this worktree."
        }
        guard let branch = currentBranch(worktreePath), branch != "HEAD" else {
            return "Could not determine the worktree's branch."
        }
        if case .failure(let error) = runGit(root, ["worktree", "remove", "--force", worktreePath]) {
            return "Could not remove the worktree: \(error.message)"
        }
        if case .failure(let error) = runGit(root, ["branch", "-D", branch]) {
            return "Worktree removed, but deleting branch \(branch) failed: \(error.message)"
        }
        // The remote branch may already be gone (gh's auto-delete, a manual
        // cleanup) or there may be no remote at all — not worth surfacing.
        _ = runGit(root, ["push", "origin", "--delete", branch])
        return nil
    }

    // Bring the main checkout up to its already-fetched upstream (Autopilot's
    // preflight and post-merge cleanup — the caller fetches first). Fast-forwards
    // when local main is a strict ancestor of @{u} — the clean, common case.
    // When local main has *diverged* from origin it reconciles with a real merge
    // commit instead of failing: this repo runs a local-first `main` alongside an
    // integrate-main job that lands the same content under different SHAs, so
    // `main` and `origin/main` routinely diverge even though their content
    // converges. The sanctioned resolution here is to merge (never reset/force),
    // which also preserves any genuine local-only commits while still landing the
    // merged HEAD so the next worktree branches from it. Returns nil on success,
    // or an error message when even the merge can't reconcile (real conflicts a
    // human must resolve) — the checkout is left clean in that case.
    static func reconcileMainWithUpstream(_ root: String) -> String? {
        // Already up to date or a clean fast-forward.
        if case .success = runGit(root, ["merge", "--ff-only", "@{u}"]) {
            return nil
        }
        // Diverged: reconcile with a merge commit.
        if case .failure(let error) = runGit(root, ["merge", "--no-edit", "@{u}"]) {
            // Leave the checkout clean if the merge stopped on conflicts.
            _ = runGit(root, ["merge", "--abort"])
            return "the main checkout diverged from its upstream and couldn't be reconciled automatically: \(error.message)"
        }
        return nil
    }

    // git with stderr captured, since every failure path here is worth
    // showing. Internal: the Git tab's branch checkout reuses it.
    static func runGit(_ root: String, _ arguments: [String]) -> Result<String, WorktreeTaskError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root] + arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
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
            .split(separator: "\n").first.map(String.init) ?? "git exited \(process.terminationStatus)"
        return .failure(WorktreeTaskError(message: message.trimmingCharacters(in: .whitespaces)))
    }
}
