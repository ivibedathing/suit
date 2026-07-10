import Cocoa

// Syntax highlighting and minimap wiring for the read-only viewer
//. Split out of FileViewerPane.swift; stored state lives in
// the primary declaration.
extension FileViewerPaneContent {
    // MARK: - Minimap

    func updateMinimapViewport() {
        guard let documentView = scrollView.documentView else { return }
        let docHeight = documentView.frame.height
        guard docHeight > 0 else { return }
        let visible = scrollView.contentView.bounds
        minimap.setViewport(
            start: visible.minY / docHeight,
            end: visible.maxY / docHeight
        )
    }

    func scroll(toFraction fraction: CGFloat) {
        guard let documentView = scrollView.documentView else { return }
        let docHeight = documentView.frame.height
        let visibleHeight = scrollView.contentView.bounds.height
        let target = max(0, min(docHeight - visibleHeight, fraction * docHeight - visibleHeight / 2))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // The minimap shows git-changed regions in orange plus the last jump
    // target in the accent color. Capped so a full-file rewrite doesn't drown
    // the strip in ticks.
    func updateMinimapMarkers() {
        var markers: [MinimapView.Marker] = changedLines.prefix(2_000).map {
            MinimapView.Marker(line: $0, color: Theme.sessionBusy)
        }
        for line in bookmarkedLines {
            markers.append(MinimapView.Marker(line: line, color: Theme.accent))
        }
        if let jumpMarkerLine {
            markers.append(MinimapView.Marker(line: jumpMarkerLine, color: Theme.accent))
        }
        minimap.setMarkers(markers)
    }

    // MARK: - Syntax highlighting

    // Applies syntax colors to the document and rebuilds the minimap. Runs the
    // scan off the main thread for anything nontrivial; the plain text is
    // already on screen, color arrives a beat later.
    func rehighlight() {
        let text = textView.string
        guard let filePath, let language = CodeLanguage.detect(path: filePath),
              (text as NSString).length <= SyntaxHighlighter.maxLength else {
            syntaxSpans = []
            applySyntaxAttributes()
            rebuildMinimap()
            return
        }
        let generation = loadGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let spans = SyntaxHighlighter.highlight(text: text, language: language)
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == generation else { return }
                self.syntaxSpans = spans
                self.applySyntaxAttributes()
                self.rebuildMinimap()
            }
        }
    }

    func applySyntaxAttributes() {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.foregroundColor, range: full)
        storage.addAttribute(.foregroundColor, value: baseTextColor, range: full)
        for span in syntaxSpans where NSMaxRange(span.range) <= storage.length {
            storage.addAttribute(.foregroundColor, value: span.kind.color, range: span.range)
        }
        storage.endEditing()
    }

    func rebuildMinimap() {
        minimap.rebuild(
            text: textView.string,
            lineStarts: lineStarts,
            spans: syntaxSpans,
            baseColor: baseTextColor
        )
        updateMinimapViewport()
    }
}
