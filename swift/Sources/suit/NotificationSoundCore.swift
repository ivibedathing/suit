import Foundation

// Notification-sound decision core (Foundation-only, no app deps — mirrors
// Recipes / RoadmapParser). Given the previous state per session id and the
// current states, it decides which sound *events* fire on this update. The
// AppKit half (NotificationSounds.swift + ClaudeAttentionCenter) maps each
// event to the user's chosen NSSound and plays it while the app is inactive.
// State is a core-owned enum so this file stays free of ClaudeSessionState,
// which lives in the AppKit-dependent ClaudeSessions.swift.

enum NotificationSoundState {
    case working
    case needsInput
    case done
}

enum NotificationSoundEvent: Equatable {
    case taskDone      // a session transitioned into .done
    case needsInput    // a session transitioned into .needsInput
}

struct NotificationSoundSettings {
    var taskDoneEnabled: Bool
    var needsInputEnabled: Bool
}

// A session fires an event when it *enters* the matching state — its current
// state is the target and its previous state (absent = different) was not the
// target. Each event is emitted at most once per update even if several
// sessions transition together, in the fixed order [.taskDone, .needsInput].
func notificationSoundEvents(
    previousStates: [String: NotificationSoundState],
    currentStates: [(id: String, state: NotificationSoundState)],
    settings: NotificationSoundSettings
) -> [NotificationSoundEvent] {
    var doneFired = false
    var needsFired = false
    for entry in currentStates {
        let wasDone = previousStates[entry.id] == .done
        let wasNeeds = previousStates[entry.id] == .needsInput
        if entry.state == .done, !wasDone, settings.taskDoneEnabled {
            doneFired = true
        }
        if entry.state == .needsInput, !wasNeeds, settings.needsInputEnabled {
            needsFired = true
        }
    }
    var events: [NotificationSoundEvent] = []
    if doneFired { events.append(.taskDone) }
    if needsFired { events.append(.needsInput) }
    return events
}
