import Darwin
import Foundation

// Autopilot engine — the §2.8 build gate (step 1) and headless review gate
// (step 2). Split out of AutopilotEngine.swift.
extension AutopilotEngine {
    // MARK: - Build gate (§2.8 step 1)

    // Free and first: the worktree's own ./build.sh, streamed to
    // logs/<slug>/build-<attempt>.log with the gate runner's 15-min watchdog.
    // The attempt is bumped up-front so the footer / feedback / log name all
    // agree on its number.
    func maybeStartBuildGate(_ run: AutopilotRun) {
        guard !inFlight, let app = appDelegate else { return }
        let attempt = run.buildAttempts + 1
        let maxAttempts = app.autopilotMaxGateAttempts
        store.updateRun { $0.buildAttempts = attempt }
        let logURL = store.buildLogURL(slug: run.slug, attempt: attempt)
        store.log("build gate: attempt \(attempt)/\(maxAttempts) — running ./build.sh in \(run.worktreePath)")
        let job = beginBackgroundJob()
        let gen = generation
        let handle = AutopilotGateHandle()
        activeGateHandle = handle
        AutopilotBuildGate.run(worktree: run.worktreePath, logPath: logURL.path,
                               handle: handle) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                self.endBackgroundJob(job)
                if self.activeGateHandle === handle { self.activeGateHandle = nil }
                guard let current = self.currentRun(ifGeneration: gen, run: run, stage: .gatingBuild) else { return }
                self.handleBuildGate(outcome, run: current, attempt: attempt,
                                     maxAttempts: maxAttempts, logPath: logURL.path)
            }
        }
        postUpdate()
    }

    private func handleBuildGate(_ outcome: AutopilotGateOutcome, run: AutopilotRun,
                                 attempt: Int, maxAttempts: Int, logPath: String) {
        if outcome.cleanExit {
            store.log("build gate passed (attempt \(attempt)) — running the review gate")
            reviewGateBrokenCount = 0
            store.updateRun { $0.stage = AutopilotRunStage.gatingReview.rawValue }
            postUpdate()
            return
        }
        let failure: String
        var logTail = Self.tailOfLog(atPath: logPath)
        switch outcome {
        case .exited(let status):
            failure = "./build.sh exited \(status)"
        case .timedOut:
            failure = "./build.sh timed out after \(Int(AutopilotBuildGate.timeoutSeconds / 60)) minutes"
            logTail = "(\(failure) and was killed)\n" + logTail
        case .failedToLaunch(let message):
            failure = "./build.sh couldn't launch: \(message)"
            logTail = failure
        }
        store.log("build gate failed (attempt \(attempt)/\(maxAttempts)): \(failure)")
        if attempt >= maxAttempts {
            block(.buildAttemptsExhausted,
                  "Phase \(run.phaseId): \(failure) — attempt \(attempt) of \(maxAttempts); log: \(logPath)",
                  phaseId: run.phaseId)
            return
        }
        returnRunToWorking(run, message: AutopilotPrompts.buildFailureMessage(
            phase: run.phaseId, attempt: attempt, maxAttempts: maxAttempts,
            slug: run.slug, logTail: logTail
        ), logLine: "build-failure feedback sent — back to working")
    }

    // MARK: - Review gate (§2.8 step 2)

    // Headless `claude -p` with the whole context inlined (repo rules + the
    // spec snapshot + the PR diff vs a freshly-fetched origin/<default>), the
    // verdict parsed off the output's final non-blank line. Ambiguity is never
    // an approve: a broken gate retries once, then blocks globally.
    func maybeStartReviewGate(_ run: AutopilotRun) {
        guard !inFlight, let app = appDelegate else { return }
        let attempt = run.reviewAttempts + 1
        let maxAttempts = app.autopilotMaxGateAttempts
        store.updateRun { $0.reviewAttempts = attempt }
        let logURL = store.reviewLogURL(slug: run.slug, attempt: attempt)
        let root = projectRoot
        let model = app.autopilotReviewModel
        store.log("review gate: attempt \(attempt)/\(maxAttempts) — headless claude review of \(run.branch)")
        let job = beginBackgroundJob()
        let gen = generation
        let handle = AutopilotGateHandle()
        activeGateHandle = handle
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Probed here, not on main: the first isAvailable touch can fall
            // back to a login shell (seconds of beachball on the main queue).
            guard AutopilotReviewGate.isAvailable else {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.endBackgroundJob(job)
                    if self.activeGateHandle === handle { self.activeGateHandle = nil }
                    guard let current = self.currentRun(ifGeneration: gen, run: run, stage: .gatingReview) else { return }
                    // A missing binary never consumes a review attempt.
                    self.store.updateRun { $0.reviewAttempts = max(0, $0.reviewAttempts - 1) }
                    self.block(.reviewGateBroken,
                               "The review gate needs the claude CLI, which couldn't be found (set SUIT_CLAUDE_PATH or install claude).",
                               phaseId: nil)
                }
                return
            }
            let defaultBranch = AutopilotEngine.defaultBranchOrMain(root: root)
            // Best-effort: verification already fetched recently; a stale
            // origin ref only makes the diff marginally out of date.
            _ = WorktreeTasks.runGit(run.worktreePath, ["fetch", "origin"])
            let diffResult = WorktreeTasks.runGit(
                run.worktreePath, ["diff", "origin/\(defaultBranch)...HEAD"])
            guard case .success(let diff) = diffResult else {
                var why = "couldn't produce the PR diff vs origin/\(defaultBranch)"
                if case .failure(let error) = diffResult { why += " (\(error.message))" }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.endBackgroundJob(job)
                    if self.activeGateHandle === handle { self.activeGateHandle = nil }
                    guard let current = self.currentRun(ifGeneration: gen, run: run, stage: .gatingReview) else { return }
                    self.reviewGateFailed(run: current, why: why)
                }
                return
            }
            // Token-cost short-circuit: a diff byte-identical to the one the
            // gate last issued a verdict for can only mean the worker pushed
            // nothing real since the rejection (an approve would have moved
            // the run to merging) — skip the headless claude call and send
            // unchanged-diff feedback. Still consumes the attempt, so a
            // worker that never changes anything runs into maxAttempts.
            let diffHash = AutopilotDiffHash.hash(diff)
            if diffHash == run.lastReviewedDiffHash {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.endBackgroundJob(job)
                    if self.activeGateHandle === handle { self.activeGateHandle = nil }
                    guard let current = self.currentRun(ifGeneration: gen, run: run, stage: .gatingReview) else { return }
                    self.handleUnchangedDiff(run: current, attempt: attempt, maxAttempts: maxAttempts)
                }
                return
            }
            // Repo rules from the *main* checkout: a worker that weakened
            // CLAUDE.md must be judged against the original, not its edit.
            let claudeMd = (try? String(contentsOfFile: root + "/CLAUDE.md", encoding: .utf8)) ?? ""
            let prompt = AutopilotPrompts.reviewGatePrompt(
                slug: run.slug, defaultBranch: defaultBranch, claudeMd: claudeMd,
                specSnapshot: run.specSnapshot, diff: diff
            )
            AutopilotReviewGate.run(
                worktree: run.worktreePath, prompt: prompt,
                model: model.isEmpty ? nil : model, logPath: logURL.path,
                handle: handle
            ) { outcome, output in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.endBackgroundJob(job)
                    if self.activeGateHandle === handle { self.activeGateHandle = nil }
                    guard let current = self.currentRun(ifGeneration: gen, run: run, stage: .gatingReview) else { return }
                    self.handleReviewGate(outcome, output: output, run: current,
                                          attempt: attempt, maxAttempts: maxAttempts,
                                          logPath: logURL.path, diffHash: diffHash)
                }
            }
        }
        postUpdate()
    }

    // The unchanged-diff short-circuit's rejection path: same policy as a
    // real rejection (attempt consumed, maxAttempts blocks), minus the API
    // spend and the findings (the previous rejection already carried them).
    private func handleUnchangedDiff(run: AutopilotRun, attempt: Int, maxAttempts: Int) {
        reviewGateBrokenCount = 0
        store.log("review gate skipped (attempt \(attempt)/\(maxAttempts)) — diff unchanged since the last rejection")
        if attempt >= maxAttempts {
            block(.reviewAttemptsExhausted,
                  "Phase \(run.phaseId): the review gate rejected \(attempt) attempts (the last diff was unchanged)",
                  phaseId: run.phaseId)
            return
        }
        returnRunToWorking(run, message: AutopilotPrompts.unchangedDiffMessage(
            phase: run.phaseId, attempt: attempt, maxAttempts: maxAttempts, slug: run.slug
        ), logLine: "unchanged-diff feedback sent — back to working")
    }

    private func handleReviewGate(_ outcome: AutopilotGateOutcome, output: String,
                                  run: AutopilotRun, attempt: Int, maxAttempts: Int,
                                  logPath: String, diffHash: String) {
        switch outcome {
        case .failedToLaunch(let message):
            // No retry can fix a missing/unrunnable binary.
            block(.reviewGateBroken, "The review gate couldn't run claude: \(message)", phaseId: nil)
        case .timedOut:
            reviewGateFailed(run: run, why: "the review timed out after \(Int(AutopilotReviewGate.timeoutSeconds / 60)) minutes")
        case .exited(let status) where status != 0:
            reviewGateFailed(run: run, why: "claude -p exited \(status) — see \(logPath)")
        case .exited:
            guard let verdict = ReviewVerdict.parse(output) else {
                reviewGateFailed(run: run, why: "the output's final line wasn't a VERDICT — see \(logPath)")
                return
            }
            // A verdict was actually issued for this diff — remember its
            // fingerprint so a byte-identical re-review can be skipped.
            store.updateRun { $0.lastReviewedDiffHash = diffHash }
            switch verdict {
            case .approve:
                store.log("review gate approved (attempt \(attempt)) — merging PR #\(run.prNumber ?? 0)")
                reviewGateBrokenCount = 0
                mergeConfirmedPending = false
                lastMergePollAt = nil
                store.updateRun { $0.stage = AutopilotRunStage.merging.rawValue }
                postUpdate()
            case .reject:
                reviewGateBrokenCount = 0
                store.log("review gate rejected (attempt \(attempt)/\(maxAttempts)) — see \(logPath)")
                if attempt >= maxAttempts {
                    block(.reviewAttemptsExhausted,
                          "Phase \(run.phaseId): the review gate rejected \(attempt) attempts — findings in \(logPath)",
                          phaseId: run.phaseId)
                    return
                }
                var findings = Self.findingsText(from: output)
                if findings.isEmpty { findings = "(the review gate returned no findings — re-check the diff against the phase spec)" }
                returnRunToWorking(run, message: AutopilotPrompts.reviewRejectionMessage(
                    phase: run.phaseId, attempt: attempt, maxAttempts: maxAttempts,
                    slug: run.slug, findings: findings
                ), logLine: "review-rejection feedback sent — back to working")
            }
        }
    }

    // §2.8: one gate retry for a broken review (timeout / unparseable / diff
    // failure), then a *global* block — the gate itself is sick, not the
    // phase. The pre-bumped attempt is rolled back so a hiccup never consumes
    // a review attempt.
    private func reviewGateFailed(run: AutopilotRun, why: String) {
        reviewGateBrokenCount += 1
        if reviewGateBrokenCount >= 2 {
            block(.reviewGateBroken, "The review gate failed twice — \(why)", phaseId: nil)
            return
        }
        store.updateRun { $0.reviewAttempts = max(0, $0.reviewAttempts - 1) }
        store.log("review gate hiccup (\(why)) — retrying once")
    }
}
