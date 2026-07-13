import Foundation

// PostToolUse output filtering — the pure, UI-free, standalone-compilable core
// (the RtkHook pattern; verified by scripts/posttool-test.sh). Where the rtk
// PreToolUse hook compresses Bash output by rewriting the command, this hook
// works on the other side of a tool call: a Claude Code PostToolUse hook
// (suit-posttool-filter.sh) rewrites the tool's *result* via
// hookSpecificOutput.updatedToolOutput (Claude Code ≥ 2.1.133) — reaching the
// built-in Read/Grep/Glob results rtk never sees. Two Settings toggles share
// the one script and the one hook entry, encoded as command-line flags
// (--compress elides giant results, --dedup stubs re-reads of unchanged
// files), because matching hooks for an event run in parallel and two
// independent rewriters for the same Read would race. Dedup additionally needs
// PreCompact (clear the session's read cache — post-compact, "already in this
// conversation" would be a lie) and SessionEnd (delete it) entries, managed
// here too. This core owns only the ~/.claude/settings.json transform,
// idempotently, touching nothing else in the file.
enum PostToolHook {

    static let filterScript = "suit-posttool-filter.sh"

    // $HOME rather than NSHomeDirectory() so tests can point everything at a
    // scratch home (matches RtkHook / ClaudeIntegration).
    static var home: String {
        ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    }
    static var installDir: String { home + "/.suit/scripts" }
    static var settingsPath: String { home + "/.claude/settings.json" }

    static var scriptPath: String { installDir + "/" + filterScript }

    // The one PostToolUse entry covers every tool the filter understands; the
    // script itself decides per tool and size whether to touch a result.
    private static let matcher = "Read|Grep|Glob|Bash"

    // The desired command line for the current toggle state, nil when both
    // toggles are off (the whole hook set is then removed).
    static func filterCommand(compress: Bool, dedup: Bool) -> String? {
        var flags: [String] = []
        if compress { flags.append("--compress") }
        if dedup { flags.append("--dedup") }
        guard !flags.isEmpty else { return nil }
        return scriptPath + " " + flags.joined(separator: " ")
    }

    // Does this settings dict carry any of our hook entries? Matched by the
    // script name so a hook pointing at an old install location still counts.
    static func isWired(in root: [String: Any]) -> Bool {
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        return hooks.values.contains { entries in
            ((entries as? [[String: Any]]) ?? []).contains { entry in
                (entry["hooks"] as? [[String: Any]] ?? []).contains {
                    ($0["command"] as? String)?.contains(filterScript) == true
                }
            }
        }
    }

    // Rewrite the settings dict to the desired state for the given toggles:
    // one PostToolUse entry (flags encoding which behaviors run), plus
    // PreCompact + SessionEnd cache-lifecycle entries when dedup is on. An
    // existing entry is repointed in place (drifted path or changed flags);
    // events whose entry is no longer desired lose exactly ours. Idempotent:
    // a no-op reports changed == false. Everything foreign is preserved.
    static func applying(to root: [String: Any], compress: Bool, dedup: Bool)
        -> (root: [String: Any], changed: Bool) {
        let filter = filterCommand(compress: compress, dedup: dedup)
        // event → (desired command for ours, matcher for a fresh entry)
        let desired: [String: (command: String?, matcher: String?)] = [
            "PostToolUse": (filter, matcher),
            "PreCompact": (dedup ? scriptPath + " --clear-cache" : nil, nil),
            "SessionEnd": (dedup ? scriptPath + " --end-session" : nil, nil),
        ]

        var out = root
        var hooks = out["hooks"] as? [String: Any] ?? [:]
        var changed = false

        for (event, want) in desired {
            var entries = hooks[event] as? [[String: Any]] ?? []
            var found = false
            var kept: [[String: Any]] = []
            for entry in entries {
                var inner = entry["hooks"] as? [[String: Any]] ?? []
                var entryChanged = false
                var innerKept: [[String: Any]] = []
                for hook in inner {
                    guard (hook["command"] as? String)?.contains(filterScript) == true else {
                        innerKept.append(hook)
                        continue
                    }
                    guard let command = want.command else {
                        // No longer desired for this event — drop ours.
                        entryChanged = true
                        continue
                    }
                    found = true
                    if (hook["command"] as? String) != command {
                        var updated = hook
                        updated["command"] = command
                        innerKept.append(updated)
                        entryChanged = true
                    } else {
                        innerKept.append(hook)
                    }
                }
                inner = innerKept
                if entryChanged { changed = true }
                if inner.isEmpty { continue } // entry existed only for our hook
                var updatedEntry = entry
                updatedEntry["hooks"] = inner
                kept.append(updatedEntry)
            }
            entries = kept
            if let command = want.command, !found {
                var entry: [String: Any] = ["hooks": [["type": "command", "command": command]]]
                if let matcher = want.matcher { entry["matcher"] = matcher }
                entries.append(entry)
                changed = true
            }
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }

        if hooks.isEmpty {
            out.removeValue(forKey: "hooks")
        } else {
            out["hooks"] = hooks
        }
        return (out, changed)
    }

    // MARK: - IO (app-side; the harness only exercises the pure transform above)

    struct InstallError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // The bundled filter script: Resources/claude/ in the app bundle, or
    // SUIT_SCRIPTS_PATH for dev runs (mirrors RtkHook).
    static func bundledFilterScript() -> String? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["SUIT_SCRIPTS_PATH"],
           fm.fileExists(atPath: env + "/" + filterScript) {
            return env + "/" + filterScript
        }
        if let resourcePath = Bundle.main.resourcePath {
            let path = resourcePath + "/claude/" + filterScript
            if fm.fileExists(atPath: path) { return path }
        }
        return nil
    }

    // Reconcile settings.json (and the installed script) with the two toggles.
    // Either toggle on copies the bundled script into ~/.suit/scripts/ and
    // merges the desired hook entries, backing settings.json up once first
    // (shared with ClaudeIntegration's backup). Both off strips exactly our
    // entries, leaving the script and every other setting in place. Returns
    // whether settings.json changed.
    @discardableResult
    static func setEnabled(compress: Bool, dedup: Bool) throws -> Bool {
        let fm = FileManager.default

        if compress || dedup {
            guard let source = bundledFilterScript() else {
                throw InstallError(
                    "The post-tool filter script was not found in the app's Resources. "
                    + "Rebuild the app (build.sh bundles scripts/claude/) or set SUIT_SCRIPTS_PATH for dev runs."
                )
            }
            try fm.createDirectory(atPath: installDir, withIntermediateDirectories: true)
            guard let data = fm.contents(atPath: source) else {
                throw InstallError("Cannot read the bundled post-tool filter script at \(source).")
            }
            try data.write(to: URL(fileURLWithPath: scriptPath), options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        }

        let root = readSettings() ?? [:]
        let (updated, changed) = applying(to: root, compress: compress, dedup: dedup)
        guard changed else { return false }

        try fm.createDirectory(
            atPath: (settingsPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
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
