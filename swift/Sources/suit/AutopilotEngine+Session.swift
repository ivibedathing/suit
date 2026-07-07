import Darwin
import Foundation

// Autopilot engine — session pinning + prompt delivery (§2.5), the §2.7
// completion-verification checklist, and the nudge/stall handling
// (§2.7/§2.9). Split out of AutopilotEngine.swift.
extension AutopilotEngine {
    // MARK: - Session pinning + prompt delivery (§2.5 inject stage)

    // The statusline writes the session file as soon as the TUI renders, so
    // file-appears ≡ ready-for-input. The session must live in the run's
    // worktree (cwd unique per run) and the assigner's pid-ancestry check
    // confirms it actually runs under the worker tab's shell; the freshness
    // guard keeps a stale file from an earlier run in the same worktree from
    // pinning before the new claude has rendered.
    func tryPinWorkerSession(_ run: AutopilotRun) {
        guard let terminal = workerTerminal() else { return }
        let assigner = ClaudeSessionMonitor.shared.makeAssigner()
        guard let session = assigner.session(forShellPid: terminal.shellPid, cwd: run.worktreePath),
              session.cwd == run.worktreePath,
              let started = attemptStartedAt,
              session.updatedAt >= started - 1 else { return }
        store.updateRun { r in
            r.sessionId = session.id
            if !r.sessionIds.contains(session.id) { r.sessionIds.append(session.id) }
        }
        sessionReadyDeadline = nil
        let prompt: String
        if let pending = pendingFeedbackMessage {
            // Held gate feedback (returnRunToWorking had no live session):
            // `--continue` restored the conversation, so the feedback itself
            // is the resume.
            prompt = pending
        } else if deliverResumePrompt {
            prompt = AutopilotPrompts.resumePrompt(
                phase: run.phaseId, title: run.title, slug: run.slug,
                worktreePath: run.worktreePath
            )
        } else {
            prompt = AutopilotPrompts.workerPrompt(
                phase: run.phaseId, title: run.title, slug: run.slug,
                worktreePath: run.worktreePath, specSnapshot: run.specSnapshot
            )
        }
        pendingFeedbackMessage = nil
        deliverResumePrompt = false
        // 0.5 s submit delay: the multi-KB bracketed paste must be fully
        // consumed before the CR (§2.5).
        SessionControl.send(text: prompt, to: terminal, submit: true, submitDelay: 0.5)
        store.log("worker session \(session.id.prefix(8))… ready — instructions delivered")
        postUpdate()
    }

    // §2.10: keep the max cost/context on the run record, written through
    // only when a value actually grows (didUpdate fires on every statusline
    // render — not worth a state.json rewrite each time).
    func sampleSessionMetrics(_ session: ClaudeSession, run: AutopilotRun) {
        let cost = session.costUSD ?? 0
        let context = session.contextPct ?? 0
        let costGrew = cost > (run.costUSD ?? 0)
        let contextGrew = context > (run.maxContextPct ?? 0)
        guard costGrew || contextGrew else { return }
        store.updateRun { r in
            if costGrew { r.costUSD = cost }
            if contextGrew { r.maxContextPct = context }
        }
    }

    // MARK: - Completion verification (§2.7 — the Stop-hook trap, addressed)

    // What the world-state checklist concluded — computed on a background
    // queue, consumed on main.
    enum VerificationOutcome {
        case complete(prNumber: Int)
        case missing([String])          // the specific unmet required outputs
        case workerBlocked(String)      // the PR body carried Autopilot-Blocked:
    }

