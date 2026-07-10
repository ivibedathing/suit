import Cocoa

// The pane's root view: a plain container that re-runs the content's manual
// layout (footer pinned to the bottom, scroll view filling the rest) whenever
// it resizes.
private final class PlanContainerView: NSView {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
}

// The plan-approval pane: when a Claude session in Plan mode
// proposes a plan (an ExitPlanMode tool call in its transcript — see
// PlanParser), this pane renders it read-only as numbered steps with a footer
// of Approve & Run / Edit / Discard buttons. Each button dispatches the
// matching payload into the session's pty, so the plan becomes something you
// *read and accept* rather than a mode you squint to identify. Reuses the
// transcript-parsing plumbing; one plan pane per window, reused like the
// transcript pane.
final class PlanApprovalPaneContent: NSObject, PaneContent {
    weak var pane: Pane?
    weak var tab: Tab?

    private let containerView = PlanContainerView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let textView = NSTextView(frame: .zero)
    private let footer = NSView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private var actionButtons: [(action: PlanApprovalAction, button: NSButton)] = []

    private var targetSessionId: String?
    private var sessionCwd: String?
    private var sessionTitle: String = ""
    // The parsed plan currently shown; the harness reads its `steps` to assert
    // every step rendered in order.
    private(set) var plan: ClaudePlan?

    private var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    private var baseTextColor: NSColor = Theme.textPrimary

    private static let footerHeight: CGFloat = 40

    var view: NSView { containerView }
    var focusTarget: NSView { textView }
    var defaultTitle: String { "Plan" }
    var workingDirectory: String? { sessionCwd }

    override init() {
        super.init()

        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = Theme.bg.cgColor
        containerView.onLayout = { [weak self] in self?.layoutViews() }

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = true
        textView.backgroundColor = Theme.bg

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        containerView.addSubview(scrollView)

        footer.wantsLayer = true
        footer.layer?.backgroundColor = Theme.barChrome.cgColor
        containerView.addSubview(footer)

        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = Theme.textDim
        statusLabel.lineBreakMode = .byTruncatingTail
        footer.addSubview(statusLabel)

        refreshButton.controlSize = .small
        refreshButton.bezelStyle = .texturedRounded
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        footer.addSubview(refreshButton)

        // Approve & Run / Edit / Discard, in that order (left→right on the right
        // side of the footer). The approve button is the default (⏎).
        for action in PlanApprovalAction.allCases {
            let button = NSButton(title: action.buttonTitle, target: self, action: #selector(actionButtonClicked(_:)))
            button.controlSize = .small
            button.bezelStyle = .texturedRounded
            if action == .approveAndRun { button.keyEquivalent = "\r" }
            footer.addSubview(button)
            actionButtons.append((action, button))
        }

        setPlanControlsEnabled(false)
    }

    // MARK: - Loading

    func load(session: ClaudeSession) {
        targetSessionId = session.id
        load(transcriptPath: session.transcriptPath, cwd: session.cwd, title: session.displayName)
    }

    private func load(transcriptPath: String?, cwd: String?, title: String) {
        sessionCwd = cwd
        sessionTitle = title
        tab?.contentTitleDidChange("Plan — \(title)")

        guard let transcriptPath, FileManager.default.fileExists(atPath: transcriptPath) else {
            plan = nil
            render(placeholder: "No transcript recorded for this session yet.")
            return
        }
        if let parsed = PlanParser.latestPlan(inTranscriptAt: transcriptPath) {
            plan = parsed
            render(plan: parsed)
        } else {
            plan = nil
            render(placeholder: "No plan awaiting approval in this session.\nSwitch it to Plan mode and ask Claude to plan; the plan appears here.")
        }
    }

    @objc private func refresh() {
        guard let id = targetSessionId,
              let session = ClaudeSessionMonitor.shared.sessions.first(where: { $0.id == id }) else {
            render(placeholder: "That session is no longer live.")
            setPlanControlsEnabled(false)
            return
        }
        load(session: session)
    }

    // MARK: - Rendering

    private func render(plan: ClaudePlan) {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 6
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)

        result.append(NSAttributedString(string: "Proposed plan — \(plan.steps.count) step\(plan.steps.count == 1 ? "" : "s")\n\n", attributes: [
            .font: boldFont, .foregroundColor: Theme.accent, .paragraphStyle: paragraph,
        ]))
        for (index, step) in plan.steps.enumerated() {
            let number = NSAttributedString(string: "\(index + 1). ", attributes: [
                .font: boldFont, .foregroundColor: Theme.accent, .paragraphStyle: paragraph,
            ])
            let body = NSAttributedString(string: step + "\n", attributes: [
                .font: font, .foregroundColor: baseTextColor, .paragraphStyle: paragraph,
            ])
            result.append(number)
            result.append(body)
        }

        // The verbatim markdown below the extracted steps, so nothing Claude
        // wrote is hidden by the step-splitting.
        result.append(NSAttributedString(string: "\n— full plan —\n\n", attributes: [
            .font: font, .foregroundColor: Theme.textFaint, .paragraphStyle: paragraph,
        ]))
        result.append(NSAttributedString(string: plan.rawMarkdown, attributes: [
            .font: font, .foregroundColor: Theme.textDim, .paragraphStyle: paragraph,
        ]))

        textView.textStorage?.setAttributedString(result)
        textView.scrollToBeginningOfDocument(nil)
        statusLabel.stringValue = sessionTitle.isEmpty ? "" : "Session: \(sessionTitle)"
        setPlanControlsEnabled(true)
    }

