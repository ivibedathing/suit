import Darwin
import Foundation

// Autopilot engine — the §2.8 merge step (step 3) and post-merge cleanup +
// loop (step 4). Split out of AutopilotEngine.swift.
extension AutopilotEngine {
    // MARK: - Merge (§2.8 step 3)

    func maybeStartMerge(_ run: AutopilotRun) {
        guard !inFlight, let app = appDelegate else { return }
        guard let prNumber = run.prNumber else {
            // Can't happen through the normal paths (verification records the
            // PR before the gates) — surface it rather than wedging.
            block(.other, "Phase \(run.phaseId): the run reached merging without a recorded PR number.",
                  phaseId: run.phaseId)
            return
        }
        if let last = lastMergePollAt,
           Date().timeIntervalSince(last) < Self.gitPollInterval { return }
        lastMergePollAt = Date()
        let root = app.autopilotProjectRoot
        let confirmOnly = mergeConfirmedPending
        if confirmOnly {
            store.log("merge: re-checking PR #\(prNumber) state")
        } else {
            store.log("merging PR #\(prNumber) (gh pr merge --merge)")
        }
        let job = beginBackgroundJob()
        let gen = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var mergeError: String?
            if !confirmOnly, case .failure(let error) = GitHubCLI.mergePR(root: root, number: prNumber) {
                mergeError = error.message
            }
            // Confirm the merge actually landed — a queued/silently-failed
            // merge must not reach cleanup (§2.8).
            var merged = false
            if mergeError == nil,
               case .success(let detail) = GitHubCLI.prState(root: root, number: prNumber) {
                merged = detail.state == .merged
            }
            // The conflict feedback names the branch to merge; resolve it
            // here so the main-queue handler never shells out.
            let defaultBranch = mergeError != nil
                ? (GitHubCLI.defaultBranch(root: root) ?? "main") : "main"
            DispatchQueue.main.async {
                guard let self else { return }
                self.endBackgroundJob(job)
                guard gen == self.generation, case .running = self.state,
                      let current = self.store.run, current.id == run.id,
                      AutopilotRunStage(rawValue: current.stage) == .merging else { return }
                if let mergeError {
                    self.handleMergeFailure(mergeError, run: current,
                                            prNumber: prNumber, defaultBranch: defaultBranch)
                } else if merged {
                    self.mergeConfirmedPending = false
                    self.store.log("PR #\(prNumber) confirmed MERGED — cleaning up")
                    self.store.updateRun { $0.stage = AutopilotRunStage.cleanup.rawValue }
                    self.postUpdate()
                } else {
                    // gh accepted the merge but GitHub hasn't marked the PR
                    // MERGED yet (merge queue / eventual consistency): re-poll
                    // the state on the next paced tick, never re-merge.
                    self.mergeConfirmedPending = true
                    self.store.log("gh pr merge succeeded but PR #\(prNumber) isn't MERGED yet — re-checking")
                }
            }
        }
    }

    private func handleMergeFailure(_ message: String, run: AutopilotRun,
                                    prNumber: Int, defaultBranch: String) {
        let lower = message.lowercased()
        // A retry after a server-side success (the first response got lost)
        // errors "already merged": that's a confirmation to chase, not a
        // failure to count.
        if lower.contains("already merged") {
            mergeConfirmedPending = true
            store.log("PR #\(prNumber) reports already merged — confirming")
            return
        }
        // "Not mergeable": the default branch moved under the PR — conflict
        // feedback into the live session, capped at 2 rounds (§2.8).
        if lower.contains("not mergeable") || lower.contains("conflict") {
            let attempts = run.mergeAttempts + 1
            store.updateRun { $0.mergeAttempts = attempts }
            if attempts > Self.mergeConflictCap {
                block(.mergeAttemptsExhausted,
                      "Phase \(run.phaseId): PR #\(prNumber) still isn't mergeable after \(attempts) tries — \(message)",
                      phaseId: run.phaseId)
                return
            }
            store.log("PR #\(prNumber) not mergeable (\(message)) — conflict feedback \(attempts)/\(Self.mergeConflictCap)")
            returnRunToWorking(run, message: AutopilotPrompts.mergeConflictMessage(
                phase: run.phaseId, slug: run.slug, defaultBranch: defaultBranch
            ), logLine: "merge-conflict feedback sent — back to working")
            return
        }
        // Branch protection / required reviews: no amount of retrying or
        // worker feedback fixes repo policy — a human reconfigures it (§2.8).
        if lower.contains("protect") || lower.contains("required") || lower.contains("policy") {
            block(.branchProtection,
                  "gh pr merge #\(prNumber) was refused by branch protection: \(message)",
                  phaseId: nil)
            return
        }
        // Anything else (auth blip, network, API hiccup): retry on the merge
        // poll pace, with the same small cap so a persistent failure blocks.
        let attempts = run.mergeAttempts + 1
        store.updateRun { $0.mergeAttempts = attempts }
        if attempts > Self.mergeConflictCap {
            block(.mergeAttemptsExhausted,
                  "Phase \(run.phaseId): gh pr merge #\(prNumber) kept failing — \(message)",
                  phaseId: run.phaseId)
            return
        }
        store.log("gh pr merge #\(prNumber) failed (\(message)) — retrying (\(attempts)/\(Self.mergeConflictCap))")
    }

    // MARK: - Cleanup + the loop (§2.8 step 4)

    func maybeStartCleanup(_ run: AutopilotRun) {
        guard !inFlight, let app = appDelegate else { return }
        let root = app.autopilotProjectRoot
        store.log("cleanup: syncing the main checkout and removing the task worktree")
        let job = beginBackgroundJob()
        let gen = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Main checkout catches up to the merged HEAD first, so the next
            // phase's worktree branches from it. A diverged local main (this
            // repo's local-first main vs the integrate-main job) is reconciled
            // with a merge rather than wedging on a rigid fast-forward.
            var divergedMessage: String?
            if case .failure(let error) = WorktreeTasks.runGit(root, ["fetch", "origin"]) {
                divergedMessage = "post-merge git fetch origin failed: \(error.message)"
            } else {
                divergedMessage = WorktreeTasks.reconcileMainWithUpstream(root)
            }
            var removalWarning: String?
            if divergedMessage == nil {
                if FileManager.default.fileExists(atPath: run.worktreePath) {
                    removalWarning = WorktreeTasks.removeAfterRemoteMerge(worktreePath: run.worktreePath)
                } else {
                    // Worktree already gone (manual cleanup): best-effort
                    // branch deletes only.
                    _ = WorktreeTasks.runGit(root, ["branch", "-D", run.branch])
                    _ = WorktreeTasks.runGit(root, ["push", "origin", "--delete", run.branch])
                }
            }
            // For the history row's pr_url; optional, so failures are fine.
            let prURL = GitHubCLI.pullRequests(root: root)[run.branch]?.url
            DispatchQueue.main.async {
                guard let self else { return }
                self.endBackgroundJob(job)
                guard gen == self.generation, case .running = self.state,
                      let current = self.store.run, current.id == run.id,
                      AutopilotRunStage(rawValue: current.stage) == .cleanup else { return }
                if let divergedMessage {
                    self.block(.mainDiverged, divergedMessage, phaseId: nil)
                    return
                }
                if let removalWarning {
                    // Not fatal: the next preflight auto-cleans a merged-and-
                    // clean leftover (§2.3 step 8) — log it and keep looping.
                    self.store.log("cleanup warning: \(removalWarning)")
                }
                self.finishMergedRun(current, prURL: prURL)
            }
        }
    }

    // History row + notification + tab close + clear → idle: the loop
    // continues (the next tick's preflight re-pulls main, so the next phase
    // branches from the merged HEAD).
    private func finishMergedRun(_ run: AutopilotRun, prURL: String?) {
        let attempts = max(run.buildAttempts, run.reviewAttempts, 1)
        store.appendHistory(CompletedRun(
            runId: run.id, phase: run.phaseId, title: run.title, slug: run.slug,
            branch: run.branch, startedAt: run.startedAt,
            endedAt: Date().timeIntervalSince1970, attempts: attempts,
            outcome: .merged, prURL: prURL, costUSD: run.costUSD,
            maxContextPct: run.maxContextPct, sessionIds: run.sessionIds,
            blockedReason: nil
        ))
        var body = "PR #\(run.prNumber ?? 0) · \(attempts) attempt\(attempts == 1 ? "" : "s")"
        if let cost = run.costUSD { body += String(format: " · $%.2f", cost) }
        appDelegate?.postAutopilotNotification(
            title: "Phase \(run.phaseId) merged — \(run.title)",
            body: body, identifier: "autopilot-merged"
        )
        // Fleet activity feed: a merged run is feed-worthy.
        appDelegate?.recordAutopilotMerged(
            runId: run.id, phaseId: run.phaseId, title: run.title,
            repo: FleetModel.projectAndWorktree(cwd: run.worktreePath).project,
            prNumber: run.prNumber, prURL: prURL
        )
        store.log("Phase \(run.phaseId) merged — PR #\(run.prNumber ?? 0)\(prURL.map { " (\($0))" } ?? "")")
        closeWorkerTab()
        store.setRun(nil)
        resetRunMemory()
        // Don't wait out the poll throttle — budget willing, the next phase
        // starts on the next tick.
        lastPreflightAt = nil
        setState(.idle)
    }
}
