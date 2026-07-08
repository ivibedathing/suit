---
description: Claim the next unclaimed ROADMAP.md phase, then start it in a worktree
argument-hint: "[phase number or title, optional]"
---

Follow the repo's phase workflow (CLAUDE.md "Workflow") to claim and begin a
ROADMAP.md phase.

1. Read the `### Phase N — …` headings in `ROADMAP.md`. Skip any already marked
   `🚧` (claimed), `✅` (shipped), or `⏸` (skipped).
2. Pick the phase: if `$ARGUMENTS` names one, use it (confirm it's unclaimed);
   otherwise take the first phase in document order with none of those markers.
3. On the **main checkout** (not a worktree), append
   ` 🚧 in progress (<branch>, <today's date>)` to that phase's heading and
   commit just that one-line change to main. Use the branch name you'll create
   next (`worktree-phase-<N>-<slug>` or similar).
4. Create the worktree/branch for the phase and switch into it (EnterWorktree,
   since CLAUDE.md mandates a worktree per task).
5. Report which phase you claimed and the branch/worktree, then begin
   implementing. Remember to replace `🚧` with `✅` when it ships, and to
   document the feature in `README.md` as part of the same task.
