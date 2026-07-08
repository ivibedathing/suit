import Foundation

// The per-task isolation decision (ROADMAP Phase 31), pulled out UI-free and
// standalone-compilable so the harness can assert it (the RoadmapParser /
// FeedbackRouting pattern). Phase 5 made "New Claude Task" always spin a
// worktree; Phase 31 makes it a choice — on isolates the task in its own
// worktree, off runs `claude` in the current checkout.
enum TaskLaunch {
    // Whether the task should get its own worktree at all.
    static func usesWorktree(isolate: Bool) -> Bool { isolate }

    // The directory the task's `claude` runs in: the freshly-created worktree
    // when isolating (and one was made), else the current checkout root. A nil
    // `worktreeDirectory` while isolating means worktree creation failed — the
    // caller surfaces that error instead of launching, so this still answers
    // with the checkout root as the safe fallback.
    static func checkoutDirectory(isolate: Bool, currentRoot: String, worktreeDirectory: String?) -> String {
        if isolate, let worktreeDirectory { return worktreeDirectory }
        return currentRoot
    }
}
