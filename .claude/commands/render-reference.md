---
description: Regenerate the committed design reference render after a chrome change
allowed-tools: Bash(design/render-reference.sh), Bash(./design/render-reference.sh), Bash(git status:*), Bash(git diff:*)
---

Run `design/render-reference.sh` to regenerate `design/phase15-window.png`, the
committed offscreen render of the design scenario (pinned terminal + shell +
viewer split). Per AGENTS.md, re-run and commit this after any window-chrome
change so visual drift shows up in review diffs (ROADMAP Phase 15).

After it runs, `git status` the PNG. If it changed, that's expected drift from
your chrome edit — eyeball it and include it in your commit. If it changed and
you did *not* touch chrome, investigate why before committing.
