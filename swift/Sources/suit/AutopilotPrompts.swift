import Foundation

// Prompt composition for Autopilot: the worker prompt typed
// into a run's interactive claude session, the headless review-gate prompt,
// and the feedback messages sent back into the live session (nudge / resume /
// build failure / review rejection / merge conflict). Pure string composition
// — no UI, no engine state — so it compiles standalone for the scratch logic
// tests.
enum AutopilotPrompts {

    // MARK: - Worker prompt

    // Placeholders substituted into the worker template (and honored in a user
    // override at ~/.suit/autopilot-prompt.md): <N> phase number, <TITLE>,
    // <SLUG>, <WORKTREE_PATH>, <SPEC> (the verbatim phase heading + body
    // snapshotted at spawn). Other angle-bracket text (<body>, <short summary>,
    // <one-line reason>) is instructions to the worker and passes through.
    static let defaultWorkerTemplate = """
    You are an Autopilot worker session run by the Suit app, working unattended.
    You are in a dedicated git worktree at <WORKTREE_PATH> on branch task/<SLUG>.
    Everything you do happens ONLY inside this worktree.

    YOUR JOB
    Implement ROADMAP.md "Phase <N> — <TITLE>" end-to-end, exactly per the spec
    below (snapshotted when this run started — treat it as the contract even if
    ROADMAP.md changes underneath you).

    --- PHASE SPEC (verbatim from ROADMAP.md) ---
    <SPEC>
    --- END PHASE SPEC ---

    First read AGENTS.md and follow every convention in it (plain swiftc via
    ./build.sh, no SwiftPM/Xcode, vendor any dependency as source, document
    shipped features in docs/features.md).

    REQUIRED OUTPUTS — all of them, in order:
    1. The implementation, including the spec's Verification item.
    2. ./build.sh exits 0 (run it from the worktree root; confirm the exit code).
    3. docs/features.md updated to document the new user-facing behavior
       (features, shortcuts, settings) in the matching section. Touch README.md
       ONLY if the change belongs in its Highlights summary or shortcuts table;
       it is kept lean by design.
    4. ROADMAP.md: append " — ✅ shipped" to THIS phase's heading only (add a short
       parenthetical if something deliberately deviated). Touch no other phase.
    5. Commit everything on this branch. Subject of the final commit:
       "Phase <N>: <short summary>". The tree must be clean afterwards.
    6. git push -u origin task/<SLUG>
    7. gh pr create --title "Phase <N>: <TITLE>" --body "<body>" where the body
       starts with what shipped and how you verified it, and ENDS with exactly
       these two lines:
       Autopilot-Phase: <N>
       Autopilot-Slug: <SLUG>

    IF THE PHASE IS ALREADY IMPLEMENTED (roadmap drift)
    Verify it genuinely works (run its Verification item and ./build.sh). Then do
    outputs 3–7 anyway as a docs-only change: mark the heading "— ✅ shipped
    (docs-only: implementation predated this run)", fill any docs/features.md
    gap, commit, push, open the PR with the same trailer lines. Never
    re-implement working code.

    HARD RULES
    - Never merge a PR; never run "gh pr merge"; never push to main/master.
    - Never modify files outside <WORKTREE_PATH>; never cd out of it to run
      write-operations; never touch the main checkout or other worktrees.
    - Never edit any other phase's text in ROADMAP.md; never reorder phases.
    - Never force-push or rewrite already-pushed history.
    - If genuinely blocked (contradictory spec, missing external dependency),
      commit what exists, push, and open the PR with the body's final line
      "Autopilot-Blocked: <one-line reason>" INSTEAD of the Autopilot-Phase line,
      then stop.

    WHEN THE PR EXISTS
    Print exactly this line and stop:
    AUTOPILOT DONE PHASE <N>
    Suit itself builds, reviews, and merges — that is not your job.
    """

