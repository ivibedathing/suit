# Suit shell extras — sourced by the ZDOTDIR shim (~/.suit/zsh/.zshrc) when
# the "Shell helpers (run_silent)" Settings toggle is on. Purely additive
# function definitions: no prompt, keybinding, or option changes, so normal
# interactive use is untouched.

# run_silent <command...> — run a command with its output buffered to a temp
# file; print only "✓ <cmd> (Ns)" on success, the full output plus
# "✗ <cmd> (exit N, Ns)" on failure. The token-saving shape for builds and
# tests in a Claude session: green runs cost a line, failures keep everything.
# Fails open — if the temp file can't be created, the command just runs
# normally.
zmodload zsh/datetime 2>/dev/null

run_silent() {
  if [ $# -eq 0 ]; then
    print -u2 "usage: run_silent <command> [args...]"
    return 64
  fi
  local out start elapsed rc
  out="$(mktemp -t run_silent)" || { "$@"; return $?; }
  start=${EPOCHSECONDS:-0}
  if "$@" >"$out" 2>&1; then
    elapsed=$(( ${EPOCHSECONDS:-0} - start ))
    print "✓ $* (${elapsed}s)"
    rm -f "$out"
    return 0
  else
    rc=$?
    elapsed=$(( ${EPOCHSECONDS:-0} - start ))
    cat "$out"
    rm -f "$out"
    print "✗ $* (exit $rc, ${elapsed}s)"
    return $rc
  fi
}
