import Cocoa

// Editing, saving and outside-change reconciliation for the file viewer.
// Split out of FileViewerPane.swift like the highlighting/blame/symbol wiring; the
// pure dirty/reconcile decisions live in FileEdit.swift (harness-tested). The
// stored state (editState, timers, savedModificationDate, isEditableFile) is on
// the primary declaration.
extension FileViewerPaneContent: NSTextViewDelegate {

    // MARK: - Live edits

    func textDidChange(_ notification: Notification) {
        guard isEditableFile, !isLoadingProgrammatically else { return }
        let text = textView.string

        // Any in-flight async highlight is now stale — invalidate it so it can't
        // paint spans over shifted text (rehighlight() re-checks loadGeneration).
        loadGeneration += 1

        // Gutter tracks the new line count immediately (cheap, synchronous).
        recomputeLineStarts(for: text)
        ruler.lineStarts = lineStarts
        ruler.updateThickness()
        ruler.needsDisplay = true

        // Dirty flag: repaint the strip + header only on the on/off transition.
        if editState.edited(to: text) {
            tab?.contentDirtyDidChange(editState.isDirty)
            pane?.refreshChrome()
        }

        scheduleAutosave()
        scheduleRehighlight()
    }

    // Re-colour after a short typing pause rather than on every keystroke; the
    // scan itself still runs off-main inside rehighlight().
    private func scheduleRehighlight() {
        rehighlightTimer?.invalidate()
        rehighlightTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            self?.rehighlight()
        }
    }

    // MARK: - Saving

    // Whether ⌘S has anything to do — an editable file with unsaved edits.
    // Drives the File ▸ Save menu item's enabled state.
    var canSave: Bool { isEditableFile && editState.isDirty }

    // ⌘S / palette "Save File": write now, cancelling the pending autosave.
    func save() {
        guard isEditableFile, filePath != nil else { NSSound.beep(); return }
        performSave()
    }

    private func scheduleAutosave() {
        guard isEditableFile, filePath != nil else { return }
        autosaveTimer?.invalidate()
        // 1 s debounce, mirroring NotesStore — keystrokes don't each hit disk.
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            guard let self, self.editState.isDirty else { return }
            self.performSave()
        }
    }

    // Flush a pending edit synchronously — called at quit and before a dirty
    // tab closes, so the sub-second autosave window never loses work.
    @discardableResult
    func flushIfDirty() -> Bool {
        guard isEditableFile, editState.isDirty else { return true }
        return performSave()
    }

    // The atomic write behind every save path. Returns false (and leaves the
    // buffer dirty) if the write failed, so callers can decide what to do.
    @discardableResult
    private func performSave() -> Bool {
        guard let filePath else { return false }
        let text = textView.string

        // Don't clobber an outside change. If the file moved on disk since we
        // last loaded/saved it, reconcile before overwriting instead of blindly
        // winning: an unchanged mtime is the common fast path; a changed mtime
        // whose content still equals our buffer is our own write echoing back
        // (safe to proceed); a changed mtime that diverges from our dirty buffer
        // is a real conflict — hand it to the user rather than silently lose
        // whatever rewrote the file (e.g. a Claude edit to the open file).
        if let saved = savedModificationDate,
           let currentMod = modificationDate(ofPath: filePath),
           saved != currentMod {
            let disk = readableDiskText(atPath: filePath)
            // If disk is unreadable (binary/too-large/non-UTF-8), fall back to
            // treating it as "matches" so an inspectable-only file still saves.
            switch editState.resolveExternalChange(diskText: disk ?? text, bufferText: text) {
            case .ignore:
                break                                   // disk == buffer — proceed to write
            case .reload:
                autosaveTimer?.invalidate(); autosaveTimer = nil
                if let disk { adoptDiskContent(disk) }  // no local edits — adopt disk, don't overwrite
                savedModificationDate = currentMod
                return true
            case .warn:
                autosaveTimer?.invalidate(); autosaveTimer = nil
                presentExternalChangeConflict(diskText: disk ?? "", modDate: currentMod)
                return false                            // let the user decide; don't overwrite
            }
        }

        autosaveTimer?.invalidate(); autosaveTimer = nil
        do {
            try FileEditWriter.write(text, toPath: filePath)
        } catch {
            presentSaveError(error)
            return false
        }
        let wasDirty = editState.isDirty
        editState.markSaved(text)
        savedModificationDate = modificationDate(ofPath: filePath)
        if wasDirty {
            tab?.contentDirtyDidChange(false)
            pane?.refreshChrome()
        }
        // The git changed-line gutter reflects HEAD vs. the file on disk, which
        // just moved — refresh the orange bars/minimap ticks.
        refreshChangedLines()
        return true
    }

    private func presentSaveError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't save \((filePath as NSString?)?.lastPathComponent ?? "file")"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Outside-change reconciliation

    @objc func appBecameActive() {
        reconcileExternalChange()
    }

    // The file may have been rewritten by Claude or $EDITOR while we were away.
    // Compare mtimes first (cheap), then reconcile via the pure decision.
    func reconcileExternalChange() {
        // The scrubber owns the buffer while time-traveling (read-only, showing
        // a historical revision) — never reload disk content over it.
        guard !isTimeTraveling else { return }
        guard isEditableFile, let filePath else { return }
        let currentMod = modificationDate(ofPath: filePath)
        // Unchanged mtime → nothing moved.
        if let saved = savedModificationDate, let currentMod, saved == currentMod { return }
        guard let diskText = readableDiskText(atPath: filePath) else { return }

        switch editState.resolveExternalChange(diskText: diskText, bufferText: textView.string) {
        case .ignore:
            savedModificationDate = currentMod
        case .reload:
            adoptDiskContent(diskText)
            savedModificationDate = currentMod
        case .warn:
            presentExternalChangeConflict(diskText: diskText, modDate: currentMod)
        }
    }

    // Silently adopt the on-disk version (clean buffer), preserving scroll.
    private func adoptDiskContent(_ text: String) {
        let line = firstVisibleLine
        isLoadingProgrammatically = true
        textView.string = text
        isLoadingProgrammatically = false
        loadGeneration += 1
        recomputeLineStarts(for: text)
        ruler.lineStarts = lineStarts
        ruler.updateThickness()
        ruler.needsDisplay = true
        let wasDirty = editState.isDirty
        editState.markLoaded(text)
        if wasDirty {
            tab?.contentDirtyDidChange(false)
            pane?.refreshChrome()
        }
        rehighlight()
        refreshChangedLines()
        scrollTo(firstVisibleLine: line)
    }

    // Unsaved edits vs. a changed disk: the user chooses. Keep-my-edits records
    // the new mtime so the same change doesn't re-prompt; the next save wins.
    private func presentExternalChangeConflict(diskText: String, modDate: Date?) {
        let alert = NSAlert()
        alert.messageText = "\((filePath as NSString?)?.lastPathComponent ?? "This file") changed on disk"
        alert.informativeText = "You have unsaved edits here. Reload the version on disk and lose your edits, or keep editing (your next save overwrites the disk version)?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep My Edits")
        alert.addButton(withTitle: "Reload from Disk")

        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if response == .alertSecondButtonReturn {
                self.adoptDiskContent(diskText)
            }
            // Either way, stop re-prompting for this particular disk change.
            self.savedModificationDate = modDate
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    // MARK: - Helpers

    func modificationDate(ofPath path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // Read the file as an editable text buffer, applying the same guards as
    // load(): nil for missing, too-large, binary (NUL in the first 8 KB), or
    // non-UTF-8 content — none of which we ever treat as an editable buffer, and
    // so none of which a save may overwrite from a UTF-8 text buffer.
    private func readableDiskText(atPath path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              data.count <= 8 * 1024 * 1024, !data.prefix(8192).contains(0),
              let text = String(bytes: data, encoding: .utf8) else { return nil }
        return text
    }
}
