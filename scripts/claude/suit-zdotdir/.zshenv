# Suit ZDOTDIR shim (.zshenv) — first file zsh reads. Sources your real
# .zshenv, then keeps the shim in charge of the rest of the startup chain.
# Installed to ~/.suit/zsh/ by Suit's "Shell helpers" toggle; never edits
# anything in $HOME. See suit-shell-extras.zsh for what gets added.
SUIT_ZDOTDIR="${ZDOTDIR:-$HOME/.suit/zsh}"
: "${SUIT_USER_ZDOTDIR:=$HOME}"
export SUIT_USER_ZDOTDIR

if [ -f "$SUIT_USER_ZDOTDIR/.zshenv" ]; then
  # Present the environment your .zshenv expects while it runs.
  ZDOTDIR="$SUIT_USER_ZDOTDIR"
  . "$SUIT_USER_ZDOTDIR/.zshenv"
fi

# Your .zshenv may have re-pointed ZDOTDIR (frameworks do this): follow it as
# the source of your remaining config files, but route the chain back through
# the shim so the extras still load at the end of .zshrc.
if [ -n "$ZDOTDIR" ] && [ "$ZDOTDIR" != "$SUIT_ZDOTDIR" ] && [ "$ZDOTDIR" != "$SUIT_USER_ZDOTDIR" ]; then
  SUIT_USER_ZDOTDIR="$ZDOTDIR"
  export SUIT_USER_ZDOTDIR
fi
ZDOTDIR="$SUIT_ZDOTDIR"
