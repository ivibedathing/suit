import Foundation

// Update check — the pure core. Parses the GitHub "latest release" API
// response, compares versions, and decides whether a release is worth
// offering to the user. Foundation-only with no app dependencies so
// scripts/update-check-test.sh can compile it standalone (the
// RoadmapParser / Recipes pattern); UpdateChecker.swift is the AppKit half
// that does the actual network fetch, notification, and download hand-off.

// One published release, reduced to what the update flow needs.
struct UpdateRelease: Equatable {
    // Tag as published, e.g. "v0.2.0" — shown to the user and remembered
    // verbatim as the "skipped" marker.
    let tag: String
    // The release page (html_url) — the fallback the browser opens when the
    // release carries no .dmg asset.
    let pageURL: String
    // Direct browser_download_url of the first .dmg asset, if any.
    let dmgURL: String?
    // Release notes (body), possibly empty.
    let notes: String
}

enum UpdateCheck {
    // Codable mirror of the fields we read from
    // GET /repos/{owner}/{repo}/releases/latest.
    private struct APIRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        let tag_name: String
        let html_url: String
        let draft: Bool?
        let prerelease: Bool?
        let body: String?
        let assets: [Asset]?
    }

    // Parse the API response. Returns nil for malformed JSON and for
    // draft/prerelease entries — the /latest endpoint shouldn't serve those,
    // but a defensive nil beats offering an unpublished build.
    static func parseRelease(_ data: Data) -> UpdateRelease? {
        guard let release = try? JSONDecoder().decode(APIRelease.self, from: data) else { return nil }
        if release.draft == true || release.prerelease == true { return nil }
        let dmg = (release.assets ?? []).first { $0.name.lowercased().hasSuffix(".dmg") }
        return UpdateRelease(
            tag: release.tag_name,
            pageURL: release.html_url,
            dmgURL: dmg?.browser_download_url,
            notes: release.body ?? ""
        )
    }

    // Numeric dot-component comparison with the usual release-tag leniency:
    // a leading "v"/"V" is ignored, each component contributes its leading
    // digits ("0.2.0-beta" → [0, 2, 0]), and missing components count as 0
    // ("1.2" == "1.2.0"). Anything non-numeric compares as 0, so two garbage
    // tags are simply "not newer" rather than an offer loop.
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = components(of: candidate)
        let b = components(of: current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func components(of version: String) -> [Int] {
        var v = Substring(version)
        if v.first == "v" || v.first == "V" { v = v.dropFirst() }
        return v.split(separator: ".").map { part in
            Int(part.prefix { $0.isNumber }) ?? 0
        }
    }

    // Should this release be offered? Only when it's strictly newer than the
    // running build and the user hasn't already dismissed this exact tag with
    // "Skip This Version". A user-initiated check passes skippedVersion: nil —
    // asking by hand overrides an earlier skip.
    static func shouldOffer(_ release: UpdateRelease, currentVersion: String, skippedVersion: String?) -> Bool {
        guard isVersion(release.tag, newerThan: currentVersion) else { return false }
        if let skipped = skippedVersion, skipped == release.tag { return false }
        return true
    }

    // Automatic checks are throttled to one network hit per interval (the
    // caller passes 24 h). A lastCheck in the future — clock rolled back —
    // counts as due rather than silencing checks until the clock catches up.
    static func isCheckDue(now: Date, lastCheck: Date?, interval: TimeInterval) -> Bool {
        guard let lastCheck else { return true }
        if lastCheck > now { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }
}
