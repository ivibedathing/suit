import Foundation

// rtk output-compression hook — the pure, UI-free, standalone-compilable core
// (the RoadmapParser / Recipes / FeedbackRouting pattern; verified by
// scripts/rtk-test.sh). rtk ("Rust Token Killer") rewrites a Bash command so
// its output is filtered down to the salient part (test failures only, build
// errors only, trimmed git/ls/grep) before it ever reaches the model's context
// window — the same mechanism Headroom installs, adapted to Suit's own hook
// installer. This core owns only the ~/.claude/settings.json transform: it adds
// and removes a single PreToolUse hook matching the Bash tool, idempotently,
// touching nothing else in the file. The Settings toggle (off by default) drives
// it; the bundled scripts/claude/suit-rtk-rewrite.sh does the actual rewrite and
// fails open (runs the original command) whenever rtk is absent or errors.
enum RtkHook {

    static let rewriteScript = "suit-rtk-rewrite.sh"

    // $HOME rather than NSHomeDirectory() so tests can point everything at a
    // scratch home (matches ClaudeIntegration).
    static var home: String {
        ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    }
    // The rewrite script installs alongside the other Suit hook scripts.
    static var installDir: String { home + "/.suit/scripts" }
    static var settingsPath: String { home + "/.claude/settings.json" }

    static var hookCommand: String { installDir + "/" + rewriteScript }

    // A PreToolUse hook is matched by tool name; rtk only compresses shell output.
    private static let matcher = "Bash"
    private static let event = "PreToolUse"

    // Does this settings dict already carry our rtk PreToolUse hook? Matched by
    // the script name so a hook pointing at an old install location still counts.
    static func isWired(in root: [String: Any]) -> Bool {
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        let entries = hooks[event] as? [[String: Any]] ?? []
        return entries.contains { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).contains {
                ($0["command"] as? String)?.contains(rewriteScript) == true
            }
        }
    }

    // Add the rtk PreToolUse hook, preserving every other key and hook. Repoints
    // an existing rtk hook at the current command if it drifted. Returns the new
    // dict and whether anything changed (idempotent: a no-op reports false).
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
                guard (hook["command"] as? String)?.contains(rewriteScript) == true else { continue }
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

    // Remove only our rtk PreToolUse hook — drops matching command hooks, prunes
    // any entry left with no hooks, and clears the PreToolUse array / hooks map if
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
                ($0["command"] as? String)?.contains(rewriteScript) != true
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

    // The bundled rewrite script: Resources/claude/ in the app bundle, or
    // SUIT_SCRIPTS_PATH for dev runs (mirrors ClaudeIntegration).
    static func bundledRewriteScript() -> String? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["SUIT_SCRIPTS_PATH"],
           fm.fileExists(atPath: env + "/" + rewriteScript) {
            return env + "/" + rewriteScript
        }
        if let resourcePath = Bundle.main.resourcePath {
            let path = resourcePath + "/claude/" + rewriteScript
            if fm.fileExists(atPath: path) { return path }
        }
        return nil
    }

    // The bundled rtk binary, if this build shipped one. SUIT_RTK_PATH overrides
    // for dev runs (mirrors SUIT_RG_PATH). Optional: when absent the installed
    // hook falls back to `rtk` on the login PATH, and passes commands through
    // untouched if that is missing too.
    static func bundledRtkBinary() -> String? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["SUIT_RTK_PATH"],
           fm.isExecutableFile(atPath: env) {
            return env
        }
        if let resourcePath = Bundle.main.resourcePath {
            let path = resourcePath + "/rtk"
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    // Install (enabled) or remove (disabled) the rtk PreToolUse hook. Enabling
    // copies the bundled rewrite script (and rtk binary, if shipped) into
    // ~/.suit/scripts/ and merges the hook into settings.json, backing the file
    // up once first. Disabling strips just our hook, leaving the scripts and
    // every other setting in place. Returns whether settings.json changed.
    @discardableResult
    static func setEnabled(_ enabled: Bool) throws -> Bool {
        let fm = FileManager.default

        if enabled {
            guard let source = bundledRewriteScript() else {
                throw InstallError(
                    "The rtk rewrite script was not found in the app's Resources. "
                    + "Rebuild the app (build.sh bundles scripts/claude/) or set SUIT_SCRIPTS_PATH for dev runs."
                )
            }
            try fm.createDirectory(atPath: installDir, withIntermediateDirectories: true)
            guard let data = fm.contents(atPath: source) else {
                throw InstallError("Cannot read the bundled rtk rewrite script at \(source).")
            }
            let destination = installDir + "/" + rewriteScript
            try data.write(to: URL(fileURLWithPath: destination), options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination)

            // Ship rtk alongside the hook when this build bundled it, so the hook
            // works without the user putting rtk on their PATH.
            if let rtk = bundledRtkBinary(), let bin = fm.contents(atPath: rtk) {
                let dest = installDir + "/rtk"
                try? bin.write(to: URL(fileURLWithPath: dest), options: .atomic)
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest)
            }
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

    // Is rtk reachable — bundled, already installed alongside the hook, in a
    // common install location, or on the app's PATH? The app's PATH is launchd's
    // (not a login shell's), so probe the usual spots too, like jqInstalled.
    static func rtkAvailable() -> Bool {
        let fm = FileManager.default
        if bundledRtkBinary() != nil { return true }
        var candidates = [
            installDir + "/rtk",
            "/opt/homebrew/bin/rtk",
            "/usr/local/bin/rtk",
            home + "/.cargo/bin/rtk",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { String($0) + "/rtk" }
        }
        return candidates.contains { fm.isExecutableFile(atPath: $0) }
    }

    private static func readSettings() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let parsed = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return parsed as? [String: Any]
    }
}
