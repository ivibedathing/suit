import Foundation

// Typeahead for the window between "the shell process exists" and "the shell
// can edit a line".
//
// A login+interactive zsh with oh-my-zsh, nvm and Powerlevel10k takes ~1.2s to
// reach zle. p10k's *instant prompt* paints a prompt at ~80ms and then runs
// `stty -icanon` while leaving ECHO on, so for the rest of that second the pty
// has no line editor *and* no canonical line buffer: the kernel echoes each
// byte raw. Letters look right, but backspace (DEL, 0x7F) has nothing to erase
// and ECHOCTL prints it literally — which is the `~/Pr/suit ❯ ^?^?^?^?^?` a new
// tab greets you with when you start typing straight away.
//
// The bytes survive (zle picks up the typeahead once it starts), so this is a
// display problem and gets a display fix: hold the keystrokes inside Suit for
// the length of that window, echo them ourselves — backspace included — then
// erase our stand-in echo and hand the whole line to the pty the moment the
// shell's line editor takes over, letting zle render it for real.
//
// The gate deliberately does nothing outside that one state. While the tty is
// still canonical the driver's own erase handling is correct, and once ECHO is
// off someone (zle, a password prompt, a full-screen app) is reading properly —
// see `ShellWarmupMode`. Foundation-only, no pty or AppKit dependency, so
// scripts/shell-warmup-test.sh can drive it; PaneTerminalView owns the tty-mode
// polling that arms and releases it.

// What the pty's line discipline says about who, if anyone, is editing input.
enum ShellWarmupMode: Equatable {
    // ICANON + ECHO: the driver buffers the line and handles erase itself.
    // Typing here already behaves, so the gate stays out of the way.
    case cooked
    // -ICANON + ECHO: nobody is editing, yet every byte is echoed raw. This is
    // the p10k instant-prompt window — the only state the gate buffers in.
    case rawEcho
    // ECHO off: zle, a password prompt, or a full-screen app owns the input.
    // Whatever it is, it reads better than we do — release immediately (and
    // never hold a password hostage).
    case lineEditor
}

enum ShellWarmupTTY {
    // Reading the *master* fd reports the slave's line-discipline settings:
    // a pty pair shares one tty struct on BSD/macOS, which is how Suit can tell
    // "instant prompt is echoing raw" from "zle is up" without asking the shell
    // anything. Returns nil once the fd is gone (the shell exited).
    static func mode(of fd: Int32) -> ShellWarmupMode? {
        guard fd >= 0 else { return nil }
        var settings = termios()
        guard tcgetattr(fd, &settings) == 0 else { return nil }
        return mode(lflag: settings.c_lflag)
    }

    // Split out so the harness can exercise the mapping without a pty.
    static func mode(lflag: tcflag_t) -> ShellWarmupMode {
        guard lflag & tcflag_t(ECHO) != 0 else { return .lineEditor }
        return lflag & tcflag_t(ICANON) != 0 ? .cooked : .rawEcho
    }
}

// What the gate wants done with a chunk of keystrokes.
struct ShellWarmupResponse: Equatable {
    // Bytes to draw locally, standing in for the echo we withheld.
    var echo: [UInt8] = []
    // Bytes that must reach the pty now, gate or no gate (^C keeps its signal).
    var passthrough: [UInt8] = []
}

// Buffered keystrokes plus the erase that takes our stand-in echo back off the
// screen, so zle renders the line from scratch instead of over our copy.
struct ShellWarmupFlush: Equatable {
    var bytes: [UInt8] = []
    var erase: [UInt8] = []
}

final class ShellWarmupTypeahead {
    // Everything the user typed during the window, in order, waiting for a
    // reader that can make sense of it.
    private(set) var buffered: [UInt8] = []

    // The tail of `buffered` we echoed locally, newest last — one entry per
    // character, holding how many bytes it occupies in the buffer and how many
    // columns it took on screen. Anything we could not echo (a control byte, an
    // escape sequence) clears the run: erasing across it would guess wrong
    // about what is on screen, so a backspace there is left for zle instead.
    private var echoed: [(bytes: Int, columns: Int)] = []

    // A partial UTF-8 scalar is echoed only once its last byte arrives —
    // feeding half a scalar to the emulator draws a replacement glyph.
    private var partialScalar: [UInt8] = []

    private enum EscapeState { case ground, escape, csi, ss3 }
    private var escapeState: EscapeState = .ground

    private static let eraseColumn: [UInt8] = [0x08, 0x20, 0x08]   // BS, space, BS

    var isEmpty: Bool { buffered.isEmpty }

    func accept(_ data: ArraySlice<UInt8>) -> ShellWarmupResponse {
        var response = ShellWarmupResponse()
        for byte in data {
            // Escape sequences (arrow keys, a bracketed paste wrapper, kitty
            // encodings) are buffered whole and never echoed: their payload
            // bytes are printable but drawing them would spray `[A` on screen.
            if escapeState != .ground {
                buffer(byte, echoable: false)
                advanceEscape(byte)
                continue
            }

            switch byte {
            case 0x1B:
                buffer(byte, echoable: false)
                escapeState = .escape
            case 0x7F, 0x08:
                response.echo += eraseLastCharacter(fallback: byte)
            case 0x03:   // ^C — drop what was typed, and let the byte through
                response.echo += eraseEchoedRun()
                response.passthrough.append(byte)
            case 0x15:   // ^U — kill the line we are holding
                response.echo += eraseEchoedRun()
            case 0x20...0x7E, 0x80...0xFF:
                response.echo += appendPrintable(byte)
            default:     // Return, Tab, other control bytes: hold, don't draw
                buffer(byte, echoable: false)
            }
        }
        return response
    }

