import Foundation

// Assertions for the shell warm-up typeahead gate —
// swift/Sources/suit/ShellWarmup.swift, the Foundation-only core that holds
// keystrokes for the second between "zsh exists" and "zle can edit a line".
// Compiled and run by scripts/shell-warmup-test.sh. Same driver shape as the
// editor-ops / find-replace harnesses.
//
// The pty section is the load-bearing one: the whole design rests on a master
// fd reporting the *slave's* line-discipline settings, so it is asserted
// against a real pty pair rather than taken on faith.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

func bytes(_ text: String) -> ArraySlice<UInt8> { Array(text.utf8)[...] }
func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

let erase: [UInt8] = [0x08, 0x20, 0x08]
func erases(_ count: Int) -> [UInt8] { Array(repeating: erase, count: count).flatMap { $0 } }

print("== tty mode mapping ==")
do {
    let cooked = tcflag_t(ICANON) | tcflag_t(ECHO) | tcflag_t(ISIG)
    check(ShellWarmupTTY.mode(lflag: cooked) == .cooked,
          "ICANON+ECHO is the driver's own line editing — hands off")
    check(ShellWarmupTTY.mode(lflag: tcflag_t(ECHO) | tcflag_t(ISIG)) == .rawEcho,
          "ECHO without ICANON is the instant-prompt window the gate exists for")
    check(ShellWarmupTTY.mode(lflag: tcflag_t(ISIG)) == .lineEditor,
          "echo off means zle (or a password prompt) is reading — release")
    check(ShellWarmupTTY.mode(lflag: tcflag_t(ICANON)) == .lineEditor,
          "a canonical read with echo off is a password prompt, not our window")
    check(ShellWarmupTTY.mode(of: -1) == nil, "a closed pty reports no mode at all")
}

print("")
print("== a real pty pair reports the slave's modes on the master fd ==")
do {
    let master = posix_openpt(O_RDWR | O_NOCTTY)
    check(master >= 0, "opened a pty master")
    if master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) {
        let slave = open(name, O_RDWR | O_NOCTTY)
        check(slave >= 0, "opened the matching slave")
        if slave >= 0 {
            var settings = termios()
            check(tcgetattr(slave, &settings) == 0, "read the slave's termios")

            // A fresh pty starts the way a shell first sees it.
            check(ShellWarmupTTY.mode(of: master) == .cooked, "a fresh pty reads as cooked")

            // What p10k's instant prompt does: `stty -icanon`, ECHO left on.
            settings.c_lflag &= ~tcflag_t(ICANON)
            _ = tcsetattr(slave, TCSANOW, &settings)
            check(ShellWarmupTTY.mode(of: master) == .rawEcho,
                  "`stty -icanon` on the slave is visible on the master as rawEcho")

            // What zle does when it finally starts.
            settings.c_lflag &= ~tcflag_t(ECHO)
            _ = tcsetattr(slave, TCSANOW, &settings)
            check(ShellWarmupTTY.mode(of: master) == .lineEditor,
                  "raw + noecho on the slave is visible on the master as lineEditor")
            close(slave)
        }
        close(master)
    }
}

print("")
print("== typing and backspace, the case that started this ==")
do {
    let gate = ShellWarmupTypeahead()
    let typed = gate.accept(bytes("echo hi"))
    check(text(typed.echo) == "echo hi", "printable keys are echoed for us, since the driver won't")
    check(typed.passthrough.isEmpty, "nothing reaches the pty while the gate holds the line")

    let deletes = gate.accept(bytes("\u{7F}\u{7F}\u{7F}"))
    check(deletes.echo == erases(3), "backspace erases on screen instead of printing ^?")
    check(text(gate.buffered) == "echo", "and erases from what the shell will be handed")

    let flushed = gate.flush(shellRedrew: false)
    check(text(flushed.bytes) == "echo", "the flush hands zle exactly the surviving line")
    check(flushed.erase == erases(4), "our stand-in echo is taken back off screen first")
    check(gate.isEmpty, "the gate is empty once flushed")
}

print("")
print("== a shell that redrew owns the screen ==")
do {
    // p10k signs off by restoring the cursor and clearing the display, which
    // already takes our characters with it; erasing again would eat the prompt.
    let gate = ShellWarmupTypeahead()
    _ = gate.accept(bytes("echo"))
    let flushed = gate.flush(shellRedrew: true)
    check(flushed.erase.isEmpty, "no erase once the shell has drawn over our echo")
    check(text(flushed.bytes) == "echo", "the line is still handed over in full")
}

