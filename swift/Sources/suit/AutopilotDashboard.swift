import Cocoa

// The Autopilot dashboard: a floating panel that supervises every autopilot
// running at once (one per repo). Each row shows an instance's repo, its live
// status, and the per-repo controls — Focus run tab, Pause/Resume, Skip
// Current Phase, Retry (while blocked), Show Log, and Stop (drop the instance).
// A "Start Here" button stands up a new autopilot on the active tab's repo.
//
// The panel mirrors FleetDashboard's windowing (a non-activating floating
// utility panel) but renders a simple vertical stack of rows rebuilt on every
// AutopilotEngine/Store update, since the row set and each row's buttons are
// small and fully state-dependent.

private final class AutopilotPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// One instance's row. Owns its engine and forwards button taps to closures the
// controller wires up (each captures the engine).
final class AutopilotDashboardRow: NSView {
    var onFocus: (() -> Void)?
    var onPauseResume: (() -> Void)?
    var onSkip: (() -> Void)?
    var onRetry: (() -> Void)?
    var onLog: (() -> Void)?
    var onStop: (() -> Void)?

    private let dot = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let buttonRow = NSStackView()

    init(engine: AutopilotEngine) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = Theme.textPrimary
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = Theme.usageFont
        statusLabel.textColor = Theme.textDim
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let text = NSStackView(views: [nameLabel, statusLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false

        buttonRow.orientation = .horizontal
        buttonRow.spacing = 4
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot)
        addSubview(text)
        addSubview(buttonRow)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dot.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            text.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            text.trailingAnchor.constraint(lessThanOrEqualTo: buttonRow.leadingAnchor, constant: -8),

            buttonRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            buttonRow.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])

        configure(engine: engine)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        return b
    }

    func configure(engine: AutopilotEngine) {
        let status = engine.footerStatus()
        nameLabel.stringValue = engine.displayName
        statusLabel.stringValue = status.text
        statusLabel.toolTip = status.tooltip
        dot.layer?.backgroundColor = Self.color(for: status.kind).cgColor

        buttonRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // Focus the run tab only when a worker tab exists.
        if engine.workerTabId != nil {
            buttonRow.addArrangedSubview(button("Focus", #selector(focusTapped)))
        }
        if case .blocked = engine.state {
            buttonRow.addArrangedSubview(button("Retry", #selector(retryTapped)))
        }
        if case .running = engine.state {
            buttonRow.addArrangedSubview(button("Skip", #selector(skipTapped)))
        }
        let paused = engine.state == .paused
        buttonRow.addArrangedSubview(button(paused ? "Resume" : "Pause", #selector(pauseResumeTapped)))
        buttonRow.addArrangedSubview(button("Log", #selector(logTapped)))
        buttonRow.addArrangedSubview(button("Stop", #selector(stopTapped)))
    }

    static func color(for kind: AutopilotFooterStatus.Kind) -> NSColor {
        switch kind {
        case .idle: return Theme.textFaint
        case .running: return Theme.sessionBusy
        case .blocked: return Theme.failed
        case .paused: return Theme.sessionNeedsInput
        case .done: return Theme.sessionDone
        }
    }

    @objc private func focusTapped() { onFocus?() }
    @objc private func pauseResumeTapped() { onPauseResume?() }
    @objc private func skipTapped() { onSkip?() }
    @objc private func retryTapped() { onRetry?() }
    @objc private func logTapped() { onLog?() }
    @objc private func stopTapped() { onStop?() }
}

final class AutopilotDashboardController: NSObject, NSWindowDelegate {
    // Wired by the AppDelegate — the app-side surfaces (tabs, viewer tabs).
    var onFocusRunTab: ((AutopilotEngine) -> Void)?
    var onOpenLog: ((AutopilotEngine) -> Void)?
    var onStartHere: (() -> Void)?

    private let panel: AutopilotPanel
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No autopilots running. “Start Here” launches one on the active tab’s repo.")
    private let startButton = NSButton()
    private let countLabel = NSTextField(labelWithString: "")

    override init() {
        panel = AutopilotPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = "Autopilot"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.delegate = self
        panel.minSize = NSSize(width: 460, height: 240)

        let content = NSView(frame: panel.contentLayoutRect)
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.bg.cgColor
        panel.contentView = content

        startButton.title = "Start Here"
        startButton.bezelStyle = .rounded
        startButton.controlSize = .regular
        startButton.target = self
        startButton.action = #selector(startTapped)
        startButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(startButton)

        countLabel.font = Theme.usageFont
        countLabel.textColor = Theme.textDim
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(countLabel)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = Theme.textFaint
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyLabel)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = stack
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)

        NSLayoutConstraint.activate([
            startButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            startButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),

            countLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            countLabel.centerYAnchor.constraint(equalTo: startButton.centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: startButton.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -40),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(reloadOnUpdate), name: AutopilotEngine.didUpdate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadOnUpdate), name: AutopilotStore.didUpdate, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func toggle(relativeTo window: NSWindow?) {
        if panel.isVisible { panel.orderOut(nil) } else { show(relativeTo: window) }
    }

    func show(relativeTo window: NSWindow?) {
        reload()
        if !panel.isVisible {
            if let window {
                let frame = window.frame
                let size = panel.frame.size
                panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
            } else {
                panel.center()
            }
        }
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func reloadOnUpdate() {
        guard panel.isVisible else { return }
        reload()
    }

    @objc private func startTapped() { onStartHere?() }

    private func reload() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let engines = AutopilotManager.shared.allEngines.filter { $0.isActive }
        emptyLabel.isHidden = !engines.isEmpty
        let running = AutopilotManager.shared.runningCount
        countLabel.stringValue = engines.isEmpty
            ? ""
            : "\(engines.count) autopilot\(engines.count == 1 ? "" : "s")" + (running > 0 ? " · 1 running" : "")

        for engine in engines {
            let row = AutopilotDashboardRow(engine: engine)
            row.onFocus = { [weak self] in self?.onFocusRunTab?(engine) }
            row.onLog = { [weak self] in self?.onOpenLog?(engine) }
            row.onPauseResume = {
                if engine.state == .paused { engine.resume() } else { engine.pauseAfterCurrentRun() }
            }
            row.onSkip = { engine.skipCurrentPhase() }
            row.onRetry = { engine.retryAfterBlock() }
            row.onStop = { AutopilotManager.shared.stop(engine) }
            // Full-width separator look: a thin divider under each row.
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            stack.addArrangedSubview(row)
        }
    }
}
