import Cocoa
import UserNotifications

// Native attention escalation (ROADMAP Phase 7): a session flipping to
// needs-input while Suit is in the background posts a user notification
// (click → activate + focus that pane), and the Dock badge counts sessions
// waiting on you. In-app attention stays exactly as before (pulsing title-bar
// dot, Sessions sort) — this only adds reach when the app isn't frontmost,
// and clicking the notification is the user's own focus grab, not the app's.
final class ClaudeAttentionCenter: NSObject, UNUserNotificationCenterDelegate {
    private var previousStates: [String: ClaudeSessionState] = [:]
    private var authorizationRequested = false
    private let onFocusSession: (String) -> Void

    // UNUserNotificationCenter traps in a process with no bundle identity —
    // the bare `swiftc -o /tmp/suit-shell` dev run. The Dock badge is safe
    // either way; notifications just switch off outside the app bundle.
    private let notificationsAvailable = Bundle.main.bundleIdentifier != nil

    init(onFocusSession: @escaping (String) -> Void) {
        self.onFocusSession = onFocusSession
        super.init()
        if notificationsAvailable {
            UNUserNotificationCenter.current().delegate = self
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionsUpdated),
            name: ClaudeSessionMonitor.didUpdate, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func sessionsUpdated() {
        let sessions = ClaudeSessionMonitor.shared.sessions
        let needsInput = sessions.filter { $0.state == .needsInput }

        NSApp.dockTile.badgeLabel = needsInput.isEmpty ? nil : String(needsInput.count)

        if notificationsAvailable {
            // Sessions that stopped needing input take their notification with
            // them — a banner for an already-answered session is stale noise.
            let resolved = previousStates
                .filter { $0.value == .needsInput }
                .map(\.key)
                .filter { id in !needsInput.contains { $0.id == id } }
            if !resolved.isEmpty {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: resolved)
            }

            // Escalate only on the transition into needs-input, and only while
            // the app is inactive — when it's frontmost the pulsing dot and
            // Sessions sort already carry the signal.
            if !NSApp.isActive {
                for session in needsInput where previousStates[session.id] != .needsInput {
                    post(for: session)
                }
            }
        }

        previousStates = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.state) })
    }

    private func post(for session: ClaudeSession) {
        let center = UNUserNotificationCenter.current()
        if !authorizationRequested {
            authorizationRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = session.displayName
        var body = "Claude needs input"
        if let cwd = session.cwd {
            body += " · \((cwd as NSString).lastPathComponent)"
        }
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: session.id, content: content, trigger: nil))
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sessionId = response.notification.request.identifier
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.onFocusSession(sessionId)
        }
        completionHandler()
    }

    // While the app is active the in-app signals cover it; no banner on top.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }
}
