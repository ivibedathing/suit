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

# Bundle universal-ctags (go-to-definition / find-references, ROADMAP Phase 33)
# the same way rg is bundled. Deliberately does NOT accept /usr/bin/ctags: on
# macOS that's BSD ctags, which doesn't speak the JSON output format the symbol
# index parses — so we probe likely universal-ctags install paths and confirm
# the binary really is Universal Ctags before copying. Missing → the app falls
# back to an rg word search at runtime (see resolveCtagsExecutable /
# SymbolIndex.swift).
CTAGS_BIN=""
for candidate in /opt/homebrew/bin/ctags /usr/local/bin/ctags "$(command -v ctags || true)"; do
  if [ -n "$candidate" ] && [ -x "$candidate" ] && "$candidate" --version 2>/dev/null | grep -qi "Universal Ctags"; then
    CTAGS_BIN="$candidate"
    break
  fi
done
if [ -n "$CTAGS_BIN" ]; then
  cp "$CTAGS_BIN" "$CONTENTS/Resources/ctags"
else
  echo "warning: universal-ctags not found — go-to-definition falls back to an rg word search" >&2
fi

# Bundle the Claude Code integration scripts (statusline + session-state
# hooks) so the app can install them from the UI without a checkout of this
# repo (see ClaudeIntegration.swift).
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
