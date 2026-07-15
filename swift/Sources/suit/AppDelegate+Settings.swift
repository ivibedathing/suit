import Cocoa

// The non-appearance settings verbs: every Settings-pane toggle or field that
// isn't visual lands here as a `…Changed` handler — shell path, Claude session
// args and API prefix, task isolation, bells and sounds, auto-compact, and the
// token-filter hooks (rtk / post-tool compress / read-dedup / token-ignore,
// which rewrite ~/.claude/settings.json through their Hook installers).
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

    // Claude API pane: the whole struct commits at once (each control hands in
    // a mutated copy). Values are pty-safe by construction — the composition
    // layer sanitizes again — but trim here so the fields snap back clean.
    func claudeAPIChanged(_ settings: ClaudeAPISettings) {
        var clean = settings
        clean.model = ClaudeAPISettings.sanitize(settings.model)
        clean.subagentModel = ClaudeAPISettings.sanitize(settings.subagentModel)
        clean.effort = ClaudeAPISettings.sanitize(settings.effort)
        clean.customHeaders = ClaudeAPISettings.sanitize(settings.customHeaders)
        clean.extraEnv = ClaudeAPISettings.sanitize(settings.extraEnv)
        clean.thinkingTokens = max(0, settings.thinkingTokens)
        clean.maxOutputTokens = max(0, settings.maxOutputTokens)
        claudeAPI = clean
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

    // Auto-/compact guardrails: the guard reads these live each
    // heartbeat, so a change applies without restarting anything.
    func autoCompactEnabledChanged(_ enabled: Bool) {
        autoCompactEnabled = enabled
        saveSettings()
    }

    func autoCompactThresholdChanged(_ threshold: Int) {
        autoCompactThreshold = threshold
        saveSettings()
    }

    func autoCompactInstructionsChanged(_ instructions: String) {
        autoCompactInstructions = instructions
        saveSettings()
    }

    // Toggle rtk output compression: persist the preference, then install or
    // remove the PreToolUse hook in ~/.claude/settings.json. Best-effort — the
    // preference sticks even if the settings write fails (e.g. the bundled
    // rewrite script isn't found on a dev run); the failure is logged, not fatal.
    func rtkCompressionChanged(_ enabled: Bool) {
        rtkCompressionEnabled = enabled
        saveSettings()
        do {
            _ = try RtkHook.setEnabled(enabled)
        } catch {
            NSLog("Suit: rtk compression \(enabled ? "install" : "removal") failed: \(error.localizedDescription)")
        }
        // The hook fails open, so a missing rtk isn't fatal — but say so plainly
        // rather than letting the toggle look active while nothing compresses.
        if enabled, !RtkHook.rtkAvailable() {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "rtk isn’t installed"
            alert.informativeText = "The hook is installed, but rtk isn’t on your PATH, so commands run unchanged (no compression) until it is. Install rtk (e.g. cargo install rtk, or place it on your PATH) — Suit picks it up automatically, and bundles it when it’s present at build time."
            alert.runModal()
        }
    }

    // PostToolUse output filtering: both toggles reconcile through the one
    // dispatcher hook (PostToolHook), whose command line encodes which
    // behaviors are on. Best-effort like rtkCompressionChanged — the
    // preference sticks even if the settings.json write fails.
    func postToolCompressChanged(_ enabled: Bool) {
        postToolCompressEnabled = enabled
        saveSettings()
        applyPostToolHook()
    }

    func readDedupChanged(_ enabled: Bool) {
        readDedupEnabled = enabled
        saveSettings()
        applyPostToolHook()
    }

    // Token-ignore firewall: one toggle drives both halves — the PreToolUse
    // Read hook (TokenIgnoreHook) and the dispatcher's --ignore flag.
    func tokenIgnoreChanged(_ enabled: Bool) {
        tokenIgnoreEnabled = enabled
        saveSettings()
        do {
            _ = try TokenIgnoreHook.setEnabled(enabled)
        } catch {
            NSLog("Suit: token-ignore firewall \(enabled ? "install" : "removal") failed: \(error.localizedDescription)")
        }
        applyPostToolHook()
    }

    func applyPostToolHook() {
        do {
            _ = try PostToolHook.setEnabled(
                compress: postToolCompressEnabled, dedup: readDedupEnabled,
                ignore: tokenIgnoreEnabled
            )
        } catch {
            NSLog("Suit: post-tool filter reconcile failed: \(error.localizedDescription)")
        }
    }

    // Shell helpers (run_silent): enabling installs the ZDOTDIR shim + extras
    // under ~/.suit/ (never the user's dotfiles); the env vars only go to
    // terminals launched after the change. Disabling just stops setting them —
    // the installed files are inert without the env.
    func shellExtrasChanged(_ enabled: Bool) {
        shellExtrasEnabled = enabled
        saveSettings()
        guard enabled else { return }
        do {
            try ShellInjection.install()
        } catch {
            NSLog("Suit: shell extras install failed: \(error.localizedDescription)")
        }
    }
}