    func maybeStartVerification() {
        guard !inFlight else { return }
        if let last = lastVerificationAt,
           Date().timeIntervalSince(last) < Self.verificationInterval { return }
        guard let run = store.run, let root = appDelegate?.autopilotProjectRoot,
              !root.isEmpty else { return }
        lastVerificationAt = Date()
        let job = beginBackgroundJob()
        let gen = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let outcome = AutopilotEngine.runCompletionVerification(root: root, run: run)
            DispatchQueue.main.async {
                guard let self else { return }
                self.endBackgroundJob(job)
                guard gen == self.generation, case .running = self.state,
                      let current = self.store.run, current.id == run.id,
                      AutopilotRunStage(rawValue: current.stage) == .working else { return }
                self.handleVerification(outcome, run: current)
            }
        }
    }

    // The five §2.7 world-state checks. Pure with respect to engine state so
    // it can run on any queue; every step shells out to git/gh and may block.
    static func runCompletionVerification(root: String, run: AutopilotRun) -> VerificationOutcome {
        var missing: [String] = []
        let worktree = run.worktreePath
        let defaultBranch = GitHubCLI.defaultBranch(root: root) ?? "main"

        // 1. Commits ahead of the default branch.
        var aheadCount = 0
        if case .success(let out) = WorktreeTasks.runGit(worktree, ["rev-list", "--count", "origin/\(defaultBranch)..HEAD"]) {
            aheadCount = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        if aheadCount == 0 {
            missing.append("commits on \(run.branch) — the branch has nothing ahead of \(defaultBranch)")
        }

        // 2. Branch pushed: the remote-tracking ref exists and matches HEAD
        // (the worker pushes from inside the shared repo, which updates it).
        var pushed = false
        if case .success(let remote) = WorktreeTasks.runGit(worktree, ["rev-parse", "--verify", "-q", "refs/remotes/origin/\(run.branch)"]),
           case .success(let head) = WorktreeTasks.runGit(worktree, ["rev-parse", "HEAD"]),
           remote.trimmingCharacters(in: .whitespacesAndNewlines) == head.trimmingCharacters(in: .whitespacesAndNewlines),
           !head.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pushed = true
        }
        if !pushed {
            missing.append("git push -u origin \(run.branch) — origin doesn't have the latest commits")
        }

        // 3. An open PR for the branch whose body carries the phase trailer;
        // an Autopilot-Blocked trailer instead means the worker gave up.
        var prNumber: Int?
        if let pr = GitHubCLI.pullRequests(root: root)[run.branch], pr.state == .open {
            switch GitHubCLI.prState(root: root, number: pr.number) {
            case .failure(let error):
                missing.append("a readable PR body — gh pr view #\(pr.number) failed (\(error.message))")
            case .success(let detail):
                if let reason = trailerValue("Autopilot-Blocked", in: detail.body) {
                    return .workerBlocked(reason)
                }
                if trailerValue("Autopilot-Phase", in: detail.body) == String(run.phaseId) {
                    prNumber = pr.number
                } else {
                    missing.append("the PR body must END with exactly \"Autopilot-Phase: \(run.phaseId)\" and \"Autopilot-Slug: \(run.slug)\" — fix it with gh pr edit \(pr.number) --body")
                }
            }
        } else {
            missing.append("an open PR for \(run.branch) — gh pr create per the original instructions")
        }

        // 4. Worktree clean.
        if WorktreeTasks.hasUncommittedChanges(worktree) {
            missing.append("a clean worktree — commit (or remove) the uncommitted changes")
        }

        // 5. The worktree's ROADMAP.md marks this phase shipped.
        var marked = false
        if let roadmap = try? String(contentsOfFile: worktree + "/ROADMAP.md", encoding: .utf8),
           let phase = RoadmapParser.phase(numbered: run.phaseId, in: roadmap) {
            marked = phase.shipped
        }
        if !marked {
            missing.append("ROADMAP.md: append \" — ✅ shipped\" to this phase's heading")
        }

        if missing.isEmpty, let prNumber {
            return .complete(prNumber: prNumber)
        }
        return .missing(missing)
    }

    // "Key: value" trailer lines anywhere in a PR body (workers put them
    // last, but gh/web edits can append content below).
    static func trailerValue(_ key: String, in body: String) -> String? {
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(key + ":") {
                return String(trimmed.dropFirst(key.count + 1))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func handleVerification(_ outcome: VerificationOutcome, run: AutopilotRun) {
        switch outcome {
        case .workerBlocked(let reason):
            block(.workerReportedBlocked,
                  "Phase \(run.phaseId): the worker reported itself blocked — \(reason)",
                  phaseId: run.phaseId)
        case .complete(let prNumber):
            store.updateRun { r in
                r.prNumber = prNumber
                r.stage = AutopilotRunStage.gatingBuild.rawValue
            }
            reviewGateBrokenCount = 0
            mergeConfirmedPending = false
            lastMergePollAt = nil
            store.log("Phase \(run.phaseId) verified complete — PR #\(prNumber) is open; running the gates")
            postUpdate()
        case .missing(let items):
            nudgeWorker(run: run, missing: items)
        }
    }

    // MARK: - Nudges + stall handling (§2.7, §2.9)

    // Nudge the live session with the specific missing items. Each nudge
    // flips the session back to working via the UserPromptSubmit hook, so the
    // done → verify cycle re-arms; ≥2 min apart, max 5 per run → blocked.
    private func nudgeWorker(run: AutopilotRun, missing: [String]) {
        if run.nudgeCount >= Self.maxNudges {
            block(.nudgesExhausted,
                  "Phase \(run.phaseId): still incomplete after \(Self.maxNudges) nudges — missing: \(missing.joined(separator: "; "))",
                  phaseId: run.phaseId)
            return
        }
        // Inside the spacing window: do nothing — the tick's done-state
        // re-verification retries once it elapses.
        if let last = run.lastNudgeAt,
           Date().timeIntervalSince1970 - last < Self.nudgeSpacing { return }
        guard let terminal = workerTerminal() else { return }
        SessionControl.send(
            text: AutopilotPrompts.nudgeMessage(phase: run.phaseId, slug: run.slug, missing: missing),
            to: terminal, submit: true, submitDelay: 0.5
        )
        store.updateRun { r in
            r.nudgeCount += 1
            r.lastNudgeAt = Date().timeIntervalSince1970
        }
        store.log("nudge \(run.nudgeCount + 1)/\(Self.maxNudges) sent — missing: \(missing.joined(separator: " · "))")
    }

    // §2.9: an unattended run has nobody to answer questions — one
    // best-judgment nudge at ~10 min (the attention center already escalates
    // needs-input to the user for free), blocked past stallMinutes.
    func handleStall(run: AutopilotRun, session: ClaudeSession) {
        let since: Date
        if let existing = needsInputSince {
            since = existing
        } else {
            since = Date()
            needsInputSince = since
        }
        let stalled = Date().timeIntervalSince(since)
        let cap = TimeInterval(appDelegate?.autopilotStallMinutes ?? 60) * 60
        if stalled >= cap {
            block(.stalled,
                  "Phase \(run.phaseId): the worker has needed input for \(Int(stalled / 60)) min — answer it in the run tab",
                  phaseId: run.phaseId)
            return
        }
        if stalled >= Self.stallNudgeAfter, !stallNudgeSent, let terminal = workerTerminal() {
            stallNudgeSent = true
            SessionControl.send(text: AutopilotPrompts.stallNudgeMessage,
                                to: terminal, submit: true, submitDelay: 0.5)
            store.log("stall nudge sent — needs-input for \(Int(stalled / 60)) min")
        }
    }
}
