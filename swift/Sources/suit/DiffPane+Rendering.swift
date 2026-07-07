import Cocoa

extension DiffPaneContent {
    // MARK: - Rendering

    private struct DiffPalette {
        let addition: NSColor
        let deletion: NSColor
        let additionBackground: NSColor
        let deletionBackground: NSColor
        let header: NSColor
        let meta: NSColor
        let fillerBackground: NSColor
    }

    private var palette: DiffPalette {
        DiffPalette(
            addition: NSColor(calibratedRed: 0.55, green: 0.85, blue: 0.55, alpha: 1),
            deletion: NSColor(calibratedRed: 0.94, green: 0.52, blue: 0.50, alpha: 1),
            additionBackground: NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.25, alpha: 0.22),
            deletionBackground: NSColor(calibratedRed: 0.70, green: 0.20, blue: 0.18, alpha: 0.22),
            header: NSColor(calibratedRed: 0.42, green: 0.78, blue: 0.86, alpha: 1),
            meta: NSColor(calibratedWhite: 0.55, alpha: 1),
            fillerBackground: NSColor(calibratedWhite: 0.5, alpha: 0.06)
        )
    }

    func render() {
        renderUnified()
        renderSideBySide()
    }

    private func attributes(color: NSColor, background: NSColor? = nil) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if let background {
            attrs[.backgroundColor] = background
        }
        return attrs
    }

    private func renderUnified() {
        let palette = palette
        let output = NSMutableAttributedString()
        unifiedAnchors = []
        unifiedLineRefs = []
        var currentFile: String?
        let commentAttrs = attributes(color: Theme.accent, background: Theme.accent.withAlphaComponent(0.09))

        if diffLines.isEmpty {
            output.append(NSAttributedString(string: "No changes.", attributes: attributes(color: palette.meta)))
        }
        for line in diffLines {
            let text: String
            let attrs: [NSAttributedString.Key: Any]
            // The (side, line) this content row anchors a comment to, if any.
            var anchor: (DiffReviewComment.Side, Int)?
            switch line.kind {
            case .fileHeader:
                currentFile = Self.fileFromHeader(line.text)
                unifiedAnchors.append(output.length + 1) // past the blank spacer line
                text = "\n" + line.text
                attrs = attributes(color: palette.header)
            case .hunkHeader:
                text = line.text
                attrs = attributes(color: palette.meta)
            case .meta:
                text = line.text
                attrs = attributes(color: palette.meta)
            case .context:
                text = "  " + line.text
                attrs = attributes(color: baseColor)
                if let n = line.newLine { anchor = (.new, n) }
            case .addition:
                text = "+ " + line.text
                attrs = attributes(color: palette.addition, background: palette.additionBackground)
                if let n = line.newLine { anchor = (.new, n) }
            case .deletion:
                text = "- " + line.text
                attrs = attributes(color: palette.deletion, background: palette.deletionBackground)
                if let n = line.oldLine { anchor = (.old, n) }
            }

            let start = output.length
            output.append(NSAttributedString(string: text + "\n", attributes: attrs))

            // Record the hit-test map and render any attached comment inline
            // right under the line it belongs to (amber, gutter-ticked).
            if let file = currentFile, let (side, num) = anchor {
                unifiedLineRefs.append(UnifiedLineRef(
                    range: NSRange(location: start, length: output.length - start),
                    file: file, side: side, line: num, text: line.text
                ))
                if let comment = reviewDraft.comment(file: file, side: side, line: num) {
                    output.append(NSAttributedString(string: "    ▎ " + comment.text + "\n", attributes: commentAttrs))
                }
            }
        }
        unifiedText.textStorage?.setAttributedString(output)
    }

    // The b/ path out of a "diff --git a/x b/x" header — matches
    // UnifiedDiffParser.changedPaths so anchors line up with review-walk paths.
    private static func fileFromHeader(_ raw: String) -> String? {
        guard let range = raw.range(of: " b/") else { return nil }
        return String(raw[range.upperBound...])
    }

    // Aligns deletions and additions within each hunk into left/right rows,
    // padding the shorter run with filler lines, so changed regions sit next
    // to each other.
    private func renderSideBySide() {
        let palette = palette
        let left = NSMutableAttributedString()
        let right = NSMutableAttributedString()
        sideAnchors = []

        func appendRow(_ leftLine: (String, [NSAttributedString.Key: Any]), _ rightLine: (String, [NSAttributedString.Key: Any])) {
            left.append(NSAttributedString(string: leftLine.0 + "\n", attributes: leftLine.1))
            right.append(NSAttributedString(string: rightLine.0 + "\n", attributes: rightLine.1))
        }

        let filler = ("", attributes(color: baseColor, background: palette.fillerBackground))

        var pendingDeletions: [DiffLine] = []
        var pendingAdditions: [DiffLine] = []

        func flushPending() {
            let rows = max(pendingDeletions.count, pendingAdditions.count)
            for i in 0..<rows {
                let leftLine = i < pendingDeletions.count
                    ? (pendingDeletions[i].text, attributes(color: palette.deletion, background: palette.deletionBackground))
                    : filler
                let rightLine = i < pendingAdditions.count
                    ? (pendingAdditions[i].text, attributes(color: palette.addition, background: palette.additionBackground))
                    : filler
                appendRow(leftLine, rightLine)
            }
            pendingDeletions = []
            pendingAdditions = []
        }

        if diffLines.isEmpty {
            left.append(NSAttributedString(string: "No changes.", attributes: attributes(color: palette.meta)))
        }
        for line in diffLines {
            switch line.kind {
            case .deletion:
                pendingDeletions.append(line)
            case .addition:
                pendingAdditions.append(line)
            case .fileHeader:
                flushPending()
                sideAnchors.append(left.length + 1) // past the blank spacer line
                appendRow(("\n" + line.text, attributes(color: palette.header)), ("\n" + line.text, attributes(color: palette.header)))
            case .hunkHeader, .meta:
                flushPending()
                appendRow((line.text, attributes(color: palette.meta)), (line.text, attributes(color: palette.meta)))
            case .context:
                flushPending()
                appendRow((line.text, attributes(color: baseColor)), (line.text, attributes(color: baseColor)))
            }
        }
        flushPending()

        leftText.textStorage?.setAttributedString(left)
        rightText.textStorage?.setAttributedString(right)
    }

    @objc func sideScrolled(_ note: Notification) {
        guard !syncingScroll, let moved = note.object as? NSClipView else { return }
        let other = moved === leftScroll.contentView ? rightScroll : leftScroll
        syncingScroll = true
        other.contentView.scroll(to: NSPoint(x: other.contentView.bounds.origin.x, y: moved.bounds.origin.y))
        other.reflectScrolledClipView(other.contentView)
        syncingScroll = false
    }
}
