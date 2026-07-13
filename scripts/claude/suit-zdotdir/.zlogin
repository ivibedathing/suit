# Suit ZDOTDIR shim (.zlogin) — sources your real .zlogin and adds nothing of
# its own.
if [ -f "$SUIT_USER_ZDOTDIR/.zlogin" ]; then
  . "$SUIT_USER_ZDOTDIR/.zlogin"
fi