    private func render(placeholder: String) {
        textView.string = placeholder
        textView.textColor = Theme.textDim
        textView.font = font
        statusLabel.stringValue = sessionTitle.isEmpty ? "" : "Session: \(sessionTitle)"
        setPlanControlsEnabled(false)
    }

    private func setPlanControlsEnabled(_ enabled: Bool) {
        for (_, button) in actionButtons { button.isEnabled = enabled }
    }

    // MARK: - Actions

    @objc private func actionButtonClicked(_ sender: NSButton) {
        guard let entry = actionButtons.first(where: { $0.button === sender }) else { return }
        guard let id = targetSessionId else { NSSound.beep(); return }
        (NSApp.delegate as? AppDelegate)?.dispatchPlanApproval(entry.action, forSessionId: id)
    }

    // MARK: - Layout

    private func layoutViews() {
        let bounds = containerView.bounds
        footer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.footerHeight)
        scrollView.frame = NSRect(x: 0, y: Self.footerHeight, width: bounds.width, height: max(0, bounds.height - Self.footerHeight))

        var right = bounds.width - 10
        // Lay the action buttons out right→left so Discard sits at the far right
        // and Approve nearest the center — reversed iteration keeps source order.
        for (_, button) in actionButtons.reversed() {
            button.sizeToFit()
            let w = max(button.frame.width, 56)
            button.frame = NSRect(x: right - w, y: (Self.footerHeight - button.frame.height) / 2, width: w, height: button.frame.height)
            right = button.frame.minX - 6
        }
        refreshButton.sizeToFit()
        refreshButton.frame = NSRect(x: right - refreshButton.frame.width - 6, y: (Self.footerHeight - refreshButton.frame.height) / 2, width: refreshButton.frame.width, height: refreshButton.frame.height)
        statusLabel.frame = NSRect(x: 10, y: 0, width: max(0, refreshButton.frame.minX - 16), height: Self.footerHeight)
    }

    // MARK: - Appearance

    func applyFont(_ newFont: NSFont) {
        font = newFont
        rerender()
    }

    func applyTextColor(_ color: NSColor) {
        baseTextColor = color
        rerender()
    }

    func applyBackground(_ color: NSColor) {
        textView.backgroundColor = color
        containerView.layer?.backgroundColor = color.cgColor
    }

    private func rerender() {
        if let plan { render(plan: plan) } else { render(placeholder: textView.string) }
    }
}
