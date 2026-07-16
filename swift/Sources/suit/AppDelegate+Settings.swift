import Cocoa

// The non-appearance settings verbs: every Settings-pane toggle or field that
// isn't visual lands here as a `…Changed` handler — shell path, Claude session
// args, task isolation, and bells and sounds.
// Values persist via AppDelegate+SettingsPersistence; the visual handlers
// (font, colors, opacity, blur) live in AppDelegate+Appearance.
extension AppDelegate {
    // MARK: - Behavior settings

    // Only accepts executable paths (a bad shell would exec-fail every new
    // tab); returns whether the value was taken so the settings field can
    // revert. Running shells are untouched — this is a new-tab default.
    @discardableResult
    func shellPathChanged(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: expanded) else { return false }
        shellPath = expanded
        saveSettings()
        return true
    }

    func claudeSessionArgsChanged(_ args: String) {
        claudeSessionArgs = args.trimmingCharacters(in: .whitespaces)
        saveSettings()
    }

    func taskIsolateByDefaultChanged(_ enabled: Bool) {
        taskIsolateByDefault = enabled
        saveSettings()
    }

    func bellFlashChanged(_ enabled: Bool) {
        bellFlashEnabled = enabled
        saveSettings()
    }

    func bellDockBounceChanged(_ enabled: Bool) {
        bellDockBounceEnabled = enabled
        saveSettings()
    }

    func taskDoneSoundEnabledChanged(_ enabled: Bool) {
        taskDoneSoundEnabled = enabled
        saveSettings()
    }

    func needsInputSoundEnabledChanged(_ enabled: Bool) {
        needsInputSoundEnabled = enabled
        saveSettings()
    }

    func taskDoneSoundNameChanged(_ name: String) {
        taskDoneSoundName = name
        saveSettings()
    }

    func needsInputSoundNameChanged(_ name: String) {
        needsInputSoundName = name
        saveSettings()
    }

    func goalProvenanceChanged(_ enabled: Bool) {
        goalPrependProvenanceEnabled = enabled
        saveSettings()
    }
}
