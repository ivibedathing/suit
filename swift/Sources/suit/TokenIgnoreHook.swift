import Foundation

// Token-ignore firewall — the pure, UI-free, standalone-compilable core (the
// RtkHook pattern; verified by scripts/token-ignore-test.sh). A repo opts in
// with `.claude/token-ignore` at its root (one root-relative path prefix per
// line) naming directories nobody should read wholesale — vendored
// dependencies, build output, generated code. The bundled
// scripts/claude/suit-token-ignore.sh PreToolUse hook then denies full-file
// Reads under those prefixes (range reads pass), and the PostToolUse
// dispatcher's --ignore flag (PostToolHook) hides Grep/Glob result lines
// there. This core owns only the ~/.claude/settings.json transform for the
// PreToolUse side: it adds and removes a single hook matching the Read tool,
// idempotently, touching nothing else in the file. The Settings toggle (off
// by default) drives both sides together (see tokenIgnoreChanged); the hook
// script fails open whenever jq is absent or anything errors.
enum TokenIgnoreHook {

    static let firewallScript = "suit-token-ignore.sh"

    // $HOME rather than NSHomeDirectory() so tests can point everything at a
    // scratch home (matches RtkHook / ClaudeIntegration).
    static var home: String {
        ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    }
    static var installDir: String { home + "/.suit/scripts" }
    static var settingsPath: String { home + "/.claude/settings.json" }

    static var hookCommand: String { installDir + "/" + firewallScript }

    // Only full-file Reads are firewalled; Grep/Glob results are handled on
    // the PostToolUse side by the dispatcher's --ignore flag.
    private static let matcher = "Read"
    private static let event = "PreToolUse"

    // Does this settings dict already carry our firewall hook? Matched by the
    // script name so a hook pointing at an old install location still counts.
    static func isWired(in root: [String: Any]) -> Bool {
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        let entries = hooks[event] as? [[String: Any]] ?? []
        return entries.contains { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).contains {
                ($0["command"] as? String)?.contains(firewallScript) == true
            }
        }
    }

    // Add the firewall PreToolUse hook, preserving every other key and hook.
    // Repoints an existing entry at the current command if it drifted. Returns
    // the new dict and whether anything changed (idempotent: no-op → false).
    static func adding(to root: [String: Any]) -> (root: [String: Any], changed: Bool) {
        var out = root
        var changed = false
        var hooks = out["hooks"] as? [String: Any] ?? [:]
        var entries = hooks[event] as? [[String: Any]] ?? []

        var found = false
        for (i, entry) in entries.enumerated() {
            var inner = entry["hooks"] as? [[String: Any]] ?? []
            var entryChanged = false
            for (j, hook) in inner.enumerated() {
                guard (hook["command"] as? String)?.contains(firewallScript) == true else { continue }
                found = true
                if (hook["command"] as? String) != hookCommand {
                    var updated = hook
                    updated["command"] = hookCommand
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
            entries.append(["matcher": matcher,
                            "hooks": [["type": "command", "command": hookCommand]]])
            changed = true
        }

        hooks[event] = entries
        out["hooks"] = hooks
        return (out, changed)
    }

    // Remove only our firewall hook — drops matching command hooks, prunes any
    // entry left with no hooks, and clears the PreToolUse array / hooks map if
    // they end up empty. Everything else is untouched.
    static func removing(from root: [String: Any]) -> (root: [String: Any], changed: Bool) {
        var out = root
        guard var hooks = out["hooks"] as? [String: Any],
              var entries = hooks[event] as? [[String: Any]] else {
            return (out, false)
        }
        var changed = false
        var kept: [[String: Any]] = []
        for entry in entries {
            let inner = entry["hooks"] as? [[String: Any]] ?? []
            let filtered = inner.filter {
                ($0["command"] as? String)?.contains(firewallScript) != true
            }
            if filtered.count != inner.count { changed = true }
            if filtered.isEmpty { continue } // entry existed only for our hook
            var updatedEntry = entry
            updatedEntry["hooks"] = filtered
            kept.append(updatedEntry)
        }
        entries = kept

        if !changed { return (out, false) }

        if entries.isEmpty {
            hooks.removeValue(forKey: event)
        } else {
            hooks[event] = entries
        }
        if hooks.isEmpty {
            out.removeValue(forKey: "hooks")
        } else {
            out["hooks"] = hooks
        }
        return (out, true)
    }

    // MARK: - IO (app-side; the harness only exercises the pure transform above)

    struct InstallError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // The bundled firewall script: Resources/claude/ in the app bundle, or
    // SUIT_SCRIPTS_PATH for dev runs (mirrors RtkHook).
    static func bundledFirewallScript() -> String? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["SUIT_SCRIPTS_PATH"],
           fm.fileExists(atPath: env + "/" + firewallScript) {
            return env + "/" + firewallScript
        }
        if let resourcePath = Bundle.main.resourcePath {
            let path = resourcePath + "/claude/" + firewallScript
            if fm.fileExists(atPath: path) { return path }
        }
        return nil
    }

    // Install (enabled) or remove (disabled) the firewall PreToolUse hook.
    // Enabling copies the bundled script into ~/.suit/scripts/ and merges the
    // hook into settings.json, backing the file up once first. Disabling
    // strips just our hook, leaving the script and every other setting in
    // place. Returns whether settings.json changed.
    @discardableResult
    static func setEnabled(_ enabled: Bool) throws -> Bool {
        let fm = FileManager.default

        if enabled {
            guard let source = bundledFirewallScript() else {
                throw InstallError(
                    "The token-ignore firewall script was not found in the app's Resources. "
                    + "Rebuild the app (build.sh bundles scripts/claude/) or set SUIT_SCRIPTS_PATH for dev runs."
                )
            }
            try fm.createDirectory(atPath: installDir, withIntermediateDirectories: true)
            guard let data = fm.contents(atPath: source) else {
                throw InstallError("Cannot read the bundled token-ignore firewall script at \(source).")
            }
            try data.write(to: URL(fileURLWithPath: hookCommand), options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookCommand)
        }

        let root = readSettings() ?? [:]
        let (updated, changed) = enabled ? adding(to: root) : removing(from: root)
        guard changed else { return false }

        try fm.createDirectory(
            atPath: (settingsPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        // One backup of the pre-Suit file, shared with ClaudeIntegration's.
        if fm.fileExists(atPath: settingsPath) {
            let backup = settingsPath + ".suit-backup"
            if !fm.fileExists(atPath: backup) {
                try? fm.copyItem(atPath: settingsPath, toPath: backup)
            }
        }
        let data = try JSONSerialization.data(
            withJSONObject: updated,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
        return true
    }

    private static func readSettings() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let parsed = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return parsed as? [String: Any]
    }
}
