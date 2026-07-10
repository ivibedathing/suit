import Foundation

// Claude Code integration installer — the producer side of the Sessions
// sidebar. build.sh bundles scripts/claude/*.sh into
// Contents/Resources/claude/; "Install Claude Code Integration…" (app menu /
// palette) copies them to ~/.suit/scripts/ — a stable path that survives
// the app being moved or rebuilt — and wires them into ~/.claude/settings.json:
// the statusLine command plus the UserPromptSubmit/Notification/Stop hooks.
// The settings file is merged, never clobbered: unrelated keys and hooks are
// preserved, and the pre-install file is backed up once alongside it.
enum ClaudeIntegration {

    static let statuslineScript = "suit-statusline.sh"
    static let sessionStateScript = "suit-session-state.sh"
    static var scriptNames: [String] { [statuslineScript, sessionStateScript] }

    // $HOME rather than NSHomeDirectory(): the scripts and Claude Code both
    // resolve ~ from the environment, and it lets tests point everything at a
    // scratch home. NSHomeDirectory() ignores an overridden $HOME on macOS.
    static var home: String {
        ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    }
    static var installDir: String { home + "/.suit/scripts" }
    static var settingsPath: String { home + "/.claude/settings.json" }

    // Hook event → argument passed to suit-session-state.sh.
    private static let hookEvents: [(event: String, argument: String)] = [
        ("UserPromptSubmit", "working"),
        ("Notification", "needs-input"),
        ("Stop", "done"),
    ]

    private static var statuslineCommand: String { installDir + "/" + statuslineScript }
    private static func hookCommand(_ argument: String) -> String {
        installDir + "/" + sessionStateScript + " " + argument
    }

    struct InstallError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    struct Report {
        var scriptsDir: String
        var settingsChanged: Bool
        var replacedStatusLine: String?
        var backupPath: String?
        var jqFound: Bool
    }

    enum Status {
        case notInstalled // scripts or settings wiring missing
        case outdated     // wired up, but installed scripts differ from this build's
        case installed    // wired up, scripts match the bundle
    }

