# Suit shell extras — telling Claude about run_silent

Suit never edits your CLAUDE.md files. To get token savings from the shell
helpers, paste this snippet into the CLAUDE.md of projects where you run
builds/tests through Claude Code (installed to `~/.suit/scripts/` alongside
this file):

```markdown
## Terminal helpers

`run_silent <command>` is available in this terminal: it buffers the command's
output and prints only `✓ <command> (Ns)` on success — the full output appears
only on failure. Prefer it for builds, tests, and other commands whose success
output you don't need to read, e.g. `run_silent npm test`,
`run_silent ./build.sh`. Skip it when you need the output of a passing run.
```
