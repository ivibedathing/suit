import Darwin
import Foundation

// Autopilot engine — the §2.3 preflight checklist, the §2.5 spawn stage, and
// the §2.2 relaunch-adoption truth table. Split out of AutopilotEngine.swift.
extension AutopilotEngine {
    // MARK: - Preflight (§2.3; blocking git/gh work on a background queue)

    func startPreflightIfDue(force: Bool) {
        guard !inFlight else { return }
        if !force, let last = lastPreflightAt,
           Date().timeIntervalSince(last) < Self.gitPollInterval { return }
        lastPreflightAt = Date()
        budgetBypassOnce = false
        let job = beginBackgroundJob()
        let gen = generation
        let root = appDelegate?.autopilotProjectRoot ?? ""
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = AutopilotEngine.runPreflight(root: root)
            DispatchQueue.main.async {
                guard let self else { return }
                self.endBackgroundJob(job)
                // Stale: the state moved on (disabled, paused, …) while the
                // git/gh work ran.
                guard gen == self.generation, case .idle = self.state else { return }
                self.handlePreflight(result)
            }
        }
    }

    private func handlePreflight(_ result: AutopilotPreflightResult) {
        switch result {
        case .doneAllPhases:
            store.log("preflight: every ROADMAP.md phase is shipped or skipped — idle until the roadmap changes")
            roadmapMtimeAtDone = roadmapModificationDate() ?? Date()
            lastRoadmapCheckAt = nil
            // §2.11: once per transition — handlePreflight only runs from
            // `idle`, so entering doneAllPhases is exactly that transition.
            appDelegate?.postAutopilotNotification(
                title: "Autopilot idle — no unshipped phases",
                body: "Every ROADMAP.md phase is ✅ shipped or ⏸ skipped. Editing the roadmap re-arms Autopilot.",
                identifier: "autopilot-idle"
            )
            setState(.doneAllPhases)
        case .blocked(let reason, let message):
            block(reason, message, phaseId: nil)
        case .ready(let phase):
            store.log("preflight passed for Phase \(phase.number) — \(phase.title)")
            spawnRun(for: phase)
        }
    }

    // MARK: - Spawn (§2.5 launch stage)

    // Worktree creation on a background queue (git worktree add checks out a
    // full tree — too slow for main), then run record + tab on main.
    private func spawnRun(for phase: RoadmapPhase) {
        guard !inFlight, let app = appDelegate else { return }
        let root = app.autopilotProjectRoot
        let job = beginBackgroundJob()
        // §2.9: the sleep hold spans spawning…cleanup. Spawning happens while
        // the state is still `idle`, so it's taken explicitly here;
        // updateSleepHold (run on every state transition) keeps it through
        // `running` and releases it anywhere else.
        beginSleepHoldForSpawn()
        let gen = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // createTask re-slugs the name it is given; RoadmapPhase.slug is a
            // fixed point of that function, so worktree/branch match the run.
            let result = WorktreeTasks.createTask(projectRoot: root, name: phase.slug)
            DispatchQueue.main.async {
                guard let self else { return }
                self.endBackgroundJob(job)
                guard gen == self.generation, case .idle = self.state else { return }
                switch result {
                case .failure(let error):
                    self.block(.spawnFailed,
                               "Couldn't create the task worktree for “\(phase.slug)”: \(error.message)",
                               phaseId: phase.number)
                case .success(let directory):
                    self.startRun(phase: phase, worktreePath: directory)
                }
            }
        }
    }

    private func startRun(phase: RoadmapPhase, worktreePath: String) {
        // The spec snapshot makes the run immune to concurrent ROADMAP.md
        // edits — worker and review gate judge against the same artifact.
        let run = AutopilotRun(
            phaseId: phase.number, title: phase.title, slug: phase.slug,
            branch: phase.branch, worktreePath: worktreePath,
            stage: AutopilotRunStage.working.rawValue,
            startedAt: Date().timeIntervalSince1970,
            specSnapshot: phase.specText
        )
        store.setRun(run)
        respawnCount = 0
        reviewGateBrokenCount = 0
        mergeConfirmedPending = false
        lastMergePollAt = nil
        guard openWorkerTab(run: run, continueSession: false) else {
            // Nothing real happened yet: drop the run record; the fresh
            // worktree is fully merged + clean, so the next preflight
            // auto-cleans it.
            store.setRun(nil)
            block(.spawnFailed, "No window is available to host the run tab.", phaseId: phase.number)
            return
        }
        store.log("run started: Phase \(phase.number) — \(phase.title) in \(worktreePath)")
        setState(.running)
    }

    // Opens the worker tab (fresh spawn, or the --continue respawn) and arms
    // the §2.5 session-ready watch. Returns false when no window exists.
    func openWorkerTab(run: AutopilotRun, continueSession: Bool) -> Bool {
        guard let tab = appDelegate?.openAutopilotRunTab(
            directory: run.worktreePath,
            title: "⚙ Phase \(run.phaseId) — \(run.title)",
            continueSession: continueSession
        ) else { return false }
        workerTabId = tab.id
        deliverResumePrompt = continueSession
        sessionReadyDeadline = Date().addingTimeInterval(Self.sessionReadyTimeout)
        attemptStartedAt = Date()
        needsInputSince = nil
        stallNudgeSent = false
        lastVerificationAt = nil
        return true
    }

    // The full ordered §2.3 checklist. Pure with respect to engine state so it
    // can run on any queue; every step shells out to git/gh and may block.
    static func runPreflight(root: String) -> AutopilotPreflightResult {
        // 1. Project configured + a git repo.
        guard !root.isEmpty else {
            return .blocked(.noProject, "No Autopilot project is configured — choose one in Settings ▸ Autopilot.")
        }
        guard FileIndex.gitRoot(of: root) != nil else {
            return .blocked(.noProject, "\(root) is not a git repository.")
        }
        // 2. ROADMAP.md exists and still has an eligible phase.
        guard let roadmap = try? String(contentsOfFile: root + "/ROADMAP.md", encoding: .utf8) else {
            return .blocked(.noProject, "ROADMAP.md not found in \(root).")
        }
        guard let phase = RoadmapParser.eligiblePhase(in: roadmap) else {
            return .doneAllPhases
        }
        // 3. gh installed.
        guard GitHubCLI.isAvailable else {
            return .blocked(.ghMissing, "Install the gh CLI — brew install gh, then gh auth login.")
        }
        // 4. gh authenticated.
        guard GitHubCLI.isAuthenticated(root: root) else {
            return .blocked(.ghUnauthenticated, "gh isn't authenticated — run gh auth login.")
        }
        // 5. Main checkout on the default branch (createTask branches from its HEAD).
        guard let defaultBranch = GitHubCLI.defaultBranch(root: root) else {
            return .blocked(.mainNotOnDefault, "Couldn't resolve the repo's default branch.")
        }
        let current = WorktreeTasks.currentBranch(root)
        guard current == defaultBranch else {
            return .blocked(.mainNotOnDefault, "The main checkout is on “\(current ?? "?")”, not “\(defaultBranch)” — a new task worktree would branch from the wrong HEAD.")
        }
        // 6. Main checkout clean.
        guard !WorktreeTasks.hasUncommittedChanges(root) else {
            return .blocked(.mainDirty, "The main checkout has uncommitted changes — commit or stash them.")
        }
        // 7. Up to date with origin. A diverged local main is reconciled with a
        // merge (this repo's local-first main vs the integrate-main job land the
        // same content under different SHAs); only genuine conflicts block.
        if case .failure(let error) = WorktreeTasks.runGit(root, ["fetch", "origin"]) {
            return .blocked(.offline, "git fetch origin failed: \(error.message)")
        }
        if let error = WorktreeTasks.reconcileMainWithUpstream(root) {
            return .blocked(.mainDiverged, "Couldn't bring the main checkout up to origin/\(defaultBranch): \(error)")
        }
        // 8. No leftover worktree/branch for this phase's slug. Auto-clean only
        // when the branch is fully merged into origin's default and the
        // worktree is clean — anything else may hold unshipped work, and a
        // human decides.
        let slug = phase.slug
        let branch = phase.branch
        let worktreePath = root + "/" + WorktreeTasks.worktreesSubpath + "/" + slug
        let worktreeExists = FileManager.default.fileExists(atPath: worktreePath)
        var branchExists = false
        if case .success = WorktreeTasks.runGit(root, ["rev-parse", "--verify", "-q", "refs/heads/\(branch)"]) {
            branchExists = true
        }
        if worktreeExists || branchExists {
            var mergedIntoDefault = true
            if branchExists {
                mergedIntoDefault = false
                if case .success = WorktreeTasks.runGit(root, ["merge-base", "--is-ancestor", branch, "origin/\(defaultBranch)"]) {
                    mergedIntoDefault = true
                }
            }
            let worktreeClean = !worktreeExists || !WorktreeTasks.hasUncommittedChanges(worktreePath)
            guard mergedIntoDefault, worktreeClean else {
                return .blocked(.leftoverWorktree, "A leftover worktree/branch for “\(slug)” has unmerged or uncommitted work — merge or remove it manually.")
            }
            if worktreeExists {
                if let error = WorktreeTasks.removeAfterRemoteMerge(worktreePath: worktreePath) {
                    return .blocked(.leftoverWorktree, "Couldn't clean up the leftover worktree for “\(slug)”: \(error)")
                }
            } else if case .failure(let error) = WorktreeTasks.runGit(root, ["branch", "-D", branch]) {
                return .blocked(.leftoverWorktree, "Couldn't delete the leftover branch \(branch): \(error.message)")
            }
        }
        return .ready(phase)
    }

    // MARK: - Relaunch adoption (§2.2)

    // §2.2's adoption truth table, factored pure so it's truth-table
    // testable: where a persisted run resumes, given whether its worktree
    // still exists and what GitHub says about its PR. nil = nothing real
    // happened (no PR, no worktree) — the run is cleared. The
    // "was merging && OPEN → retry merge" refinement is the caller's (it
    // needs the persisted stage).
    static func adoptionStage(worktreeExists: Bool, prState: GitPRInfo.State?) -> AutopilotRunStage? {
        switch prState {
        case .merged:
            // The PR landed; only the post-merge cleanup can still be owed.
            return .cleanup
        case .open:
            // Gates are idempotent — re-run both against the open PR.
            return .gatingBuild
        case .closed, .none:
            // A closed-unmerged PR counts as no PR: finishing the work and
            // (re-)opening one is the working stage's job. No worktree
            // either → nothing real happened.
            return worktreeExists ? .working : nil
        }
    }

    // The one path back into a persisted run: relaunch (adoptOnLaunch),
    // Resume after a pause, Retry after a block, and re-enabling the setting
    // all land here. Resolves world state on a background queue, then
    // finishAdoption lands the run at its true stage.
    func adoptPersistedRun(context: String) {
        guard let app = appDelegate, let run = store.run else {
            setState(.idle)
            return
        }
        let root = app.autopilotProjectRoot
        guard !root.isEmpty else {
            block(.noProject, "No Autopilot project is configured — choose one in Settings ▸ Autopilot.", phaseId: nil)
            return
        }
        store.log("\(context): adopting the persisted Phase \(run.phaseId) run (stage \(run.stage))")
        setState(.running)
        adopting = true
        let job = beginBackgroundJob()
        let gen = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // §2.2: without gh the PR's state is unknowable — blocked(.ghMissing),
            // run kept; Retry adopts it once gh is installed. Probed here, not
            // on main: the first isAvailable touch can fall back to a login
            // shell, and adoption runs inside applicationDidFinishLaunching.
            guard GitHubCLI.isAvailable else {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.endBackgroundJob(job)
                    self.adopting = false
                    guard gen == self.generation, case .running = self.state else { return }
                    self.block(.ghMissing,
                               "Install the gh CLI — brew install gh, then gh auth login. The persisted Phase \(run.phaseId) run is kept and resumes once gh is available.",
                               phaseId: nil)
                }
                return
            }
            // The PR's state on GitHub: by number when the run recorded one
            // (gh pr view sees merged/closed PRs and distinguishes "couldn't
            // reach GitHub" from "no PR"), else by branch from the all-state
            // PR list (nil there genuinely means no PR ever got opened).
            var prState: GitPRInfo.State?
            var prNumber = run.prNumber
            var lookupError: String?
            if let number = run.prNumber {
                switch GitHubCLI.prState(root: root, number: number) {
                case .success(let detail): prState = detail.state
                case .failure(let error): lookupError = "couldn't read PR #\(number) (\(error.message))"
                }
            } else if let pr = GitHubCLI.pullRequests(root: root)[run.branch] {
                prState = pr.state
                prNumber = pr.number
            }
            let worktreeExists = FileManager.default.fileExists(atPath: run.worktreePath)
            DispatchQueue.main.async {
                guard let self else { return }
                self.endBackgroundJob(job)
                self.adopting = false
                guard gen == self.generation, case .running = self.state,
                      let current = self.store.run, current.id == run.id else { return }
                if let lookupError {
                    self.block(.offline, "Adoption couldn't reach GitHub — \(lookupError). Retry once you're online.", phaseId: nil)
                    return
                }
                self.finishAdoption(run: current, worktreeExists: worktreeExists,
                                    prState: prState, prNumber: prNumber)
            }
        }
    }

    private func finishAdoption(run: AutopilotRun, worktreeExists: Bool,
                                prState: GitPRInfo.State?, prNumber: Int?) {
        guard let stage = Self.adoptionStage(worktreeExists: worktreeExists, prState: prState) else {
            // §2.2: no PR and no worktree — nothing real happened; clear the
            // run and let the next preflight start the phase over.
            store.log("adoption: no PR and no worktree for \(run.branch) — clearing the run")
            store.setRun(nil)
            resetRunMemory()
            lastPreflightAt = nil
            setState(.idle)
            return
        }
        // §2.2: a run that was mid-merge and whose PR is still OPEN retries
        // the merge (idempotent) instead of re-running the gates.
        var target = stage
        if target == .gatingBuild, AutopilotRunStage(rawValue: run.stage) == .merging {
            target = .merging
        }
        resetRunMemory()
        store.updateRun { r in
            r.stage = target.rawValue
            if r.prNumber == nil { r.prNumber = prNumber }
            // Un-pin the dead session so the session-ready watch re-arms;
            // the old id stays in sessionIds for the history row.
            if target == .working { r.sessionId = nil }
        }
        if target == .working {
            // §2.2 respawn: `claude --dangerously-skip-permissions --continue`
            // + the resume prompt, delivered on session-ready like a fresh
            // spawn.
            guard let current = store.run, openWorkerTab(run: current, continueSession: true) else {
                block(.workerDied,
                      "Phase \(run.phaseId): no window could host the adopted run's tab",
                      phaseId: run.phaseId)
                return
            }
            store.log("adoption: Phase \(run.phaseId) resumes at working — respawned claude --continue")
        } else {
            store.log("adoption: Phase \(run.phaseId) resumes at stage \(target.rawValue)")
        }
        postUpdate()
    }
}
