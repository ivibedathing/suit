import Cocoa

// One-shot, deadline-bounded scanner for ssh's password prompt in the pty
// output stream. Chunk-boundary-safe: a tail of the previous chunk is carried
// so "…passw" + "ord: " still matches. The match is anchored at the end of
// the buffer (only spaces/CR may follow the colon) — a prompt is where output
// stops and waits, so `cat`ing a file that merely contains "password:" keeps
// scrolling text after it and never fires.
final class SSHAutoAuth {
    // "assword" covers "Password:" and "user@host's password:"; bytes are
    // ASCII-case-folded before matching.
    private static let pattern = Array("assword".utf8)

    private var tail: [UInt8] = []
    private var deadline: Date?
    private var fired = false

    // Fetches the Keychain password and types it; set by SSHPaneContent.
    var onPrompt: (() -> Void)?

    // One attempt per arm: a wrong stored password means ssh re-prompts and
    // the user types — no retry loop hammering the server.
    func arm(timeout: TimeInterval = 90) {
        deadline = Date().addingTimeInterval(timeout)
        fired = false
        tail = []
    }

    func disarm() {
        deadline = nil
        tail = []
    }

    // Called from PaneTerminalView.outputSniffer on the main queue.
    func scan(_ slice: ArraySlice<UInt8>) {
        guard !fired, let deadline else { return }
        guard Date() <= deadline else { disarm(); return }

        var buffer = tail
        buffer.reserveCapacity(buffer.count + slice.count)
        for byte in slice {
            buffer.append((65...90).contains(byte) ? byte + 32 : byte)
        }

        if let end = Self.promptEnd(in: buffer),
           buffer[end...].allSatisfy({ $0 == 0x20 || $0 == 0x0D }) {
            fired = true
            disarm()
            // Never send from inside SwiftTerm's feed path.
            DispatchQueue.main.async { [onPrompt] in onPrompt?() }
            return
        }
        tail = Array(buffer.suffix(Self.pattern.count + 1))
    }

    // Index just past the ':' of the last "assword:" occurrence, or nil.
    private static func promptEnd(in buffer: [UInt8]) -> Int? {
        let colon = UInt8(ascii: ":")
        guard buffer.count > pattern.count else { return nil }
        for start in stride(from: buffer.count - pattern.count - 1, through: 0, by: -1) {
            if buffer[start..<(start + pattern.count)].elementsEqual(pattern),
               buffer[start + pattern.count] == colon {
                return start + pattern.count + 1
            }
        }
        return nil
    }
}

// A terminal tab bound to a saved SSH host: a normal local shell that types
// the ssh command itself, plus hands-free password auth for .password hosts
// (the password is fetched from the Keychain at prompt time and written raw
// to the pty — echo is off at the prompt, so it never appears in scrollback,
// and it never touches saved state or logs).
final class SSHPaneContent: TerminalPaneContent {
    // A value copy: deleting the host from the store never breaks a live tab.
    let sshHost: SSHHost
    private let autoAuth = SSHAutoAuth()

    init(host: SSHHost) {
        sshHost = host
        super.init()
    }

    override var defaultTitle: String { sshHost.displayName }

    // Fresh connect (clicking the host): the shell needs a beat to finish its
    // rc files before typed input lands cleanly — same delay startClaudeTask
    // uses — then the command is submitted and the matcher armed.
    func connect() {
        installAutoAuth()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.terminalView.send(txt: sshCommand(for: self.sshHost) + "\r")
            if self.sshHost.auth == .password {
                self.autoAuth.arm()
            }
        }
    }

    // Restore / ⇧⌘T reopen: pre-type the command *without* submitting, so app
    // launch never reconnects to servers by surprise. The matcher arms only
    // when the user commits the line (CR), however much later that is.
    func prepareReconnect() {
        installAutoAuth()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.terminalView.send(txt: sshCommand(for: self.sshHost))
            if self.sshHost.auth == .password {
                self.terminalView.userReturnHook = { [weak self] in
                    self?.autoAuth.arm()
                }
            }
        }
    }

    private func installAutoAuth() {
        terminalView.outputSniffer = { [weak self] slice in
            self?.autoAuth.scan(slice)
        }
        autoAuth.onPrompt = { [weak self] in
            guard let self,
                  let password = SSHKeychain.password(forHostId: self.sshHost.id) else { return }
            // Raw write, no bracketed paste — readpassphrase wants plain bytes.
            self.terminalView.send(txt: password + "\r")
        }
    }

    override func processTerminated(source: TerminalView, exitCode: Int32?) {
        autoAuth.disarm()
        super.processTerminated(source: source, exitCode: exitCode)
    }

    override func teardown() {
        autoAuth.disarm()
        super.teardown()
    }
}
