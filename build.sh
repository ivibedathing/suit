#!/usr/bin/env bash
# Builds Suit.app: a native Swift/AppKit terminal (SwiftTerm + pty),
# packaged as a real macOS app bundle.
#
# NOTE: Swift sources are compiled directly with `swiftc` instead of Swift
# Package Manager. On this machine's beta Xcode Command Line Tools (27.0),
# `swift build` fails to even link its own manifest for a brand-new empty
# package, so SwiftTerm is vendored as source under swift/Vendor/SwiftTerm
# and compiled together with our own sources as a single module.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Suit.app"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

echo "==> Building Swift shell"
swiftc -O \
  "$ROOT"/swift/Sources/suit/*.swift \
  $(find "$ROOT/swift/Vendor/SwiftTerm" -name '*.swift') \
  -o "$CONTENTS/MacOS/Suit"

echo "==> Assembling bundle"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

# Bundle ripgrep (project-wide search) so the app doesn't depend on the user's
# PATH. Skipped when rg isn't installed on the build machine; the app then
# falls back to common install locations at runtime (see RipgrepSearch.swift).
RG_BIN="$(command -v rg || true)"
if [ -z "$RG_BIN" ]; then
  for candidate in /opt/homebrew/bin/rg /usr/local/bin/rg "$HOME/.local/share/opencode/bin/rg"; do
    if [ -x "$candidate" ]; then
      RG_BIN="$candidate"
      break
    fi
  done
fi
if [ -n "$RG_BIN" ]; then
  cp "$RG_BIN" "$CONTENTS/Resources/rg"
else
  echo "warning: rg not found — search will rely on a runtime fallback" >&2
fi

# Bundle universal-ctags (go-to-definition / find-references symbol index,
# ROADMAP Phase 33) the same way as rg. Only a *universal* ctags is bundled —
# macOS-stock /usr/bin/ctags is BSD ctags, which rejects our flags — so probe
# --version for "Universal Ctags". When absent the app degrades to an rg word
# search (see SymbolIndex.swift), so a missing binary is a warning, not a fail.
CTAGS_BIN=""
for candidate in "$(command -v ctags || true)" /opt/homebrew/bin/ctags /usr/local/bin/ctags; do
  if [ -n "$candidate" ] && [ -x "$candidate" ] && "$candidate" --version 2>/dev/null | grep -q "Universal Ctags"; then
    CTAGS_BIN="$candidate"
    break
  fi
done
if [ -n "$CTAGS_BIN" ]; then
  cp "$CTAGS_BIN" "$CONTENTS/Resources/ctags"
else
  echo "warning: universal-ctags not found — go-to-definition will rely on the rg word-search fallback" >&2
fi

# Bundle rtk (output-compression wrapper for the "Compress tool output with rtk"
# toggle, see RtkHook.swift) the same way as rg/ctags. Optional: when absent the
# installed PreToolUse hook falls back to `rtk` on the user's PATH, and passes
# commands through untouched if that is missing too — so a missing binary is a
# warning, not a failure.
RTK_BIN="$(command -v rtk || true)"
if [ -z "$RTK_BIN" ]; then
  for candidate in /opt/homebrew/bin/rtk /usr/local/bin/rtk; do
    if [ -x "$candidate" ]; then
      RTK_BIN="$candidate"
      break
    fi
  done
fi
if [ -n "$RTK_BIN" ]; then
  cp "$RTK_BIN" "$CONTENTS/Resources/rtk"
else
  echo "warning: rtk not found — the rtk compression hook will rely on a PATH lookup at runtime" >&2
fi

# Bundle the Claude Code integration scripts (statusline + session-state
# hooks, plus the rtk rewrite hook) so the app can install them from the UI
# without a checkout of this repo (see ClaudeIntegration.swift / RtkHook.swift).
mkdir -p "$CONTENTS/Resources/claude"
cp "$ROOT"/scripts/claude/*.sh "$CONTENTS/Resources/claude/"
chmod +x "$CONTENTS/Resources/claude/"*.sh

# Bundle the suit-bg background-task wrapper (ROADMAP Phase 30) so it ships with
# the app; users symlink it onto their PATH to track jobs in the monitor.
cp "$ROOT/scripts/suit-bg.sh" "$CONTENTS/Resources/suit-bg.sh"
chmod +x "$CONTENTS/Resources/suit-bg.sh"

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "$APP"

echo "==> Built $APP"
