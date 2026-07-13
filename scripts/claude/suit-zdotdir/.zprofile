# Suit ZDOTDIR shim (.zprofile) — sources your real .zprofile (login shells:
# Homebrew shellenv, PATH setup) and adds nothing of its own.
if [ -f "$SUIT_USER_ZDOTDIR/.zprofile" ]; then
  . "$SUIT_USER_ZDOTDIR/.zprofile"
fi
