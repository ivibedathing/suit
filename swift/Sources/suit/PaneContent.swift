import Cocoa

// What a pane hosts. Today that's always a terminal (TerminalPaneContent), but
// the split tree, title bars, focus borders, and drag rearrangement in
// Pane/TerminalWindowController are content-agnostic: a file viewer, diff view,
// or search-results pane (see ROADMAP.md) plugs in by implementing this and
// changing nothing else.
protocol PaneContent: AnyObject {
    // The viewport currently displaying this content; nil while its tab is
    // backgrounded. Set by Pane.display. Used for pane-scoped actions
    // (context menu, file links).
    var pane: Pane? { get set }

    // The tab wrapping this content, set by Tab's initializer. Title changes
    // and process exit report through it (tab?.contentTitleDidChange /
    // tab?.contentProcessDidExit) so they still land while backgrounded.
    var tab: Tab? { get set }

    // The view installed inside the pane's bordered container, below the title bar.
    var view: NSView { get }

    // What becomes first responder when the pane is focused/selected. Focus
    // visuals are derived from window.firstResponder by the window controller
    // (one observer repaints every pane) — contents don't report focus.
    var focusTarget: NSView { get }

    // Shown in the title bar when neither a custom title nor a content-reported
    // title is set.
    var defaultTitle: String { get }

    // The content's own idea of its background, used as the pane's starting color.
    var initialBackgroundColor: NSColor { get }

    // Where "split from this pane" and "new tab" should start; nil when the
    // content has no meaningful directory.
    var workingDirectory: String? { get }

    func applyFont(_ font: NSFont)
    func applyTextColor(_ color: NSColor)
    // The color already carries the global translucency alpha.
    func applyBackground(_ color: NSColor)

    // The pane is going away: stop processes/timers. Must be safe to call twice.
    func teardown()
}

// A pane content backed by a single file on disk (viewer, markdown, image,
// PDF). openFile dedups by `filePath` so a file opens at
// most one tab regardless of which preview kind renders it, and `load` re-points
// an existing one (honoring an optional line jump where the kind supports it).
protocol FileBackedPaneContent: PaneContent {
    var filePath: String? { get }
    func load(path: String, line: Int?)
}

// Which preview pane a file opens into: routed by extension
// from openFile. Everything that isn't markdown/image/PDF falls through to the
// syntax-highlighted text viewer.
enum PreviewKind: Equatable {
    case text, markdown, image, pdf

    static func forPath(_ path: String) -> PreviewKind {
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd", "mkdn": return .markdown
        case "png", "jpg", "jpeg", "gif", "svg", "bmp",
             "tiff", "tif", "webp", "heic", "heif", "ico": return .image
        case "pdf": return .pdf
        default: return .text
        }
    }
}

// Appearance hooks and the working directory are opt-in — a content kind that
// has no font or no cwd just leaves the defaults.
extension PaneContent {
    var focusTarget: NSView { view }
    // One surface: every pane kind grounds on the chrome bg unless
    // it says otherwise, so a split window reads as one dark world.
    var initialBackgroundColor: NSColor { Theme.bg }
    var workingDirectory: String? { nil }
    func applyFont(_ font: NSFont) {}
    func applyTextColor(_ color: NSColor) {}
    func applyBackground(_ color: NSColor) {}
    func teardown() {}
}

// The original pane content: an interactive shell on a SwiftTerm pty.
// Non-final so SSHPaneContent can layer connect behavior on top.
class TerminalPaneContent: PaneContent, LocalProcessTerminalViewDelegate {
    let terminalView: PaneTerminalView

    // PaneTerminalView keeps its own back-reference so first-responder changes
    // and its context menu can reach the pane without knowing about contents.
    weak var pane: Pane? {
        didSet { terminalView.pane = pane }
    }

    // And the tab back-reference, so bells route to the strip while hidden.
    weak var tab: Tab? {
        didSet { terminalView.owningTab = tab }
    }

    var view: NSView { terminalView }
    var focusTarget: NSView { terminalView }
    var defaultTitle: String { "Terminal" }
    // Terminals ground a step darker than the chrome (Theme.terminalBg) unless
    // the settings window picked a different global default.
    var initialBackgroundColor: NSColor {
        (NSApp.delegate as? AppDelegate)?.defaultTerminalBackground ?? Theme.terminalBg
    }

    init() {
        terminalView = PaneTerminalView(frame: .zero)
        terminalView.processDelegate = self
    }

    func start(in directory: String = NSHomeDirectory()) {
        lastKnownWorkingDirectory = directory
        let appDelegate = NSApp.delegate as? AppDelegate
        // -l -i (login + interactive), matching what Terminal.app actually starts:
        // login shells source ~/.zprofile/~/.zlogin (where Homebrew's `brew shellenv`
        // PATH setup typically lives) before interactive shells source ~/.zshrc (where
        // oh-my-zsh/Powerlevel10k assume that PATH is already set up). -i alone skips
        // the login files, which is what caused `brew` to be missing when ~/.zshrc ran.
        // The flags fit bash/fish the same way, so the settings-window shell
        // override reuses them as-is.
        let shell = appDelegate?.shellPath ?? "/bin/zsh"
        terminalView.startProcess(executable: shell, args: ["-l", "-i"], environment: nil, execName: nil, currentDirectory: directory)
        if let style = appDelegate?.cursorStyle {
            applyCursorStyle(style)
        }
    }

    // The settings-window default; DECSCUSR from a program inside the terminal
    // can still override it per SwiftTerm's usual rules.
    func applyCursorStyle(_ style: CursorStyle) {
        terminalView.getTerminal().setCursorStyle(style)
    }

    var shellPid: pid_t { terminalView.process.shellPid }

    // The kernel read only works while the shell is alive; remember the last
    // answer so close-time capture (reopen stack, quit snapshot) still knows
    // where an exited shell was.
    private var lastKnownWorkingDirectory: String?

    var workingDirectory: String? {
        if let cwd = currentWorkingDirectory(ofProcess: shellPid) {
            lastKnownWorkingDirectory = cwd
            return cwd
        }
        return lastKnownWorkingDirectory
    }

    // The foreground job in this terminal (claude, vim, a build), or nil when
    // the user is idle at the shell prompt — see Pane.runningProcessName.
    var runningProcessName: String? {
        foregroundProcessName(ptyFd: terminalView.process.childfd, shellPid: shellPid)
    }

    func applyFont(_ font: NSFont) {
        terminalView.font = font
    }

    func applyTextColor(_ color: NSColor) {
        terminalView.nativeForegroundColor = color
        terminalView.colorsChanged()
    }

    func applyBackground(_ color: NSColor) {
        terminalView.nativeBackgroundColor = color
        terminalView.colorsChanged()
    }

    func teardown() {
        terminalView.process.terminate()
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        tab?.contentTitleDidChange(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // SwiftTerm hands back the raw `waitpid` status word here, not a decoded
        // exit code (see ProcessExitStatus's doc comment) — nil only happens on a
        // dead code path in SwiftTerm that never actually runs.
        tab?.contentProcessDidExit(exitCode.map(ProcessExitStatus.init(waitStatus:)))
    }
}
