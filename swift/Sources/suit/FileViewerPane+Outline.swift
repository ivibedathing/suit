import Cocoa

// The file’s symbol outline: ⌃⌘O to jump to a symbol in this file, and the
// breadcrumb strip above the text showing which symbol the caret is inside.
// Both read the same OutlineEntry list, built by SymbolOutline (pure,
// harness-tested) from the ctags index go-to-definition already maintains — so
// the outline costs one dictionary walk, not a second parse of the file.
extension FileViewerPaneContent {

    // MARK: - Building

    @objc func symbolIndexChanged(_ note: Notification) {
        // Only this file's project matters; a rebuild for some other repo open
        // in another window is not our business.
        guard let index = note.object as? SymbolIndex,
              let filePath, filePath.hasPrefix(index.root + "/") else { return }
        refreshOutline()
    }

    // Rebuild the outline for the open file. Cheap enough to call on load and on
    // every index refresh; deliberately *not* called per keystroke, because the
    // index it reads only moves when ctags re-runs.
    func refreshOutline() {
        guard let filePath, let directory = workingDirectory else {
            outlineEntries = []
            updateBreadcrumb()
            return
        }
        let index = SymbolIndex.shared(forDirectory: directory)
        let relative = relativePath(of: filePath, inRoot: index.root)
        outlineEntries = SymbolOutline.entries(
            definitions: index.byName,
            relativePath: relative,
            fileText: textView.string
        )
        updateBreadcrumb()
    }

    // ctags paths are root-relative; ours is absolute. Files outside the index
    // root (a scratch file, /etc/hosts) simply match nothing, which is correct.
    private func relativePath(of path: String, inRoot root: String) -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    // MARK: - ⌃⌘O

    func showSymbolOutline() {
        guard !outlineEntries.isEmpty else {
            // An empty outline is almost always a missing ctags rather than a
            // file with no symbols in it — say which.
            presentOutlineUnavailable()
            return
        }
        (NSApp.delegate as? AppDelegate)?.showSymbolOutlinePicker(
            entries: outlineEntries,
            relativeTo: view.window
        ) { [weak self] line in
            self?.jump(toLine: line)
            self?.textView.window?.makeFirstResponder(self?.textView)
        }
    }

    private func presentOutlineUnavailable() {
        let alert = NSAlert()
        alert.messageText = "No symbols in this file"
        alert.informativeText = SymbolIndex.hasCtags
            ? "The symbol index has nothing indexed for this file yet. If it was just created, give the index a moment and try again."
            : "ctags isn't installed, so there's no symbol index. Rebuild the app with universal-ctags on PATH, or set SUIT_CTAGS_PATH."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Breadcrumb

    // Show or hide the strip. Off by default would make it undiscoverable and on
    // for a plain text file would be a permanently empty bar, so it appears
    // exactly when the file has symbols to show.
    func updateBreadcrumb() {
        guard !outlineEntries.isEmpty else {
            if breadcrumbBar != nil {
                breadcrumbBar = nil
                container.breadcrumbBar = nil
            }
            return
        }
        if breadcrumbBar == nil {
            let bar = BreadcrumbBarView(frame: .zero)
            bar.onSelect = { [weak self] line in
                self?.jump(toLine: line)
                self?.textView.window?.makeFirstResponder(self?.textView)
            }
            breadcrumbBar = bar
            container.breadcrumbBar = bar
        }
        breadcrumbBar?.setTrail(
            fileName: (filePath as NSString?)?.lastPathComponent ?? "",
            entries: SymbolOutline.breadcrumb(for: currentLineNumber(), in: outlineEntries)
        )
    }

    // The caret moved — refresh the breadcrumb, and keep the window's navigation
    // history pointing at where we actually are in this file, so going back
    // returns to the line we left rather than the line we arrived on.
    func textViewDidChangeSelection(_ notification: Notification) {
        updateBreadcrumb()
        if let filePath {
            pane?.noteNavigationLine(currentLineNumber(), inFile: filePath)
        }
    }
}
