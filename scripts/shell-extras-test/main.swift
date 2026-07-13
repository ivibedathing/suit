import Foundation

// Standalone assertion driver for the shell-helpers injection core
// (ShellInjection.swift, Foundation-only, no app deps), compiled by
// scripts/shell-extras-test.sh. Asserts the env construction: nil when
// disabled or non-zsh, the ZDOTDIR shim vars when on, a pre-existing ZDOTDIR
// captured into SUIT_USER_ZDOTDIR, and the base entries preserved. The shim
// files and run_silent themselves are exercised by the .sh half with a real
// zsh in a scratch HOME.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

let base = ["TERM=xterm-256color", "COLORTERM=truecolor", "LANG=en_US.UTF-8",
            "USER=tester", "HOME=/home/tester"]
let home = "/home/tester"

print("== disabled / non-zsh ==")
check(ShellInjection.environment(base: base, enabled: false, shellPath: "/bin/zsh", home: home) == nil,
      "disabled → nil (launch exactly as today)")
check(ShellInjection.environment(base: base, enabled: true, shellPath: "/bin/bash", home: home) == nil,
      "bash → nil")
check(ShellInjection.environment(base: base, enabled: true, shellPath: "/opt/homebrew/bin/fish", home: home) == nil,
      "fish → nil")

print("== zsh injection ==")
let env = ShellInjection.environment(base: base, enabled: true, shellPath: "/bin/zsh", home: home)
check(env != nil, "enabled zsh → a custom environment")
if let env {
    check(env.contains("ZDOTDIR=/home/tester/.suit/zsh"), "ZDOTDIR points at the shim")
    check(env.contains("SUIT_USER_ZDOTDIR=/home/tester"), "the user chain defaults to $HOME")
    check(env.contains("SUIT_SHELL_EXTRAS=/home/tester/.suit/scripts/suit-shell-extras.zsh"),
          "the extras path is passed through the env")
    check(env.filter { $0.hasPrefix("ZDOTDIR=") }.count == 1, "exactly one ZDOTDIR")
    for entry in base {
        check(env.contains(entry), "base entry preserved: \(entry)")
    }
}

print("== zsh from a custom install path ==")
check(ShellInjection.environment(base: base, enabled: true, shellPath: "/opt/homebrew/bin/zsh", home: home) != nil,
      "any path whose basename is zsh injects")

print("== a pre-existing ZDOTDIR is captured, not clobbered ==")
let custom = base + ["ZDOTDIR=/home/tester/.config/zsh"]
if let env = ShellInjection.environment(base: custom, enabled: true, shellPath: "/bin/zsh", home: home) {
    check(env.contains("SUIT_USER_ZDOTDIR=/home/tester/.config/zsh"),
          "the original ZDOTDIR becomes the user chain")
    check(env.contains("ZDOTDIR=/home/tester/.suit/zsh"), "the shim owns ZDOTDIR")
    check(env.filter { $0.hasPrefix("ZDOTDIR=") }.count == 1, "no duplicate ZDOTDIR")
} else {
    check(false, "custom-ZDOTDIR base still injects")
}

print("== a stale shim ZDOTDIR in the base is not treated as the user's ==")
let stale = base + ["ZDOTDIR=/home/tester/.suit/zsh"]
if let env = ShellInjection.environment(base: stale, enabled: true, shellPath: "/bin/zsh", home: home) {
    check(env.contains("SUIT_USER_ZDOTDIR=/home/tester"),
          "the shim's own dir never becomes the user chain")
} else {
    check(false, "stale-shim base still injects")
}

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
