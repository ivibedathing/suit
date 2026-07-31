import Cocoa

// One operation in the sidebar's Background tab: the subsystem's glyph, what
// ran, how long it took, and — the column that turns a list into an
// explanation — what triggered it. A run of identical operations collapses to
// one row wearing a ×N, so an FSEvents burst reads as "git status ×6" instead
// of pushing everything that explains it off the top.
private final class OpsRowView: NSView {
    static let height: CGFloat = 34

    private let iconView = NSImageView(frame: .zero)
    private let labelField = NSTextField(labelWithString: "")
    private let countField = NSTextField(labelWithString: "")
    private let durationField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let ageField = NSTextField(labelWithString: "")

    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        labelField.font = .systemFont(ofSize: 11.5, weight: .medium)
        labelField.lineBreakMode = .byTruncatingTail
        addSubview(labelField)

        // The ×N sits with the label rather than in a column of its own: it is
        // part of what ran, not a measurement of it.
        countField.font = .systemFont(ofSize: 10, weight: .semibold)
        addSubview(countField)

        // Monospaced digits so a column of durations lines up and a slow row
        // is findable by shape alone — the whole reason to show them.
        durationField.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        durationField.alignment = .right
        addSubview(durationField)

        detailField.font = .systemFont(ofSize: 9.5, weight: .regular)
        detailField.lineBreakMode = .byTruncatingTail
        addSubview(detailField)

        ageField.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        ageField.alignment = .right
        addSubview(ageField)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(row: OpsRow, now: TimeInterval) {
        let record = row.record
        let failed = record.outcome.isFailed

        iconView.image = NSImage(systemSymbolName: record.kind.glyph, accessibilityDescription: record.kind.label)
        iconView.contentTintColor = failed ? Theme.failed : Theme.textFaint

        labelField.stringValue = record.label
        labelField.textColor = failed ? Theme.failed : Theme.textPrimary

        countField.stringValue = row.isCollapsed ? "×\(row.count)" : ""
        countField.textColor = Theme.accent
        countField.isHidden = !row.isCollapsed

        // A collapsed row reports the run's total: what the burst cost, which
        // is the number worth reading, not what one of its six calls took.
        durationField.stringValue = OpsFormat.duration(row.totalDuration)
        durationField.textColor = Theme.textDim

        // "why · what". The trigger leads because it is the column you scan
        // when you're asking what set all this off.
        var parts: [String] = []
        if let trigger = record.trigger, !trigger.isEmpty { parts.append(trigger) }
        if let detail = record.detail, !detail.isEmpty { parts.append(detail) }
        if record.outcome == .empty { parts.append("no output") }
        detailField.stringValue = parts.joined(separator: " · ")
        detailField.textColor = Theme.textFaint

        ageField.stringValue = OpsFormat.age(now - record.startedAt)
        ageField.textColor = Theme.textFaint

        toolTip = [record.kind.label, record.label, detailField.stringValue,
                   OpsFormat.duration(record.duration)]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        needsLayout = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        Theme.hover.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
    }

    override func layout() {
        super.layout()
        // Unflipped: the label line sits above the detail line.
        let iconSize: CGFloat = 12
        iconView.frame = NSRect(x: 11, y: 18, width: iconSize, height: iconSize)

        let left = iconView.frame.maxX + 7
        let durationWidth: CGFloat = 54
        durationField.frame = NSRect(x: bounds.width - 10 - durationWidth, y: 17, width: durationWidth, height: 14)

        var labelRight = durationField.frame.minX - 4
        if !countField.isHidden {
            countField.sizeToFit()
            let width = min(countField.frame.width, 34)
            countField.frame = NSRect(x: labelRight - width, y: 17, width: width, height: 14)
            labelRight = countField.frame.minX - 4
        }
        labelField.frame = NSRect(x: left, y: 17, width: max(0, labelRight - left), height: 14)

        let ageWidth: CGFloat = 26
        ageField.frame = NSRect(x: bounds.width - 10 - ageWidth, y: 4, width: ageWidth, height: 12)
        detailField.frame = NSRect(
            x: left, y: 4, width: max(0, ageField.frame.minX - 4 - left), height: 12
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }
}

// The sidebar's Background tab: everything Suit does that nobody asked it to.
//
// Every other sidebar tab shows the user's material — their files, their
// changes, their sessions. This one shows the app's own: the `git status` per
// FSEvents burst, the `gh pr list` when Source Control comes forward, the index
// rescans, the ctags passes, the update check. That work was previously
// invisible, which is why a runaway cascade of it could ship (see the git-storm
// fix) and be diagnosed only by reading code. The rows come from OpsLog; the
// footer's rolling count is the line that makes a cascade obvious at a glance.
//
// Read-only by design. Rows aren't clickable — there is nowhere useful to go
// from "a git status ran" — but every row carries the full record as a tooltip.
final class OpsLogView: NSView {
    // Rows rendered at most. Past a couple of hundred the list is scrollback
    // nobody scrolls, and each row is a live view; the buffer keeps the rest.
    private static let maxRows = 200

