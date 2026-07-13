import Foundation

// The Settings → Claude API pane's model: per-launch Anthropic API tuning for
// Claude Code sessions started from Suit (✦ quick launch, tasks, recipes,
// review passes). Each knob maps to a documented Claude Code environment
// variable; the composed `KEY='value' claude …` prefix is typed into the
// session's zsh, so it applies to that session only and stays visible in the
// terminal — a playground, not hidden state. Autopilot workers are deliberately
// left alone (they have their own Arguments setting, and autonomous runs
// shouldn't silently inherit experiments).
//
// Foundation-only on purpose (the FavoritesStore/RoadmapParser pattern): the
// composition and parsing logic here is exercised by
// scripts/claude-api-settings-test.sh with no app dependencies.
struct ClaudeAPISettings: Equatable {
    /// ANTHROPIC_MODEL — main-loop model override ("" = account default).
    var model = ""
    /// CLAUDE_CODE_SUBAGENT_MODEL — model for Task-tool subagents.
    var subagentModel = ""
    /// CLAUDE_CODE_EFFORT_LEVEL — reasoning effort ("" = default).
    var effort = ""
    /// MAX_THINKING_TOKENS — thinking budget (0 = model default).
    var thinkingTokens = 0
    /// CLAUDE_CODE_MAX_OUTPUT_TOKENS — per-response output cap (0 = default).
    var maxOutputTokens = 0
    /// Prompt caching; off adds DISABLE_PROMPT_CACHING=1 (full-price tokens —
    /// only useful for cost A/B experiments).
    var promptCachingEnabled = true
    /// ANTHROPIC_CUSTOM_HEADERS — e.g. an anthropic-beta header line.
    var customHeaders = ""
    /// Free-form KEY=VALUE pairs (space-separated) appended last, so they can
    /// override the structured knobs or set variables this pane doesn't cover.
    var extraEnv = ""

    /// True when every knob is at its default — launch commands pass through
    /// untouched, so existing users see zero change until they opt in.
    var isDefault: Bool { self == ClaudeAPISettings() }

    /// The CLAUDE_CODE_EFFORT_LEVEL values Claude Code documents, in cost
    /// order. The Settings popup shows "Default" + these; "" means unset.
    static let effortLevels = ["low", "medium", "high", "xhigh", "max"]

    /// The ordered KEY=VALUE assignments this configuration implies. Extra-env
    /// pairs land last and replace an earlier assignment of the same key (the
    /// override semantics a shell would give a later assignment anyway, minus
    /// the duplicate noise in the echoed command).
    func environmentAssignments() -> [(key: String, value: String)] {
        var assignments: [(key: String, value: String)] = []
        func add(_ key: String, _ value: String) {
            let clean = Self.sanitize(value)
            guard !clean.isEmpty else { return }
            assignments.append((key, clean))
        }
        add("ANTHROPIC_MODEL", model)
        add("CLAUDE_CODE_SUBAGENT_MODEL", subagentModel)
        add("CLAUDE_CODE_EFFORT_LEVEL", effort)
        if thinkingTokens > 0 { add("MAX_THINKING_TOKENS", String(thinkingTokens)) }
        if maxOutputTokens > 0 { add("CLAUDE_CODE_MAX_OUTPUT_TOKENS", String(maxOutputTokens)) }
        if !promptCachingEnabled { add("DISABLE_PROMPT_CACHING", "1") }
        add("ANTHROPIC_CUSTOM_HEADERS", customHeaders)
        for pair in Self.parseExtraEnv(extraEnv) {
            if let index = assignments.firstIndex(where: { $0.key == pair.key }) {
                assignments[index].value = pair.value
            } else {
                assignments.append(pair)
            }
        }
        return assignments
    }

    /// Prefix `base` (e.g. "claude --continue") with the env assignments,
    /// single-quoted for zsh. Defaults return `base` unchanged.
    func launchCommand(base: String) -> String {
        let assignments = environmentAssignments()
        guard !assignments.isEmpty else { return base }
        let prefix = assignments
            .map { "\($0.key)=\(Self.shellQuote($0.value))" }
            .joined(separator: " ")
        return prefix + " " + base
    }

    /// Single-quote a value for the zsh command line ('…' with embedded
    /// single quotes spliced as '\''). Values are newline-stripped first —
    /// the command is typed into a pty, where a newline would submit early.
    static func shellQuote(_ value: String) -> String {
        "'" + sanitize(value).replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Whitespace-separated KEY=VALUE tokens; tokens without "=" or with an
    /// invalid key are dropped (values here can't contain spaces — the
    /// structured fields cover the ones that legitimately do).
    static func parseExtraEnv(_ text: String) -> [(key: String, value: String)] {
        sanitize(text).split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { token in
            let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let key = String(parts[0])
            let value = String(parts[1])
            guard isValidEnvKey(key), !value.isEmpty else { return nil }
            return (key, value)
        }
    }

    /// POSIX env-name shape: [A-Za-z_][A-Za-z0-9_]*.
    static func isValidEnvKey(_ key: String) -> Bool {
        guard let first = key.first, first.isLetter || first == "_" else { return false }
        return key.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" }
    }

    /// Newlines flattened to spaces, ends trimmed — pty-safe field values.
    static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