print("")
print("== backspace with nothing of ours on screen ==")
do {
    let gate = ShellWarmupTypeahead()
    let response = gate.accept(bytes("\u{7F}"))
    check(response.echo.isEmpty, "no local erase — there is nothing of ours to erase")
    check(gate.buffered == [0x7F], "the byte is held for the line editor to interpret")
}

print("")
print("== escape sequences pass through unechoed ==")
do {
    let gate = ShellWarmupTypeahead()
    _ = gate.accept(bytes("ab"))
    let arrow = gate.accept(bytes("\u{1B}[A"))
    check(arrow.echo.isEmpty, "an arrow key's payload bytes are never drawn as text")
    let afterArrow = gate.accept(bytes("\u{7F}"))
    check(afterArrow.echo.isEmpty, "a backspace after one is left for zle, not guessed at")
    check(gate.buffered == Array("ab\u{1B}[A\u{7F}".utf8), "every byte still reaches the shell in order")

    let ss3 = ShellWarmupTypeahead()
    _ = ss3.accept(bytes("\u{1B}OP"))
    let afterSS3 = ss3.accept(bytes("x"))
    check(text(afterSS3.echo) == "x", "the SS3 sequence ends after its one final byte")

    let paste = ShellWarmupTypeahead()
    let wrapped = paste.accept(bytes("\u{1B}[200~hi\u{1B}[201~"))
    check(text(wrapped.echo) == "hi", "a bracketed paste draws its text but not its wrapper")
}

print("")
print("== control keys ==")
do {
    let interrupt = ShellWarmupTypeahead()
    _ = interrupt.accept(bytes("oops"))
    let ctrlC = interrupt.accept(bytes("\u{03}"))
    check(ctrlC.echo == erases(4), "^C wipes the line we drew")
    check(ctrlC.passthrough == [0x03], "and still reaches the pty, so it keeps its signal")
    check(interrupt.isEmpty, "nothing is left to hand over")

    let kill = ShellWarmupTypeahead()
    _ = kill.accept(bytes("oops"))
    let ctrlU = kill.accept(bytes("\u{15}"))
    check(ctrlU.echo == erases(4) && ctrlU.passthrough.isEmpty,
          "^U kills the held line locally, with nothing to forward")

    let entered = ShellWarmupTypeahead()
    _ = entered.accept(bytes("ls\r"))
    let after = entered.accept(bytes("\u{7F}"))
    check(after.echo.isEmpty, "backspace after Return can't erase back into the committed line")
    check(text(entered.buffered) == "ls\r\u{7F}", "both bytes are still delivered")

    let tabbed = ShellWarmupTypeahead()
    let completion = tabbed.accept(bytes("ec\t"))
    check(text(completion.echo) == "ec", "Tab isn't drawn — zle completes it when it starts")
}

print("")
print("== wide and multi-byte characters ==")
do {
    let gate = ShellWarmupTypeahead()
    let emoji = gate.accept(bytes("🚀"))
    check(text(emoji.echo) == "🚀", "a scalar is echoed once, when its last byte lands")
    let back = gate.accept(bytes("\u{7F}"))
    check(back.echo == erases(2), "erasing a double-width glyph clears both columns")
    check(gate.isEmpty, "all four of its bytes came back out of the buffer")

    let partial = ShellWarmupTypeahead()
    let head = partial.accept(bytes("🚀").dropLast())
    check(head.echo.isEmpty, "half a scalar is held back rather than drawn as garbage")
    let cancelled = partial.accept(bytes("\u{7F}"))
    check(cancelled.echo.isEmpty && partial.isEmpty, "backspacing a half-typed scalar drops it silently")

    let accented = ShellWarmupTypeahead()
    let combining = accented.accept(bytes("e\u{301}"))
    check(text(combining.echo) == "e\u{301}", "a combining mark is drawn")
    let undo = accented.accept(bytes("\u{7F}"))
    check(undo.echo.isEmpty, "but occupies no column, so erasing it moves the cursor nowhere")
}

print("")
print("== a dead shell drops what it can't receive ==")
do {
    let gate = ShellWarmupTypeahead()
    _ = gate.accept(bytes("rm -rf /"))
    gate.discard()
    check(gate.isEmpty, "discard leaves nothing to replay into the next process")
    check(gate.flush(shellRedrew: false).bytes.isEmpty, "and a later flush stays empty")
}

print("")
if failures == 0 {
    print("All shell-warmup assertions passed.")
} else {
    print("\(failures) shell-warmup assertion(s) FAILED.")
}
exit(failures == 0 ? 0 : 1)