    // The window the footer counts over. A minute is long enough that a normal
    // burst has finished inside it and short enough that a number sitting there
    // means work is happening *now*.
    private static let rollupWindow: TimeInterval = 60

    // Ages and the rolling count drift with the clock, not with new records, so
    // a visible tab re-renders on a slow tick as well as on didUpdate. Only
    // while visible — a hidden tab schedules nothing.
    private static let tickInterval: TimeInterval = 2

    private static let kindFilterKey = "opsLogKindFilter"

    private let titleLabel = SidebarTitle.label("BACKGROUND")
    private let filterButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let pauseButton = NSButton(frame: .zero)
    private let clearButton = NSButton(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let documentView = FlippedView(frame: .zero)
    private let footerLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")

    private var rowViews: [OpsRowView] = []
    private var rows: [OpsRow] = []
    private var renderedSignature: String?
    private var tickTimer: Timer?

    // nil = every kind.
    private var kindFilter: OpsKind?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        addSubview(titleLabel)

        buildFilterMenu()
        filterButton.target = self
        filterButton.action = #selector(filterChanged)
        filterButton.isBordered = false
        filterButton.font = .systemFont(ofSize: 10, weight: .medium)
        filterButton.toolTip = "Show only one kind of operation"
        addSubview(filterButton)

        configureGlyphButton(pauseButton, symbol: "pause.fill", action: #selector(togglePause))
        configureGlyphButton(clearButton, symbol: "trash", action: #selector(clearLog))
        clearButton.toolTip = "Clear the log"
        addSubview(pauseButton)
        addSubview(clearButton)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView
        addSubview(scrollView)

        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 3
        addSubview(emptyLabel)

        footerLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        addSubview(footerLabel)

        if let saved = UserDefaults.standard.string(forKey: Self.kindFilterKey),
           let kind = OpsKind(rawValue: saved) {
            kindFilter = kind
        }
        selectFilterItem()

        NotificationCenter.default.addObserver(
            self, selector: #selector(logUpdated), name: OpsLog.didUpdate, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: Theme.didChange, object: nil
        )
        applyControlTints()
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        tickTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Chrome

    private func configureGlyphButton(_ button: NSButton, symbol: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        button.image?.isTemplate = true
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
    }

    private func buildFilterMenu() {
        // Every kind, always — a menu rebuilt from what the log currently holds
        // would reshuffle under the pointer as work arrives, and a kind with no
        // rows is an answer ("nothing has hit the network") rather than a gap.
        let menu = NSMenu()
        let all = NSMenuItem(title: "All", action: nil, keyEquivalent: "")
        all.representedObject = nil
        menu.addItem(all)
        menu.addItem(.separator())
        for kind in OpsKind.allCases {
            let item = NSMenuItem(title: kind.label, action: nil, keyEquivalent: "")
            item.representedObject = kind.rawValue
            menu.addItem(item)
        }
        filterButton.menu = menu
    }

    private func selectFilterItem() {
        let target = kindFilter?.rawValue
        let index = filterButton.menu?.items.firstIndex {
            ($0.representedObject as? String) == target
        }
        filterButton.selectItem(at: index ?? 0)
    }

    // Tints baked into controls at init aren't reached by the window
    // controller's recursive needsDisplay sweep (that only repaints draw()-based
    // chrome), so they are re-read here — the reapplyTheme contract every other
    // sidebar surface follows.
    private func applyControlTints() {
        filterButton.contentTintColor = Theme.textDim
        pauseButton.contentTintColor = OpsLog.shared.isPaused ? Theme.accent : Theme.textDim
        clearButton.contentTintColor = Theme.textDim
        footerLabel.textColor = Theme.textFaint
        emptyLabel.textColor = Theme.textFaint
    }

    func reapplyTheme() {
        applyControlTints()
        renderedSignature = nil
        reload()
    }

    @objc private func themeChanged() {
        reapplyTheme()
    }

    // MARK: - Actions

    @objc private func filterChanged() {
        let raw = filterButton.selectedItem?.representedObject as? String
        kindFilter = raw.flatMap { OpsKind(rawValue: $0) }
        if let raw {
            UserDefaults.standard.set(raw, forKey: Self.kindFilterKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.kindFilterKey)
        }
        renderedSignature = nil
        reload()
    }

    @objc private func togglePause() {
        OpsLog.shared.isPaused.toggle()
        let paused = OpsLog.shared.isPaused
        pauseButton.image = NSImage(
            systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: nil
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        pauseButton.image?.isTemplate = true
        pauseButton.toolTip = paused ? "Resume recording" : "Pause recording"
        applyControlTints()
        reload()
    }

    @objc private func clearLog() {
        OpsLog.shared.clear()
    }

    // MARK: - Refresh

    @objc private func logUpdated() {
        // OpsLog coalesces its notifications, but a hidden tab shouldn't rebuild
        // rows nobody can see — the tab exists to stop needless background work,
        // not to add its own.
        guard !isHiddenOrHasHiddenAncestor else { return }
        reload()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        startTicking()
        reload()
    }

    override func viewDidHide() {
        super.viewDidHide()
        stopTicking()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, !isHiddenOrHasHiddenAncestor {
            startTicking()
        } else {
            stopTicking()
        }
    }

    private func startTicking() {
        guard tickTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.reload()
        }
        // Generous tolerance: nothing here is time-critical, and letting the
        // system coalesce the fire keeps an idle tab off the CPU.
        timer.tolerance = Self.tickInterval / 2
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func reload() {
        let records = OpsFilter.apply(OpsLog.shared.snapshot, kind: kindFilter)
        rows = OpsCollapse.rows(records, limit: Self.maxRows)
        let now = Date().timeIntervalSince1970

        footerLabel.stringValue = OpsRollup
            .over(OpsLog.shared.snapshot, now: now, window: Self.rollupWindow)
            .summary(window: Self.rollupWindow)

        emptyLabel.isHidden = !rows.isEmpty
        if rows.isEmpty {
            emptyLabel.stringValue = OpsLog.shared.isPaused
                ? "Recording paused."
                : kindFilter.map { "No \($0.label.lowercased()) operations yet." }
                    ?? "Nothing yet — Suit logs its own background work here as it happens."
        }

        // Row views are rebuilt wholesale, and this runs on every coalesced
        // update plus a 2 s tick; comparing what the rows draw is far cheaper
        // than tearing down two hundred views to discover nothing moved. Ages
        // are part of the signature, so a row does re-render when its printed
        // age changes — and only then. (The SessionsView pattern.)
        let signature = Self.signature(rows: rows, now: now)
        guard signature != renderedSignature else { return }
        renderedSignature = signature
        rebuild(now: now)
    }

    private static func signature(rows: [OpsRow], now: TimeInterval) -> String {
        rows.map { row in
            [
                "\(row.record.seq)", "\(row.count)", row.record.label,
                row.record.detail ?? "", row.record.trigger ?? "",
                row.record.outcome.rawValue,
                OpsFormat.duration(row.totalDuration),
                OpsFormat.age(now - row.record.startedAt),
            ].joined(separator: "\u{1}")
        }.joined(separator: "\u{2}")
    }

    private func rebuild(now: TimeInterval) {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = []
        for row in rows {
            let view = OpsRowView(frame: .zero)
            view.configure(row: row, now: now)
            documentView.addSubview(view)
            rowViews.append(view)
        }
        layoutDocument()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        // Not flipped: the title band is at the top, the footer at the bottom.
        let titleY = bounds.height - SidebarTitle.height
        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(
            x: SidebarTitle.leftInset,
            y: titleY + (SidebarTitle.height - titleLabel.frame.height) / 2
        )

        let glyph: CGFloat = 18
        let bandCenter = titleY + (SidebarTitle.height - glyph) / 2
        clearButton.frame = NSRect(x: bounds.width - 8 - glyph, y: bandCenter, width: glyph, height: glyph)
        pauseButton.frame = NSRect(x: clearButton.frame.minX - 2 - glyph, y: bandCenter, width: glyph, height: glyph)

        // The filter takes what's left between the title and the buttons, down
        // to nothing on a narrow sidebar — the buttons never get pushed off.
        let filterLeft = titleLabel.frame.maxX + 8
        let filterRight = pauseButton.frame.minX - 4
        filterButton.frame = NSRect(
            x: filterLeft, y: titleY + (SidebarTitle.height - 16) / 2,
            width: max(0, filterRight - filterLeft), height: 16
        )
        filterButton.isHidden = filterButton.frame.width < 40

        let footerHeight: CGFloat = 20
        footerLabel.frame = NSRect(x: 11, y: 4, width: max(0, bounds.width - 22), height: 13)
        scrollView.frame = NSRect(
            x: 0, y: footerHeight, width: bounds.width, height: max(0, titleY - footerHeight)
        )
        emptyLabel.frame = NSRect(
            x: 16, y: scrollView.frame.midY - 20, width: max(0, bounds.width - 32), height: 40
        )
        layoutDocument()
    }

    // A hairline above the footer, so the rolling count reads as a summary of
    // the list rather than its last row.
    override func draw(_ dirtyRect: NSRect) {
        Theme.hairline.setFill()
        NSRect(x: 0, y: 20, width: bounds.width, height: 1).fill()
    }

    private func layoutDocument() {
        let width = scrollView.contentSize.width
        let height = OpsRowView.height
        var y: CGFloat = 4
        for view in rowViews {
            view.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height
        }
        documentView.frame = NSRect(x: 0, y: 0, width: width, height: max(scrollView.contentSize.height, y + 4))
    }
}
