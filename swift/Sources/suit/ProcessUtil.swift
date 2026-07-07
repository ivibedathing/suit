import Darwin

// SwiftTerm's LocalProcess hands back the raw `waitpid` status word as `exitCode`
// (see LocalProcess.swift's `processTerminated()`), not a decoded exit code — so
// this reimplements the <sys/wait.h> WIFEXITED/WEXITSTATUS/WIFSIGNALED/WTERMSIG
// macros, which the Swift importer doesn't expose on Darwin.
enum ProcessExitStatus: Equatable {
    case exited(code: Int32)
    case signaled(signal: Int32)

    init(waitStatus status: Int32) {
        let stopSignal = status & 0x7f
        if stopSignal == 0 {
            self = .exited(code: (status >> 8) & 0xff)
        } else {
            self = .signaled(signal: stopSignal)
        }
    }

    var isClean: Bool {
        self == .exited(code: 0)
    }

    // strsignal already renders human text for the case that matters most here
    // (SIGPIPE -> "Broken pipe"), so there's no need for a hand-rolled signal table.
    var shortLabel: String {
        switch self {
        case .exited(let code):
            return code == 0 ? "done" : "exit \(code)"
        case .signaled(let signal):
            return String(cString: strsignal(signal)).lowercased()
        }
    }
}

// A pane counts as "running code" when the pty's foreground process group is no
// longer the shell's own — i.e. the user launched something (claude, vim, a
// build…) that currently controls the terminal. Background helpers that prompt
// frameworks spawn (e.g. Powerlevel10k's gitstatusd) live in their own
// non-foreground group, so they don't trip this. Returns the foreground
// process's name, or nil when the shell is sitting idle at a prompt.
func foregroundProcessName(ptyFd: Int32, shellPid: pid_t) -> String? {
    guard ptyFd >= 0, shellPid > 0 else { return nil }
    let foregroundGroup = tcgetpgrp(ptyFd)
    guard foregroundGroup > 0, foregroundGroup != shellPid else { return nil }
    // The group leader's pid is the pgid itself; it can be gone already if the
    // job is mid-exit, in which case the pane is still busy — just nameless.
    var buffer = [CChar](repeating: 0, count: 256)
    let length = proc_name(foregroundGroup, &buffer, UInt32(buffer.count))
    return length > 0 ? String(cString: buffer) : "a process"
}

// Reads a running process's current working directory straight from the kernel
// (the same information `lsof`/`ps` show), so a new split pane can start in
// wherever the shell it was split from actually is right now — independent of
// whether that shell's prompt/config reports its cwd via any escape sequence.
func currentWorkingDirectory(ofProcess pid: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let size = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size))
    guard size == Int32(MemoryLayout<proc_vnodepathinfo>.size) else { return nil }

    return withUnsafePointer(to: &info.pvi_cdir.vip_path) { pathPtr in
        pathPtr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cString in
            String(cString: cString)
        }
    }
}