    // The template actually used: ~/.suit/autopilot-prompt.md when present and
    // non-empty (HOME resolved from the environment so tests/harnesses can
    // sandbox it, same reasoning as FavoritesStore), else the built-in default.
    static func workerTemplate() -> String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let overridePath = home + "/.suit/autopilot-prompt.md"
        if let override = try? String(contentsOfFile: overridePath, encoding: .utf8),
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return override
        }
        return defaultWorkerTemplate
    }

    // The full instruction block SessionControl pastes into a fresh worker
    // session once its session file appears (§2.5 two-stage delivery).
    static func workerPrompt(phase: Int, title: String, slug: String,
                             worktreePath: String, specSnapshot: String) -> String {
        substitute(workerTemplate(), phase: phase, title: title, slug: slug,
                   worktreePath: worktreePath, spec: specSnapshot)
    }

    // MARK: - Resume prompt (relaunch adoption / one-shot respawn with --continue)

    static func resumePrompt(phase: Int, title: String, slug: String,
                             worktreePath: String) -> String {
        """
        AUTOPILOT RESUME — you are an Autopilot worker session restarted with
        --continue after the previous claude process ended mid-run. You are still
        in the dedicated git worktree at \(worktreePath) on branch task/\(slug),
        implementing ROADMAP.md "Phase \(phase) — \(title)".
        Take stock of what already happened (commits on this branch, whether it
        was pushed, whether the PR exists), then finish the remaining REQUIRED
        OUTPUTS from the original instructions: the implementation including the
        spec's Verification item, ./build.sh exits 0, docs/features.md updated,
        this phase's heading marked "— ✅ shipped", everything committed, pushed to
        origin task/\(slug), and a PR whose body ENDS with exactly these two lines:
        Autopilot-Phase: \(phase)
        Autopilot-Slug: \(slug)
        All HARD RULES from the original instructions still apply (never merge,
        never leave the worktree, never touch other phases). When the PR exists,
        print exactly this line and stop:
        AUTOPILOT DONE PHASE \(phase)
        """
    }

    // MARK: - Nudges (§2.7 completion verification misses; §2.9 stall)

    // Sent when the session went `done` but world-state verification found
    // specific required outputs still missing.
    static func nudgeMessage(phase: Int, slug: String, missing: [String]) -> String {
        let items = missing.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        return """
        AUTOPILOT CHECK — Phase \(phase) is not finished yet. These required
        outputs are still missing:
        \(items)
        Complete them per the original instructions (same worktree, same branch
        task/\(slug)), then print AUTOPILOT DONE PHASE \(phase) again.
        """
    }

    // Sent once (~10 min into a needs-input stall) before the stall clock can
    // block the phase — an unattended run has nobody to answer questions.
    static let stallNudgeMessage =
        "AUTOPILOT: this is an unattended run — proceed with your best judgment"

    // MARK: - Gate feedback (§2.8)

    // Build gate failure: the log tail rides along fenced so bracketed paste
    // keeps it one input-box unit.
    static func buildFailureMessage(phase: Int, attempt: Int, maxAttempts: Int,
                                    slug: String, logTail: String) -> String {
        """
        AUTOPILOT BUILD GATE — Phase \(phase) attempt \(attempt) of \(maxAttempts): ./build.sh failed.
        Fix the build in this same worktree, keep every requirement from the
        original instructions (build.sh green, docs/features.md, the ✅ heading
        mark), commit, and push to the same branch task/\(slug); the existing PR
        updates itself.
        When pushed, print AUTOPILOT DONE PHASE \(phase) again.

        ```
        \(logTail)
        ```
        """
    }

    // Review gate rejection: the gate's numbered findings verbatim.
    static func reviewRejectionMessage(phase: Int, attempt: Int, maxAttempts: Int,
                                       slug: String, findings: String) -> String {
        """
        AUTOPILOT REVIEW — Phase \(phase) attempt \(attempt) of \(maxAttempts) was rejected.
        Fix the findings below in this same worktree, keep every requirement from the
        original instructions (build.sh green, docs/features.md, the ✅ heading
        mark), commit, and push to the same branch task/\(slug); the existing PR
        updates itself.
        When pushed, print AUTOPILOT DONE PHASE \(phase) again.

        \(findings)
        """
    }

    // Review gate short-circuit: the diff is byte-identical to the one the
    // gate already rejected, so no new review ran (the verdict couldn't
    // change — only tokens would burn). Counts as a rejected attempt.
    static func unchangedDiffMessage(phase: Int, attempt: Int, maxAttempts: Int,
                                     slug: String) -> String {
        """
        AUTOPILOT REVIEW — Phase \(phase) attempt \(attempt) of \(maxAttempts): the branch's diff
        is byte-identical to the one the review gate already rejected, so the
        review was not re-run. Nothing you pushed changed the PR. Actually
        address the findings from the previous rejection (they were sent in the
        earlier AUTOPILOT REVIEW message; the full review output is under
        logs/\(slug)/ in ~/.suit/autopilot/), commit real changes, and push to
        the same branch task/\(slug).
        When pushed, print AUTOPILOT DONE PHASE \(phase) again.
        """
    }

    // Merge stage "not mergeable" (§2.9 conflict feedback): the default branch
    // moved under the PR.
    static func mergeConflictMessage(phase: Int, slug: String,
                                     defaultBranch: String) -> String {
        """
        AUTOPILOT MERGE CONFLICT — Phase \(phase): the PR is no longer mergeable
        because \(defaultBranch) moved. In this same worktree run
        git fetch origin && git merge origin/\(defaultBranch), resolve every
        conflict (keeping every requirement from the original instructions
        intact), commit the merge, and push to the same branch task/\(slug);
        the existing PR updates itself.
        When pushed, print AUTOPILOT DONE PHASE \(phase) again.
        """
    }

    // MARK: - Review gate prompt (§2.8; fed to headless `claude -p` on stdin)

    // Context is inlined so the reviewer needs no tools: repo rules capped at
    // 40 KB, the spec snapshot, and the PR diff capped at ~150 KB with an
    // explicit truncation header so the gate knows it judged a prefix.
    private static let repoRulesByteCap = 40 * 1024
    private static let diffByteCap = 150 * 1024
    static let diffTruncationHeader = "[diff truncated at 150KB]"
    static let repoRulesTruncationHeader = "[AGENTS.md truncated at 40KB]"

    static func reviewGatePrompt(slug: String, defaultBranch: String,
                                 repoRules: String, specSnapshot: String,
                                 diff: String) -> String {
        let (clippedRules, rulesTruncated) = clip(repoRules, toBytes: repoRulesByteCap)
        let rulesSection = rulesTruncated
            ? clippedRules + "\n" + repoRulesTruncationHeader : repoRules
        let (clippedDiff, diffTruncated) = clip(diff, toBytes: diffByteCap)
        let diffSection = diffTruncated
            ? diffTruncationHeader + "\n" + clippedDiff : diff
        return """
        You are the Autopilot review gate for the Suit repository. Below are the repo
        rules, the roadmap phase spec that was supposed to be implemented, and the full
        PR diff (branch task/\(slug) vs \(defaultBranch)). Decide whether this PR
        correctly and completely implements the phase. You are the only reviewer;
        be strict but not pedantic — style nits are not rejection grounds.

        APPROVE only if ALL hold:
        1. The diff implements the phase spec, including its Verification item.
        2. docs/features.md documents the shipped user-facing behavior. (README.md
           is kept lean on purpose — it is only expected to change when the phase
           belongs in its Highlights summary or shortcuts table.)
        3. ROADMAP.md marks exactly this one phase "✅ shipped" and no other phase's
           text changed.
        4. No out-of-scope changes: no unrelated refactors, no edits weakening
           AGENTS.md, no SwiftPM/Xcode reintroduction, no build.sh regressions.
        5. Nothing destructive or unsafe: no deletions outside the feature's scope,
           no secrets, no network calls the spec didn't ask for.
        (A docs-only diff is correct when the phase was already implemented — judge it
        against rules 2, 3, 4, 5 only.)

        OUTPUT FORMAT — exactly this, nothing after it:
        - Numbered findings, most important first, max 8. Each: "N. <file>:<line or
          area> — <what is wrong and what to change>". If approving, findings may be
          empty or advisory.
        - Then, alone on the FINAL line, exactly one of:
        VERDICT: APPROVE
        VERDICT: REJECT

        === REPO RULES (AGENTS.md) ===
        \(rulesSection)
        === PHASE SPEC (snapshot) ===
        \(specSnapshot)
        === DIFF ===
        \(diffSection)
        """
    }

    // MARK: - Helpers

    private static func substitute(_ template: String, phase: Int, title: String,
                                   slug: String, worktreePath: String,
                                   spec: String) -> String {
        // <SPEC> goes last so placeholder-shaped text inside the snapshotted
        // ROADMAP body is never re-substituted.
        template
            .replacingOccurrences(of: "<WORKTREE_PATH>", with: worktreePath)
            .replacingOccurrences(of: "<SLUG>", with: slug)
            .replacingOccurrences(of: "<TITLE>", with: title)
            .replacingOccurrences(of: "<N>", with: String(phase))
            .replacingOccurrences(of: "<SPEC>", with: spec)
    }

    // Byte-capped prefix, backed off to a UTF-8 sequence boundary so the cut
    // never splits a character.
    private static func clip(_ text: String, toBytes cap: Int) -> (text: String, truncated: Bool) {
        let bytes = Array(text.utf8)
        guard bytes.count > cap else { return (text, false) }
        var end = cap
        while end > 0 && (bytes[end] & 0xC0) == 0x80 { end -= 1 }
        return (String(decoding: bytes[0..<end], as: UTF8.self), true)
    }
}
