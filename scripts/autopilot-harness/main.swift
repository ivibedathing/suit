import Cocoa

// Autopilot pipeline harness driver (ROADMAP Phase 32, STANDALONE.md §4).
// Compiled by scripts/autopilot-harness.sh against the app sources minus the
// app's main.swift, the way design/reference/main.swift drives the app
// offscreen: create the NSApplication + AppDelegate, open one real window,
// configure Autopilot the way the Settings section would, then pump the run
// loop and tick the real engine until it works the fixture repo's Phase 1
// end-to-end (spawn → nudge → gates → merge → cleanup) and lands in
// doneAllPhases because Phase 2 carries the ⏸ steering marker.
//
// The world around the engine is entirely faked by the wrapping script: a
// temp $HOME (sandboxes ~/.suit and the run tab's zsh rc files), a fixture
// repo with a bare "origin", a stub build.sh, and fake `claude`/`gh`
// binaries (PATH-first inside the tab's zsh; SUIT_CLAUDE_PATH/SUIT_GH_PATH
// for the headless gate and GitHubCLI). This driver only observes: it prints
// machine-parseable "OBSERVE …" lines the script asserts on.
//
// Exit codes: 0 = engine reached doneAllPhases, 2 = timeout, 3 = the engine
// blocked, 64 = missing configuration.

setbuf(stdout, nil)

let environment = ProcessInfo.processInfo.environment
guard let projectRoot = environment["HARNESS_PROJECT_ROOT"], !projectRoot.isEmpty else {
    FileHandle.standardError.write(Data("HARNESS_PROJECT_ROOT is not set\n".utf8))
    exit(64)
}
let timeout = TimeInterval(environment["HARNESS_TIMEOUT_SECONDS"] ?? "") ?? 360

func observe(_ line: String) {
    print("OBSERVE \(line)")
}

func pump(_ seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
}

_ = NSApplication.shared
// applicationDidFinishLaunching doesn't run here; pin the committed-dark
// appearance the way the app does.
NSApp.appearance = NSAppearance(named: .darkAqua)
let delegate = AppDelegate()

delegate.newWindow(nil)
guard let controller = NSApp.windows.compactMap({ $0.delegate as? TerminalWindowController }).first else {
    FileHandle.standardError.write(Data("no window controller\n".utf8))
    exit(1)
}
controller.window.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 720), display: true)
pump(1.0)

// What Settings ▸ Autopilot would write through the autopilotXChanged
// setters. Max-out with no usage snapshot on disk is always `.go`, so the
// budget gate never binds; the defaults cover the rest (3 gate attempts,
// 60-min stall). No sleep hold — the harness must not touch power state.
delegate.autopilotEnabled = true
delegate.autopilotProjectRoot = projectRoot
delegate.autopilotMode = .maxOut
delegate.autopilotPreventSleep = false

// The applicationDidFinishLaunching wiring, minus the 3 s timer (the loop
// below ticks by hand, faster — every throttle the engine applies is its own).
AutopilotEngine.shared.appDelegate = delegate
ClaudeSessionMonitor.shared.reload()
AutopilotEngine.shared.adoptOnLaunch()
observe("engine-started")

let engine = AutopilotEngine.shared
let store = AutopilotStore.shared
var seenRunIds = Set<String>()
var lastStageLine = ""
var ticks = 0
var exitCode: Int32 = 2
let deadline = Date().addingTimeInterval(timeout)

loop: while Date() < deadline {
    pump(0.5)
    engine.tick()
    ticks += 1
    // The app's slow heartbeat: re-read the session files every ~3 s (the
    // directory watcher covers writes; the reload also refreshes the pid
    // table behind session pinning).
    if ticks % 6 == 0 { ClaudeSessionMonitor.shared.reload() }

    if let run = store.run {
        if !seenRunIds.contains(run.id) {
            seenRunIds.insert(run.id)
            let exists = FileManager.default.fileExists(atPath: run.worktreePath)
            observe("run-started phase=\(run.phaseId) slug=\(run.slug) worktree=\(run.worktreePath) exists=\(exists ? 1 : 0)")
        }
        let stageLine = "stage phase=\(run.phaseId) \(run.stage)"
        if stageLine != lastStageLine {
            lastStageLine = stageLine
            observe(stageLine)
        }
    }

    switch engine.state {
    case .doneAllPhases:
        observe("done-all-phases")
        exitCode = 0
        break loop
    case .blocked(let reason):
        observe("blocked \(reason.rawValue) — \(engine.footerStatus().tooltip)")
        exitCode = 3
        break loop
    default:
        break
    }
}

if exitCode == 2 {
    observe("timeout — \(engine.footerStatus().text)")
}

// Kill the fixture shells (and any straggling worker pty) before exiting.
for window in NSApp.windows {
    guard let c = window.delegate as? TerminalWindowController else { continue }
    for tab in c.store.tabs { tab.content.teardown() }
}
exit(exitCode)
