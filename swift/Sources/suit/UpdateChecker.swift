import Cocoa

// Update check — the AppKit half. Polls the GitHub releases API for a tag
// newer than the running bundle's CFBundleShortVersionString, raises a user
// notification (click → the offer alert), and hands the download to the
// browser: the user downloads the new .dmg themselves — Suit doesn't
// self-replace. All the decisions (parsing, version compare, offer/throttle)
// live in UpdateCheckCore.swift, the harness-tested pure core.
//
// Cadence: one API hit at most every 24 h, evaluated shortly after launch and
// on a 6 h timer for machines that stay up for weeks. "Skip This Version"
// silences that tag until a newer one ships; the manual App menu ▸ Check for
// Updates… entry ignores the skip and the throttle.
final class UpdateChecker {
    // Where releases are published — the repo this app is built from.
    static let repo = "ivibedathing/suit"

    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let timerInterval: TimeInterval = 6 * 60 * 60

    // Posts the "update available" user notification; AppDelegate wires this
    // to ClaudeAttentionCenter so this class stays out of the UN* delegate.
    private let postNotification: (_ title: String, _ body: String) -> Void

    private let store = UpdateCheckStore()
    private var timer: Timer?
    // The release behind the currently delivered notification; the
    // click-through (onUpdateEvent) presents it.
    private var pendingRelease: UpdateRelease?

    // nil in the bare `swiftc -o /tmp/suit-shell` dev run, which has no bundle
    // Info.plist — automatic checks switch off there, same reasoning as
    // ClaudeAttentionCenter.notificationsAvailable.
    private let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    init(postNotification: @escaping (_ title: String, _ body: String) -> Void) {
        self.postNotification = postNotification
    }

    // Launch + long-uptime cadence. The first evaluation is delayed so an
    // update banner never races the window restore work at startup.
    func startAutomaticChecks() {
        guard currentVersion != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.checkIfDue()
        }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.timerInterval, repeats: true) { [weak self] _ in
            self?.checkIfDue()
        }
        timer.tolerance = 60
        self.timer = timer
    }

    private func checkIfDue() {
        guard UpdateCheck.isCheckDue(now: Date(), lastCheck: store.lastCheck, interval: Self.checkInterval) else { return }
        check(userInitiated: false)
    }

    // App menu ▸ Check for Updates…: always hits the network and always
    // answers — update offer, "up to date", or the error.
    func checkNow() {
        check(userInitiated: true)
    }

    // Notification click-through: show the offer the banner announced.
    func presentPendingUpdate() {
        guard let release = pendingRelease else { return }
        presentOffer(release)
    }

    private func check(userInitiated: Bool) {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.handleResult(data: data, response: response, error: error, userInitiated: userInitiated)
            }
        }.resume()
    }

    private func handleResult(data: Data?, response: URLResponse?, error: Error?, userInitiated: Bool) {
        // Stamp the attempt either way — a flaky network shouldn't turn the
        // 6 h timer into a retry hammer; the next daily window tries again.
        store.noteChecked()

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard error == nil, status == 200, let data, let release = UpdateCheck.parseRelease(data) else {
            if userInitiated {
                // 404 with no error usually means no release published yet.
                let detail = error?.localizedDescription
                    ?? (status == 404 ? "No releases found for \(Self.repo)." : "Unexpected response (HTTP \(status)).")
                presentInfo(title: "Couldn’t Check for Updates", body: detail)
            }
            return
        }

        guard let currentVersion else {
            if userInitiated {
                presentInfo(
                    title: "Version Unknown",
                    body: "Suit was launched outside the app bundle, so there's no version to compare. Latest release: \(release.tag)."
                )
            }
            return
        }

        // A manual check overrides an earlier "Skip This Version".
        let skipped = userInitiated ? nil : store.skippedVersion
        guard UpdateCheck.shouldOffer(release, currentVersion: currentVersion, skippedVersion: skipped) else {
            if userInitiated {
                presentInfo(title: "You’re Up to Date", body: "Suit \(currentVersion) is the latest version.")
            }
            return
        }

        if userInitiated {
            presentOffer(release)
        } else {
            // Background find: a notification, not a modal — the offer alert
            // waits for the click (ClaudeAttentionCenter routes "update-" here).
            pendingRelease = release
            postNotification("Suit \(release.tag) is available", "Click to download the update.")
        }
    }

    // The offer: Download opens the .dmg (or the release page when the release
    // has no .dmg asset) in the browser — installing stays a user action.
    private func presentOffer(_ release: UpdateRelease) {
        let alert = NSAlert()
        alert.messageText = "Suit \(release.tag) is available"
        var info = "You have \(currentVersion ?? "an unknown version"). Download the new .dmg and drag it into Applications to update."
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            info += "\n\n" + String(notes.prefix(600))
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Remind Me Later")
        alert.addButton(withTitle: "Skip This Version")

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = URL(string: release.dmgURL ?? release.pageURL) {
                NSWorkspace.shared.open(url)
            }
        case .alertThirdButtonReturn:
            store.skipVersion(release.tag)
        default:
            break // Remind Me Later: the next daily check offers again.
        }
        pendingRelease = nil
    }

    private func presentInfo(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// ~/.suit/update-check.json — the check throttle stamp and the skipped tag.
// FavoritesStore pattern: $HOME-resolved path, StoreFile load, atomic write.
private final class UpdateCheckStore {
    private struct Model: Codable {
        var lastCheckedAt: TimeInterval?
        var skippedVersion: String?
    }

    private var model = Model()

    private var fileURL: URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home + "/.suit/update-check.json")
    }

    init() {
        if let decoded = StoreFile.load(Model.self, from: fileURL.path) {
            model = decoded
        }
    }

    var lastCheck: Date? {
        model.lastCheckedAt.map { Date(timeIntervalSince1970: $0) }
    }

    var skippedVersion: String? {
        model.skippedVersion
    }

    func noteChecked() {
        model.lastCheckedAt = Date().timeIntervalSince1970
        save()
    }

    func skipVersion(_ tag: String) {
        model.skippedVersion = tag
        save()
    }

    private func save() {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(model) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
