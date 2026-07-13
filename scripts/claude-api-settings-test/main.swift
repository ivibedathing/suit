import Foundation

// Standalone assertion driver for the Claude API settings core, compiled
// against swift/Sources/suit/ClaudeAPISettings.swift (Foundation-only) by
// scripts/claude-api-settings-test.sh. Asserts the properties the Settings
// pane depends on: defaults leave the launch command untouched, each knob
// emits exactly its documented variable, values are pty-safe (newlines
// flattened) and zsh-safe (single-quoted, embedded quotes spliced), and the
// free-form extra-env field parses strictly and overrides the structured knobs.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

// MARK: - Defaults pass through untouched

print("== defaults ==")
do {
    let api = ClaudeAPISettings()
    check(api.isDefault, "a fresh settings struct is default")
    check(api.environmentAssignments().isEmpty, "defaults emit no assignments")
    check(api.launchCommand(base: "claude") == "claude", "defaults leave the bare command untouched")
    check(api.launchCommand(base: "claude --continue") == "claude --continue",
          "defaults leave a command with args untouched")
}

// MARK: - Each knob emits its documented variable

print("== knob → variable mapping ==")
do {
    var api = ClaudeAPISettings()
    api.model = "opus"
    check(api.launchCommand(base: "claude") == "ANTHROPIC_MODEL='opus' claude",
          "model → ANTHROPIC_MODEL prefix")
    check(!api.isDefault, "a set knob makes the struct non-default")

    api = ClaudeAPISettings()
    api.subagentModel = "haiku"
    check(api.environmentAssignments().first! == ("CLAUDE_CODE_SUBAGENT_MODEL", "haiku"),
          "subagent model → CLAUDE_CODE_SUBAGENT_MODEL")

    api = ClaudeAPISettings()
    api.effort = "xhigh"
    check(api.environmentAssignments().first! == ("CLAUDE_CODE_EFFORT_LEVEL", "xhigh"),
          "effort → CLAUDE_CODE_EFFORT_LEVEL")

    api = ClaudeAPISettings()
    api.thinkingTokens = 8000
    check(api.environmentAssignments().first! == ("MAX_THINKING_TOKENS", "8000"),
          "thinking tokens → MAX_THINKING_TOKENS")

    api = ClaudeAPISettings()
    api.maxOutputTokens = 16000
    check(api.environmentAssignments().first! == ("CLAUDE_CODE_MAX_OUTPUT_TOKENS", "16000"),
          "max output tokens → CLAUDE_CODE_MAX_OUTPUT_TOKENS")

    api = ClaudeAPISettings()
    api.promptCachingEnabled = false
    check(api.environmentAssignments().first! == ("DISABLE_PROMPT_CACHING", "1"),
          "caching off → DISABLE_PROMPT_CACHING=1")

    api = ClaudeAPISettings()
    api.promptCachingEnabled = true
    check(api.environmentAssignments().isEmpty, "caching on (the default) emits nothing")

    api = ClaudeAPISettings()
    api.customHeaders = "anthropic-beta: fast-mode-2026-02-01"
    check(api.environmentAssignments().first! == ("ANTHROPIC_CUSTOM_HEADERS", "anthropic-beta: fast-mode-2026-02-01"),
          "custom headers → ANTHROPIC_CUSTOM_HEADERS")

    api = ClaudeAPISettings()
    api.thinkingTokens = 0
    api.maxOutputTokens = 0
    check(api.environmentAssignments().isEmpty, "zero token counts mean default, not env=0")
}

// MARK: - Composition order and full command

print("== composition ==")
do {
    var api = ClaudeAPISettings()
    api.model = "opus"
    api.effort = "low"
    api.promptCachingEnabled = false
    let command = api.launchCommand(base: "claude --continue")
    check(command == "ANTHROPIC_MODEL='opus' CLAUDE_CODE_EFFORT_LEVEL='low' DISABLE_PROMPT_CACHING='1' claude --continue",
          "multiple knobs compose in declaration order before the base command")
}

// MARK: - Quoting and pty safety

print("== quoting ==")
do {
    check(ClaudeAPISettings.shellQuote("plain") == "'plain'", "plain value single-quoted")
    check(ClaudeAPISettings.shellQuote("has space") == "'has space'", "spaces survive inside quotes")
    check(ClaudeAPISettings.shellQuote("it's") == "'it'\\''s'", "embedded single quote spliced as '\\''")
    check(ClaudeAPISettings.shellQuote("a\nb") == "'a b'", "newline flattened to a space (pty-typed command)")
    check(ClaudeAPISettings.sanitize("  x\r\ny  ") == "x  y", "sanitize trims ends and flattens CR/LF")

    var api = ClaudeAPISettings()
    api.model = "weird'model"
    check(api.launchCommand(base: "claude") == "ANTHROPIC_MODEL='weird'\\''model' claude",
          "a value with a quote still yields one well-formed assignment")

    api = ClaudeAPISettings()
    api.model = "\n"
    check(api.environmentAssignments().isEmpty, "a whitespace-only value emits nothing")
}

// MARK: - Extra env parsing

print("== extra env ==")
do {
    let pairs = ClaudeAPISettings.parseExtraEnv("FOO=1  BAR=two\tBAZ=a=b")
    check(pairs.count == 3, "three valid tokens parse")
    check(pairs[0] == ("FOO", "1") && pairs[1] == ("BAR", "two"), "keys and values split on the first =")
    check(pairs[2] == ("BAZ", "a=b"), "later = signs stay in the value")

    check(ClaudeAPISettings.parseExtraEnv("novalue FOO= =bar 2BAD=x").isEmpty,
          "tokens without =, empty values, empty keys, and digit-led keys are dropped")
    check(ClaudeAPISettings.parseExtraEnv("_OK=1").count == 1, "underscore-led key is valid")
    check(ClaudeAPISettings.parseExtraEnv("").isEmpty, "empty field parses to nothing")

    check(ClaudeAPISettings.isValidEnvKey("MAX_MCP_OUTPUT_TOKENS"), "typical env key validates")
    check(!ClaudeAPISettings.isValidEnvKey("BAD-KEY"), "dash rejected")
    check(!ClaudeAPISettings.isValidEnvKey(""), "empty key rejected")
}

// MARK: - Extra env overrides the structured knobs

print("== extra env override ==")
do {
    var api = ClaudeAPISettings()
    api.model = "opus"
    api.extraEnv = "ANTHROPIC_MODEL=sonnet MAX_MCP_OUTPUT_TOKENS=2048"
    let assignments = api.environmentAssignments()
    check(assignments.count == 2, "override replaces rather than duplicates")
    check(assignments[0] == ("ANTHROPIC_MODEL", "sonnet"), "extra env wins over the structured knob, in place")
    check(assignments[1] == ("MAX_MCP_OUTPUT_TOKENS", "2048"), "novel extra keys append last")
}

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
