---
description: Quick file search by name — locate repo files whose path matches a query
argument-hint: "<name, substring, or glob>"
allowed-tools: Bash(git ls-files:*), Bash(grep:*), Bash(head:*), Bash(rg:*), Read
---

Find files in this repository by name. Query: **`$ARGUMENTS`**

Case-insensitive substring matches over the tracked + untracked, gitignore-respecting
file list (the same `git ls-files --cached --others --exclude-standard` index the app's
Cmd-P uses, so results match what Suit itself shows):

!`git ls-files --cached --others --exclude-standard | grep -i -- "$ARGUMENTS" | head -50`

Now, using the matches above:

- **Exactly one match** → that's the answer; report its path. Read it only if the user
  asked to see or open the file.
- **Several matches** → list them (prefer the ones whose *basename* — not just a parent
  directory — contains the query), then pick the most likely given the conversation or
  ask which one.
- **No matches** → the query may be a glob or too specific. Retry once with
  `rg --files -g "$ARGUMENTS"` (glob, e.g. `*Pane*.swift`), and if that's still empty try a
  shorter substring. Report honestly if nothing matches.
- **Empty query** → ask for a filename, substring, or glob to search for.

Keep it quick: this is a locator, not a code review — return the path(s), don't dump file
contents unless asked.