    // Hands over the held keystrokes and the erase that undoes our echo. The
    // gate is empty afterwards; the caller sends `erase` to the display and
    // `bytes` to the pty.
    //
    // `shellRedrew` is whether the shell wrote anything since our last echo — a
    // p10k instant prompt signs off by restoring the cursor and clearing to the
    // end of the display, which takes our characters with it. Erasing on top of
    // that would eat the fresh prompt instead (four backspaces through
    // `/Users/you ❯ ` leaves `/Users/yecho`), so the redraw wins and we only
    // clean up after ourselves when nothing else has touched the screen.
    func flush(shellRedrew: Bool) -> ShellWarmupFlush {
        // Unlike ^C/^U this erases the *display* only: the keystrokes it drew
        // are exactly what we are handing to the shell.
        let flush = ShellWarmupFlush(bytes: buffered, erase: shellRedrew ? [] : echoedErase())
        echoed.removeAll()
        buffered.removeAll()
        partialScalar.removeAll()
        escapeState = .ground
        return flush
    }

    // The shell died mid-window: the keystrokes have nowhere to go.
    func discard() {
        buffered.removeAll()
        echoed.removeAll()
        partialScalar.removeAll()
        escapeState = .ground
    }

    // MARK: - Buffer bookkeeping

    private func buffer(_ byte: UInt8, echoable: Bool) {
        buffered.append(byte)
        if !echoable {
            // Our record of what is on screen no longer reaches the end of the
            // buffer, so stop claiming we can erase back into it.
            echoed.removeAll()
            partialScalar.removeAll()
        }
    }

    private func appendPrintable(_ byte: UInt8) -> [UInt8] {
        buffered.append(byte)
        partialScalar.append(byte)
        guard let scalar = completedScalar() else { return [] }
        let bytes = partialScalar
        partialScalar.removeAll()
        echoed.append((bytes: bytes.count, columns: Self.columns(of: scalar)))
        return bytes
    }

    // Nil while the bytes so far are a valid prefix of a longer scalar. An
    // invalid sequence resolves as soon as it can't grow into anything (4 bytes
    // is the UTF-8 ceiling), so a stray byte can't wedge the echo forever.
    private func completedScalar() -> Unicode.Scalar? {
        if let text = String(bytes: partialScalar, encoding: .utf8), let scalar = text.unicodeScalars.first {
            return scalar
        }
        if partialScalar.count >= 4 { return Unicode.Scalar(0xFFFD) }
        return nil
    }

    private func eraseLastCharacter(fallback: UInt8) -> [UInt8] {
        // A half-typed scalar never reached the screen: drop its bytes silently.
        if !partialScalar.isEmpty {
            buffered.removeLast(partialScalar.count)
            partialScalar.removeAll()
            return []
        }
        guard let last = echoed.popLast() else {
            // Nothing of ours is on screen to erase — hold the byte and let the
            // real line editor apply it when it starts.
            buffer(fallback, echoable: false)
            return []
        }
        buffered.removeLast(last.bytes)
        return Array(repeating: Self.eraseColumn, count: last.columns).flatMap { $0 }
    }

    // The backspaces that take everything we drew back off the screen. Pure —
    // callers that also mean to drop the keystrokes say so themselves.
    private func echoedErase() -> [UInt8] {
        let columns = echoed.reduce(0) { $0 + $1.columns }
        return Array(repeating: Self.eraseColumn, count: columns).flatMap { $0 }
    }

    // ^C / ^U: unwind the line on screen *and* out of the buffer.
    private func eraseEchoedRun() -> [UInt8] {
        let erase = echoedErase()
        let bytes = echoed.reduce(0) { $0 + $1.bytes }
        buffered.removeLast(min(bytes, buffered.count))
        echoed.removeAll()
        if !partialScalar.isEmpty {
            buffered.removeLast(min(partialScalar.count, buffered.count))
            partialScalar.removeAll()
        }
        return erase
    }

    private func advanceEscape(_ byte: UInt8) {
        switch escapeState {
        case .ground:
            break
        case .escape:
            switch byte {
            case 0x5B: escapeState = .csi          // ESC [
            case 0x4F: escapeState = .ss3          // ESC O
            default:   escapeState = .ground       // ESC + one byte
            }
        case .csi:
            // Parameter and intermediate bytes run until a final byte.
            if (0x40...0x7E).contains(byte) { escapeState = .ground }
        case .ss3:
            escapeState = .ground
        }
    }

    // MARK: - Display width

    // Enough of a width table for an erase to land on the right column: the
    // wide CJK and emoji blocks count two, combining marks and joiners count
    // zero, everything else one.
    static func columns(of scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        switch value {
        case 0x0300...0x036F, 0x200B...0x200F, 0xFE00...0xFE0F, 0xFE20...0xFE2F, 0xE0100...0xE01EF:
            return 0
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1F9FF,
             0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}
