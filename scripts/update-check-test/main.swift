import Foundation

// Standalone assertion driver for UpdateCheckCore
// (swift/Sources/suit/UpdateCheckCore.swift, Foundation-only, no app deps),
// compiled and run by scripts/update-check-test.sh. Mirrors the
// RoadmapParser / StoreFile standalone-test pattern.
//
// Pins the update flow's decisions: GitHub release JSON parsing (including
// the .dmg asset pick and the draft/prerelease refusal), the lenient version
// comparison behind "is this newer than the running build", the offer gate
// with its Skip This Version override, and the daily-check throttle.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

// MARK: - parseRelease

print("== UpdateCheck.parseRelease ==")

let full = """
{
  "tag_name": "v0.2.0",
  "html_url": "https://github.com/owner/repo/releases/tag/v0.2.0",
  "draft": false,
  "prerelease": false,
  "body": "Fixes and features.",
  "assets": [
    {"name": "checksums.txt", "browser_download_url": "https://example.com/checksums.txt"},
    {"name": "Suit-0.2.0.dmg", "browser_download_url": "https://example.com/Suit-0.2.0.dmg"}
  ]
}
"""
if let release = UpdateCheck.parseRelease(Data(full.utf8)) {
    check(release.tag == "v0.2.0", "tag_name comes through verbatim")
    check(release.pageURL == "https://github.com/owner/repo/releases/tag/v0.2.0", "html_url is the page URL")
    check(release.dmgURL == "https://example.com/Suit-0.2.0.dmg", "the .dmg asset is picked over other assets")
    check(release.notes == "Fixes and features.", "body becomes the notes")
} else {
    check(false, "a full release parses")
}

let minimal = """
{"tag_name": "v0.3.0", "html_url": "https://example.com/r"}
"""
if let release = UpdateCheck.parseRelease(Data(minimal.utf8)) {
    check(release.dmgURL == nil, "no assets → dmgURL nil (browser falls back to the page)")
    check(release.notes == "", "missing body → empty notes")
} else {
    check(false, "a minimal release (no assets, no body, no flags) parses")
}

let upperDMG = """
{"tag_name": "v1.0.0", "html_url": "https://e.com", "assets": [{"name": "SUIT.DMG", "browser_download_url": "https://e.com/SUIT.DMG"}]}
"""
check(UpdateCheck.parseRelease(Data(upperDMG.utf8))?.dmgURL == "https://e.com/SUIT.DMG",
      "the .dmg asset match is case-insensitive")

check(UpdateCheck.parseRelease(Data("{\"tag_name\": \"v9\", \"html_url\": \"u\", \"draft\": true}".utf8)) == nil,
      "a draft release is refused")
check(UpdateCheck.parseRelease(Data("{\"tag_name\": \"v9\", \"html_url\": \"u\", \"prerelease\": true}".utf8)) == nil,
      "a prerelease is refused")
check(UpdateCheck.parseRelease(Data("not json".utf8)) == nil, "malformed JSON returns nil")
check(UpdateCheck.parseRelease(Data("{\"message\": \"Not Found\"}".utf8)) == nil,
      "the GitHub 404 body (no tag_name) returns nil")

// MARK: - isVersion(newerThan:)

print("== UpdateCheck.isVersion(_:newerThan:) ==")

check(UpdateCheck.isVersion("v0.2.0", newerThan: "0.1.0"), "v0.2.0 > 0.1.0 (v-prefix ignored)")
check(UpdateCheck.isVersion("0.1.10", newerThan: "0.1.9"), "0.1.10 > 0.1.9 (numeric, not lexicographic)")
check(!UpdateCheck.isVersion("0.1.0", newerThan: "0.1.0"), "equal versions are not newer")
check(!UpdateCheck.isVersion("v0.1.0", newerThan: "0.1.0"), "equal versions are not newer across the v-prefix")
check(!UpdateCheck.isVersion("0.0.9", newerThan: "0.1.0"), "an older tag is not newer")
check(UpdateCheck.isVersion("1.2.1", newerThan: "1.2"), "1.2.1 > 1.2 (missing components count as 0)")
check(!UpdateCheck.isVersion("1.2", newerThan: "1.2.0"), "1.2 == 1.2.0")
check(UpdateCheck.isVersion("2", newerThan: "1.9.9"), "2 > 1.9.9")
check(UpdateCheck.isVersion("1.2.3-beta", newerThan: "1.2.2"), "a -suffix component contributes its leading digits")
check(!UpdateCheck.isVersion("nightly", newerThan: "0.1.0"), "a non-numeric tag is not newer (no offer loop)")
check(!UpdateCheck.isVersion("garbage", newerThan: "junk"), "two non-numeric tags compare as not newer")

// MARK: - shouldOffer

print("== UpdateCheck.shouldOffer ==")

let release = UpdateRelease(tag: "v0.2.0", pageURL: "u", dmgURL: nil, notes: "")
check(UpdateCheck.shouldOffer(release, currentVersion: "0.1.0", skippedVersion: nil),
      "a newer, unskipped release is offered")
check(!UpdateCheck.shouldOffer(release, currentVersion: "0.2.0", skippedVersion: nil),
      "the running version is not re-offered")
check(!UpdateCheck.shouldOffer(release, currentVersion: "0.3.0", skippedVersion: nil),
      "an older release is not offered (downgrade)")
check(!UpdateCheck.shouldOffer(release, currentVersion: "0.1.0", skippedVersion: "v0.2.0"),
      "Skip This Version silences exactly that tag")
check(UpdateCheck.shouldOffer(release, currentVersion: "0.1.0", skippedVersion: "v0.1.5"),
      "a skip of an older tag does not silence a newer release")

// MARK: - isCheckDue

print("== UpdateCheck.isCheckDue ==")

let now = Date(timeIntervalSince1970: 1_000_000)
let day: TimeInterval = 24 * 60 * 60
check(UpdateCheck.isCheckDue(now: now, lastCheck: nil, interval: day), "never checked → due")
check(UpdateCheck.isCheckDue(now: now, lastCheck: now.addingTimeInterval(-day), interval: day),
      "exactly one interval ago → due")
check(!UpdateCheck.isCheckDue(now: now, lastCheck: now.addingTimeInterval(-60), interval: day),
      "a minute ago → not due")
check(UpdateCheck.isCheckDue(now: now, lastCheck: now.addingTimeInterval(3600), interval: day),
      "a future lastCheck (clock rolled back) → due, not silenced")

// MARK: - verdict

if failures == 0 {
    print("ALL PASS")
    exit(0)
} else {
    print("\(failures) FAILURE(S)")
    exit(1)
}
