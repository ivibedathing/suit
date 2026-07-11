import Cocoa

// AppKit half of the notification-sound feature (decision logic is the
// Foundation-only NotificationSoundCore). Plays a chosen macOS system sound
// and enumerates the available ones for the Settings pickers.

// Holds a strong reference to every currently-playing NSSound so ARC does not
// deallocate one mid-play — including when two sounds (task-done + needs-input)
// fire in the same update. Each sound is released when it finishes. A name
// NSSound can't resolve is a silent no-op.
final class NotificationSoundPlayer: NSObject, NSSoundDelegate {
    private var playing: [NSSound] = []

    func play(named name: String) {
        guard let sound = NSSound(named: name) else { return }
        sound.delegate = self
        playing.append(sound)
        sound.play()
    }

    func sound(_ sound: NSSound, didFinishPlaying finished: Bool) {
        playing.removeAll { $0 === sound }
    }
}

// Basenames of the built-in macOS system sounds (e.g. "Glass", "Ping"),
// sorted, suitable for NSSound(named:) and the Settings sound pickers.
func availableSystemSounds() -> [String] {
    let dir = "/System/Library/Sounds"
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return entries
        .filter { $0.hasSuffix(".aiff") }
        .map { ($0 as NSString).deletingPathExtension }
        .sorted()
}
