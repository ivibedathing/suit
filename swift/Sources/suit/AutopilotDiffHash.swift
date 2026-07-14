import Foundation

// Stable fingerprint of a PR diff, persisted on the run
// (AutopilotRun.lastReviewedDiffHash) so a review attempt can recognize a
// byte-identical diff and skip the headless claude call — the verdict
// couldn't change, only tokens would burn (AutopilotEngine+Gates). FNV-1a 64
// over UTF-8: seed-free (Swift's Hasher is process-randomized, useless
// persisted), dependency-free, and byte-exact — cryptographic strength isn't
// needed to compare a run's own consecutive diffs. Foundation-only in its own
// file (the RoadmapParser pattern) so the roadmap-routing harness compiles it
// standalone.
enum AutopilotDiffHash {
    static func hash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
