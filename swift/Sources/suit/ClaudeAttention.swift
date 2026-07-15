import Cocoa
import UserNotifications

// Native attention escalation: a session flipping to
// needs-input while Suit is in the background posts a user notification
// (click → activate + focus that pane), and the Dock badge counts sessions
// waiting on you. In-app attention stays exactly as before (pulsing title-bar
// dot, Sessions sort) — this only adds reach when the app isn't frontmost,
// and clicking the notification is the user's own focus grab, not the app's.
final class ClaudeAttentionCenter: NSObject, UNUserNotificationCenterDelegate {
    private var previousStates: [String: ClaudeSessionState] = [:]
    private let soundPlayer = NotificationSoundPlayer()
    private var authorizationRequested = false
    private let onFocusSession: (String) -> Void

    // UNUserNotificationCenter traps in a process with no bundle identity —
    // the bare `swiftc -o /tmp/suit-shell` dev run. The Dock badge is safe
    // either way; notifications just switch off outside the app bundle.
    private let notificationsAvailable = Bundle.main.bundleIdentifier != nil

    // Autopilot events: click-through routing for
    // notifications whose identifier carries the "autopilot-" prefix —
    // AppDelegate focuses the run tab when one is open, else opens the log.
    var onAutopilotEvent: ((String) -> Void)?

    // Activity feed: the once-daily digest notification
    // ("activity-" prefixed identifier) routes here — AppDelegate opens the
    // Activity panel. Same plumbing rationale as onAutopilotEvent.
    var onActivityEvent: (() -> Void)?

    // Cost budget guardrails: a budget trip notification
    // ("budget-" prefixed identifier) routes here with the session id carried in
    // the notification's userInfo — AppDelegate focuses that pane.
    var onBudgetEvent: ((String) -> Void)?

    // Update check: the "update-available" notification's click routes here —
    // AppDelegate presents the download offer via UpdateChecker.
    var onUpdateEvent: (() -> Void)?

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

        // Notification sounds: on the transition into done / needs-input while
        // the app is inactive, play the user's chosen system sound. Independent
        // of notificationsAvailable so it also works in the bare swiftc dev run.
        // The pure core (notificationSoundEvents) decides which events fire.
        if !NSApp.isActive {
            let appDelegate = NSApp.delegate as? AppDelegate
            let settings = NotificationSoundSettings(
                taskDoneEnabled: appDelegate?.taskDoneSoundEnabled ?? true,
                needsInputEnabled: appDelegate?.needsInputSoundEnabled ?? true
            )
            let events = notificationSoundEvents(
                previousStates: previousStates.mapValues(Self.soundState),
                currentStates: sessions.map { ($0.id, Self.soundState($0.state)) },
                settings: settings
            )
            for event in events {
                switch event {
                case .taskDone:
                    soundPlayer.play(named: appDelegate?.taskDoneSoundName ?? "Glass")
                case .needsInput:
                    soundPlayer.play(named: appDelegate?.needsInputSoundName ?? "Ping")
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
        center.add(UNNotificationRequest(identifier: session.id, content: content, trigger: nil))
    }

    // Autopilot's notifications: merged / blocked /
    // idle events with *stable* identifiers ("autopilot-merged",
    // "autopilot-blocked", "autopilot-idle") — a newer event of the same kind
    // replaces the previous one instead of piling up. Lives here because this
    // class is already the UNUserNotificationCenter delegate; a second
    // delegate would fight it.
    func postAutopilotEvent(title: String, body: String, identifier: String) {
        guard notificationsAvailable else { return }
        let center = UNUserNotificationCenter.current()
        if !authorizationRequested {
            authorizationRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    // Budget-trip notifications: a per-trip identifier (so a
    // distinct crossing is its own banner, not a replacement) with the session
    // id in userInfo for click-through routing to the pane. Presents even while
    // the app is active — a cap trip is always news, never silent.
    func postBudgetEvent(title: String, body: String, identifier: String, sessionId: String) {
        guard notificationsAvailable else { return }
        let center = UNUserNotificationCenter.current()
        if !authorizationRequested {
            authorizationRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["sessionId": sessionId]
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    // Update-available notification: the stable "update-available" identifier
    // means a re-check replaces the banner instead of piling up. Same
    // lives-here rationale as postAutopilotEvent.
    func postUpdateEvent(title: String, body: String) {
        guard notificationsAvailable else { return }
        let center = UNUserNotificationCenter.current()
        if !authorizationRequested {
            authorizationRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "update-available", content: content, trigger: nil))
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            if identifier.hasPrefix("autopilot-") {
                self?.onAutopilotEvent?(identifier)
            } else if identifier.hasPrefix("activity-") {
                self?.onActivityEvent?()
            } else if identifier.hasPrefix("update-") {
                self?.onUpdateEvent?()
            } else if identifier.hasPrefix("budget-") || identifier.hasPrefix("compact-") {
                // Budget trips and auto-compacts both route the click to the
                // pane hosting the session named in userInfo.
                let sessionId = response.notification.request.content.userInfo["sessionId"] as? String
                if let sessionId { self?.onBudgetEvent?(sessionId) }
            } else {
                self?.onFocusSession(identifier)
            }
        }
        completionHandler()
    }

    // While the app is active the in-app signals cover sessions; no banner on
    // top. The one exception is an Autopilot block (§2.11) — always news, so
    // it presents even while the app is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // An available update is news regardless of focus — without the banner
        // an active-app user would never learn a release shipped.
        if notification.request.identifier == "autopilot-blocked"
            || notification.request.identifier.hasPrefix("budget-")
            || notification.request.identifier.hasPrefix("update-") {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([])
        }
    }

    // Bridge ClaudeSessionState (AppKit-dependent) to the Foundation-only
    // core's state enum, so the sound decision stays in NotificationSoundCore.
    private static func soundState(_ state: ClaudeSessionState) -> NotificationSoundState {
        switch state {
        case .working: return .working
        case .needsInput: return .needsInput
        case .done: return .done
        }
    }
}
