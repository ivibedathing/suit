import Foundation

// The live slash-command catalog. Claude Code's hidden verbs
// (built-ins, custom ~/.claude/commands/*.md, and skills) become a discoverable
// list the command menu dispatches into a session's pty via SessionControl.send,
// so steering is one tap instead of a typed incantation. Pure and Foundation-only
// so the discovery is verifiable on its own (the AutopilotScheduler pattern).

struct SlashCommand: Equatable {
    enum Source: String { case builtin, custom, skill }

    // The exact string sent into the session's pty, e.g. "/compact".
    let name: String
    let source: Source
    // One-line description for the menu row, best-effort (nil when unknown).
    let detail: String?

    // Palette row label: the command plus its description when we have one.
    var menuTitle: String {
        if let detail, !detail.isEmpty { return "\(name) — \(detail)" }
        return name
    }
}

enum SlashCommandCatalog {
    // The built-ins Claude Code always understands. `/context` and `/compact`
    // pair with the context meter; the rest are the common steering
    // verbs. Curated because the SDK doesn't surface the list in the session
    // file today — custom commands and skills are discovered live below.
    static let builtins: [SlashCommand] = [
        SlashCommand(name: "/context", source: .builtin, detail: "Show context-window usage"),
        SlashCommand(name: "/compact", source: .builtin, detail: "Summarize & shrink the context"),
        SlashCommand(name: "/clear", source: .builtin, detail: "Clear the conversation"),
        SlashCommand(name: "/usage", source: .builtin, detail: "Show plan usage & limits"),
        SlashCommand(name: "/cost", source: .builtin, detail: "Show session cost"),
        SlashCommand(name: "/model", source: .builtin, detail: "Switch model"),
        SlashCommand(name: "/review", source: .builtin, detail: "Review a pull request"),
        SlashCommand(name: "/rewind", source: .builtin, detail: "Rewind to a checkpoint"),
        SlashCommand(name: "/resume", source: .builtin, detail: "Resume a past session"),
        SlashCommand(name: "/help", source: .builtin, detail: "List available commands"),
    ]

    // The full catalog for a session: user-level ~/.claude always, plus the
    // session project's own .claude when the cwd is inside one.
    static func forSession(cwd: String?, home: String? = nil) -> [SlashCommand] {
        let h = home ?? ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        var commandDirs = [h + "/.claude/commands"]
        var skillDirs = [h + "/.claude/skills"]
        if let cwd, let root = nearestClaudeRoot(from: cwd), root != h {
            commandDirs.append(root + "/.claude/commands")
            skillDirs.append(root + "/.claude/skills")
        }
        return discover(commandDirs: commandDirs, skillDirs: skillDirs)
    }

    // Discovers custom commands and skills from the given roots, deduped by
    // command name (built-ins win, then earlier roots). `commandDirs` hold
    // `*.md` command files (name = filename without extension); `skillDirs`
    // hold `<name>/SKILL.md` skill folders (name = folder). Missing dirs are
    // skipped. Built-ins come first, discovered entries alphabetical after.
    static func discover(commandDirs: [String], skillDirs: [String]) -> [SlashCommand] {
        var seen = Set(builtins.map { $0.name })
        var discovered: [SlashCommand] = []
        let fm = FileManager.default

        for dir in commandDirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in entries.sorted() where file.hasSuffix(".md") {
                let base = (file as NSString).deletingPathExtension
                let name = "/" + base
                guard !base.isEmpty, !seen.contains(name) else { continue }
                seen.insert(name)
                discovered.append(SlashCommand(name: name, source: .custom,
                                               detail: description(atPath: dir + "/" + file)))
            }
        }

        for dir in skillDirs {
            guard let subs = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for sub in subs.sorted() {
                let skillFile = dir + "/" + sub + "/SKILL.md"
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: skillFile, isDirectory: &isDir), !isDir.boolValue else { continue }
                let name = "/" + sub
                guard !seen.contains(name) else { continue }
                seen.insert(name)
                discovered.append(SlashCommand(name: name, source: .skill,
                                               detail: description(atPath: skillFile)))
            }
        }

        return builtins + discovered.sorted { $0.name < $1.name }
    }

    // MARK: - Helpers

    // Nearest ancestor of `cwd` (inclusive) holding a `.claude` directory —
    // the project whose commands/skills apply. nil when none up to the root.
    private static func nearestClaudeRoot(from cwd: String) -> String? {
        let fm = FileManager.default
        var dir = cwd
        while true {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir + "/.claude", isDirectory: &isDir), isDir.boolValue {
                return dir
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { return nil }
            dir = parent
        }
    }

    // Best-effort one-line description: the YAML frontmatter `description:` when
    // present (skills always have one), else the first non-blank, non-heading
    // line, trimmed and capped so the palette row stays one line.
    private static func description(atPath path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            for line in lines.dropFirst() {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t == "---" { break }
                if t.lowercased().hasPrefix("description:") {
                    let value = String(t.dropFirst("description:".count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
                    if !value.isEmpty { return capped(value) }
                }
            }
        }

        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t == "---" { continue }
            let stripped = String(t.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty { return capped(stripped) }
        }
        return nil
    }

    private static func capped(_ s: String, _ limit: Int = 80) -> String {
        s.count <= limit ? s : String(s.prefix(limit - 1)) + "…"
    }
}
