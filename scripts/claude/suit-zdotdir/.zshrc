# Suit ZDOTDIR shim (.zshrc) — sources your real .zshrc (oh-my-zsh, p10k,
# aliases) first, then loads Suit's shell extras exactly once.
if [ -f "$SUIT_USER_ZDOTDIR/.zshrc" ]; then
  . "$SUIT_USER_ZDOTDIR/.zshrc"
fi

# Guarded against re-sourcing within one shell (e.g. `source ~/.zshrc`).
# Deliberately NOT exported: functions don't cross a process boundary, so a
# nested `zsh` must source its own copy — an inherited guard would leave it
# without run_silent.
if [ -z "$SUIT_EXTRAS_LOADED" ] && [ -n "$SUIT_SHELL_EXTRAS" ] && [ -f "$SUIT_SHELL_EXTRAS" ]; then
  SUIT_EXTRAS_LOADED=1
  . "$SUIT_SHELL_EXTRAS"
fi
