import Foundation

// Drives AutopilotPaths: the path-only lookup behind the terminal context
// menu's Start/Stop Autopilot item, plus the root normalization it shares with
// AutopilotManager.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition {
        print("  FAIL: \(message)")
        failures += 1
    }
}

// MARK: - normalize

let home = NSHomeDirectory()
check(AutopilotPaths.normalize("/tmp/repo") == "/tmp/repo", "a plain path is used verbatim")
check(AutopilotPaths.normalize("/tmp/repo/") == "/tmp/repo", "one trailing slash is dropped")
check(AutopilotPaths.normalize("/tmp/repo///") == "/tmp/repo", "repeated trailing slashes are dropped")
check(AutopilotPaths.normalize("~/Projects/suit") == home + "/Projects/suit", "a tilde is expanded")
check(AutopilotPaths.normalize("/") == "/", "root survives the trailing-slash trim")
check(AutopilotPaths.normalize("") == "", "an empty path stays empty")

// The /private carve-out is the whole reason normalize doesn't use
// standardizedFileURL: rewriting it breaks worker session pinning.
check(AutopilotPaths.normalize("/private/tmp/repo") == "/private/tmp/repo",
      "/private must NOT be collapsed to /tmp — that would break session pinning")
check(AutopilotPaths.normalize("/tmp/repo") != AutopilotPaths.normalize("/private/tmp/repo"),
      "/tmp and /private/tmp stay distinct keys")

// MARK: - directory(_:isInside:)

check(AutopilotPaths.directory("/tmp/repo", isInside: "/tmp/repo"), "a root contains itself")
check(AutopilotPaths.directory("/tmp/repo/swift/Sources", isInside: "/tmp/repo"), "a nested dir is inside")
check(AutopilotPaths.directory("/tmp/repo/", isInside: "/tmp/repo"), "trailing slashes are normalized both sides")
check(AutopilotPaths.directory("~/repo/src", isInside: home + "/repo"), "a tilde cwd matches its expanded root")

// The bug a bare hasPrefix would introduce.
check(!AutopilotPaths.directory("/tmp/repo-two", isInside: "/tmp/repo"),
      "/tmp/repo-two must not be read as inside /tmp/repo (component-anchored)")
check(!AutopilotPaths.directory("/tmp/repository", isInside: "/tmp/repo"),
      "/tmp/repository must not be read as inside /tmp/repo")

check(!AutopilotPaths.directory("/tmp", isInside: "/tmp/repo"), "a parent is not inside its child")
check(!AutopilotPaths.directory("/other/place", isInside: "/tmp/repo"), "unrelated paths are outside")
check(!AutopilotPaths.directory("/tmp/repo", isInside: ""), "an empty root contains nothing")
check(!AutopilotPaths.directory("/tmp/repo", isInside: "/"), "/ must not swallow every pane")
check(!AutopilotPaths.directory("", isInside: "/tmp/repo"), "an empty directory is inside nothing")

// MARK: - bestRoot(for:among:)

check(AutopilotPaths.bestRoot(for: "/tmp/repo/src", among: ["/tmp/repo"]) == "/tmp/repo", "the one containing root wins")
check(AutopilotPaths.bestRoot(for: "/tmp/elsewhere", among: ["/tmp/repo"]) == nil, "no containing root -> nil")
check(AutopilotPaths.bestRoot(for: "/tmp/repo/src", among: []) == nil, "no engines -> nil")

// Nested repos: the innermost owner must win, regardless of argument order.
let nested = ["/tmp/repo", "/tmp/repo/vendor/dep"]
check(AutopilotPaths.bestRoot(for: "/tmp/repo/vendor/dep/src", among: nested) == "/tmp/repo/vendor/dep",
      "longest match wins for nested repos")
check(AutopilotPaths.bestRoot(for: "/tmp/repo/vendor/dep/src", among: nested.reversed()) == "/tmp/repo/vendor/dep",
      "longest match wins regardless of ordering")
check(AutopilotPaths.bestRoot(for: "/tmp/repo/swift", among: nested) == "/tmp/repo",
      "a dir outside the nested repo still resolves to the outer one")

// A pane sitting in an Autopilot worker's own worktree still belongs to the
// project driving it — that's where Stop is most likely to be reached for.
check(AutopilotPaths.bestRoot(for: "/tmp/repo/.claude/worktrees/phase-1-foo", among: ["/tmp/repo"]) == "/tmp/repo",
      "a task worktree resolves to its project root")

// Sibling repos must never be confused for one another.
check(AutopilotPaths.bestRoot(for: "/tmp/repo-two/src", among: ["/tmp/repo", "/tmp/repo-two"]) == "/tmp/repo-two",
      "sibling repos sharing a prefix stay distinct")

// Mixed spellings across the registry.
check(AutopilotPaths.bestRoot(for: home + "/repo/src", among: ["~/repo"]) == "~/repo",
      "the matched root is returned as given, so it can key the engines dictionary")

print("")
if failures == 0 {
    print("All AutopilotPaths checks passed.")
} else {
    print("\(failures) check(s) FAILED.")
}
exit(failures == 0 ? 0 : 1)
