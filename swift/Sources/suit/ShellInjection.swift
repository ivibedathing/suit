import Foundation

// run_silent shell helpers — the pure, UI-free, standalone-compilable core
// (the RtkHook pattern; verified by scripts/shell-extras-test.sh). When the
// Settings ▸ Claude toggle is on, Suit launches its zsh terminals with a
// ZDOTDIR shim (the VS Code shell-integration mechanism): zsh reads
// ~/.suit/zsh/.zshenv → .zshrc etc., each of which sources the user's real
// counterpart first and then loads suit-shell-extras.zsh — defining
// `run_silent` (buffer a command's output; print "✓ cmd (Ns)" on success,
// everything on failure), the shape that keeps green build/test output out of
// a Claude session's context window. Fully reversible: the toggle only stops
// setting the env vars; nothing in $HOME is ever touched. Applies only to
// terminals Suit launches, only when the configured shell is zsh — anything
// else launches exactly as before (environment: nil).
enum ShellInjection {

    static let extrasScript = "suit-shell-extras.zsh"
    static let zdotdirFiles = [".zshenv", ".zprofile", ".zshrc", ".zlogin"]

    // $HOME rather than NSHomeDirectory() so tests can point everything at a
    // scratch home (matches RtkHook / ClaudeIntegration).
    static var home: String {
        ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    }
    static var zdotdir: String { home + "/.suit/zsh" }
    static var scriptsDir: String { home + "/.suit/scripts" }
    static var extrasPath: String { scriptsDir + "/" + extrasScript }

    // Build the child environment for a terminal launch, or nil for "launch
    // exactly as today" (toggle off, or a non-zsh shell). `base` is the
    // caller's default env array (SwiftTerm's, in the app); any ZDOTDIR
    // already in it is captured into SUIT_USER_ZDOTDIR so the shim still
    // finds and sources the user's real config chain.
    static func environment(base: [String], enabled: Bool,
                            shellPath: String, home: String) -> [String]? {
        guard enabled else { return nil }
        guard (shellPath as NSString).lastPathComponent == "zsh" else { return nil }

        let shimDir = home + "/.suit/zsh"
        var userZdotdir = home
        var out: [String] = []
        for entry in base {
            if entry.hasPrefix("ZDOTDIR=") {
                let value = String(entry.dropFirst("ZDOTDIR=".count))
                if !value.isEmpty, value != shimDir { userZdotdir = value }
                continue // replaced by the shim's ZDOTDIR below
            }
            out.append(entry)
        }
        out.append("ZDOTDIR=" + shimDir)
        out.append("SUIT_USER_ZDOTDIR=" + userZdotdir)
        out.append("SUIT_SHELL_EXTRAS=" + home + "/.suit/scripts/" + extrasScript)
        return out
    }

    // MARK: - IO (app-side; the harness only exercises the pure logic above)

    struct InstallError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // The bundled shim + extras: Resources/claude/ in the app bundle, or
    // SUIT_SCRIPTS_PATH for dev runs (mirrors RtkHook).
    static func bundledSource(_ name: String, subdir: String = "") -> String? {
        let fm = FileManager.default
        let rel = subdir.isEmpty ? name : subdir + "/" + name
        if let env = ProcessInfo.processInfo.environment["SUIT_SCRIPTS_PATH"],
           fm.fileExists(atPath: env + "/" + rel) {
            return env + "/" + rel
        }
        if let resourcePath = Bundle.main.resourcePath {
            let path = resourcePath + "/claude/" + rel
            if fm.fileExists(atPath: path) { return path }
        }
        return nil
    }

    // Copy the shim files into ~/.suit/zsh/ and the extras script into
    // ~/.suit/scripts/. Idempotent (plain overwrite, atomic); nothing in the
    // user's own dotfiles is read or written. Runs when the toggle turns on —
    // the env vars only ever point at files this owns.
    static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: zdotdir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: scriptsDir, withIntermediateDirectories: true)

        for name in zdotdirFiles {
            guard let source = bundledSource(name, subdir: "suit-zdotdir") else {
                throw InstallError(
                    "The Suit zsh shim file \(name) was not found in the app's Resources. "
                    + "Rebuild the app (build.sh bundles scripts/claude/suit-zdotdir/) or set SUIT_SCRIPTS_PATH for dev runs."
                )
            }
            guard let data = fm.contents(atPath: source) else {
                throw InstallError("Cannot read the bundled shim file at \(source).")
            }
            try data.write(to: URL(fileURLWithPath: zdotdir + "/" + name), options: .atomic)
        }

        guard let source = bundledSource(extrasScript) else {
            throw InstallError("The shell extras script was not found in the app's Resources.")
        }
        guard let data = fm.contents(atPath: source) else {
            throw InstallError("Cannot read the bundled extras script at \(source).")
        }
        try data.write(to: URL(fileURLWithPath: extrasPath), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: extrasPath)

        // The CLAUDE.md snippet doc the Settings hint points at — best-effort.
        if let doc = bundledSource("SUIT-SHELL-EXTRAS.md"),
           let docData = fm.contents(atPath: doc) {
            try? docData.write(
                to: URL(fileURLWithPath: scriptsDir + "/SUIT-SHELL-EXTRAS.md"),
                options: .atomic
            )
        }
    }
}