    // Where the bundled scripts live: Resources/claude/ inside the app bundle;
    // SUIT_SCRIPTS_PATH overrides for dev runs outside a bundle (mirrors
    // SUIT_RG_PATH in RipgrepSearch).
    static func bundledScriptsDirectory() -> String? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["SUIT_SCRIPTS_PATH"],
           fm.fileExists(atPath: env + "/" + statuslineScript) {
            return env
        }
        if let resourcePath = Bundle.main.resourcePath {
            let dir = resourcePath + "/claude"
            if fm.fileExists(atPath: dir + "/" + statuslineScript) {
                return dir
            }
        }
        return nil
    }

    static func status() -> Status {
        let fm = FileManager.default
        guard let root = readSettings() else { return .notInstalled }
        guard let statusLine = root["statusLine"] as? [String: Any],
              (statusLine["command"] as? String)?.contains(statuslineScript) == true else {
            return .notInstalled
        }
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, argument) in hookEvents {
            let entries = hooks[event] as? [[String: Any]] ?? []
            let wired = entries.contains { entry in
                (entry["hooks"] as? [[String: Any]] ?? []).contains {
                    ($0["command"] as? String)?.contains(sessionStateScript + " " + argument) == true
                }
            }
            if !wired { return .notInstalled }
        }
        for name in scriptNames where !fm.isExecutableFile(atPath: installDir + "/" + name) {
            return .notInstalled
        }
        if let bundled = bundledScriptsDirectory() {
            for name in scriptNames
            where fm.contents(atPath: bundled + "/" + name) != fm.contents(atPath: installDir + "/" + name) {
                return .outdated
            }
        }
        return .installed
    }

    // The user's current statusLine command when it isn't ours — surfaced in
    // the confirmation dialog since installing will replace it.
    static func existingForeignStatusLine() -> String? {
        guard let root = readSettings(),
              let statusLine = root["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String,
              !command.isEmpty, !command.contains("suit-statusline") else { return nil }
        return command
    }

    static func install() throws -> Report {
        let fm = FileManager.default
        guard let bundled = bundledScriptsDirectory() else {
            throw InstallError(
                "The integration scripts were not found in the app's Resources. "
                + "Rebuild the app (build.sh bundles scripts/claude/) or set SUIT_SCRIPTS_PATH for dev runs."
            )
        }

        try fm.createDirectory(atPath: installDir, withIntermediateDirectories: true)
        for name in scriptNames {
            let source = bundled + "/" + name
            guard let data = fm.contents(atPath: source) else {
                throw InstallError("Cannot read bundled script at \(source).")
            }
            let destination = installDir + "/" + name
            try data.write(to: URL(fileURLWithPath: destination), options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination)
        }

        var root: [String: Any] = [:]
        let hadSettingsFile = fm.fileExists(atPath: settingsPath)
        if hadSettingsFile {
            guard let parsed = readSettings() else {
                throw InstallError(
                    "\(settingsPath) exists but is not a JSON object — fix or remove it, then install again. "
                    + "(The scripts were copied; the settings file was not touched.)"
                )
            }
            root = parsed
        }

        let (merged, changed, replacedStatusLine) = merge(into: root)
        var backupPath: String?
        if changed {
            try fm.createDirectory(
                atPath: (settingsPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            // One backup of the pre-Suit file; later reinstalls must not
            // overwrite it with an already-modified copy.
            if hadSettingsFile {
                let candidate = settingsPath + ".suit-backup"
                if !fm.fileExists(atPath: candidate) {
                    try fm.copyItem(atPath: settingsPath, toPath: candidate)
                    backupPath = candidate
                }
            }
            let data = try JSONSerialization.data(
                withJSONObject: merged,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
        }

        return Report(
            scriptsDir: installDir,
            settingsChanged: changed,
            replacedStatusLine: replacedStatusLine,
            backupPath: backupPath,
            jqFound: jqInstalled()
        )
    }

    // MARK: - Internals

    private static func readSettings() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let parsed = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return parsed as? [String: Any]
    }

    private static func merge(into original: [String: Any]) -> (merged: [String: Any], changed: Bool, replacedStatusLine: String?) {
        var root = original
        var changed = false
        var replacedStatusLine: String?

        let existingCommand = (root["statusLine"] as? [String: Any])?["command"] as? String ?? ""
        if existingCommand != statuslineCommand {
            if !existingCommand.isEmpty, !existingCommand.contains("suit-statusline") {
                replacedStatusLine = existingCommand
            }
            root["statusLine"] = ["type": "command", "command": statuslineCommand]
            changed = true
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, argument) in hookEvents {
            let desired = hookCommand(argument)
            var entries = hooks[event] as? [[String: Any]] ?? []
            var found = false
            for (i, entry) in entries.enumerated() {
                var inner = entry["hooks"] as? [[String: Any]] ?? []
                var entryChanged = false
                for (j, hook) in inner.enumerated() {
                    guard let command = hook["command"] as? String,
                          command.contains(sessionStateScript) else { continue }
                    // Ours, possibly pointing at an old location — repoint it,
                    // matching by the state argument so the three don't collapse.
                    guard command.hasSuffix(" " + argument) || command == desired else { continue }
                    found = true
                    if command != desired {
                        var updated = hook
                        updated["command"] = desired
                        inner[j] = updated
                        entryChanged = true
                    }
                }
                if entryChanged {
                    var updatedEntry = entry
                    updatedEntry["hooks"] = inner
                    entries[i] = updatedEntry
                    changed = true
                }
            }
            if !found {
                entries.append(["hooks": [["type": "command", "command": desired]]])
                changed = true
            }
            hooks[event] = entries
        }
        root["hooks"] = hooks

        return (root, changed, replacedStatusLine)
    }

    // The scripts need jq; the app's own PATH is launchd's, so check the usual
    // install locations rather than `command -v`.
    private static func jqInstalled() -> Bool {
        let fm = FileManager.default
        var candidates = ["/opt/homebrew/bin/jq", "/usr/local/bin/jq", "/usr/bin/jq"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { String($0) + "/jq" }
        }
        return candidates.contains { fm.isExecutableFile(atPath: $0) }
    }
}
