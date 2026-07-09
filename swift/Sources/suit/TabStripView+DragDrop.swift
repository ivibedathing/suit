import Cocoa

extension TabStripView {
    // MARK: - Drag start

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation else { return }
        guard hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        mouseDownLocation = nil

        let startPoint = convert(start, from: nil)
        // Background drags are inert: the title bar above owns window moves.
        guard let id = tabId(at: startPoint),
              let tab = tabsProvider().first(where: { $0.id == id }) else { return }
        draggedTabId = id
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(id, forType: .suitTab)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        // Preview as a pane header, matching a pane drag — the drag makes clear
        // the tab can become its own pane. Centered under the cursor, and small
        // enough (just the header) not to hide the drop indicator beneath it.
        let preview = PaneTitleBarView.dragPreviewImage(for: tab)
        let frame = NSRect(
            x: startPoint.x - preview.size.width / 2,
            y: startPoint.y - preview.size.height / 2,
            width: preview.size.width,
            height: preview.size.height
        )
        draggingItem.setDraggingFrame(frame, contents: preview)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    // MARK: - Drag source

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .generic : []
    }

    // A drag that ended on no target: if it left every Suit window, tear the
    // tab off into its own window at the drop point (browser behavior).
    // An Esc-cancelled drag also ends with operation == [] — the cancel
    // keystroke is still NSApp.currentEvent here, and cancelling must not
    // tear anything off.
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        defer { draggedTabId = nil }
        guard operation == [], let id = draggedTabId else { return }
        if let event = NSApp.currentEvent, event.type == .keyDown, event.keyCode == 53 {
            return
        }
        let overSuitWindow = NSApp.windows.contains { window in
            window.isVisible && window.frame.contains(screenPoint)
        }
        if !overSuitWindow {
            onTearOff?(id, screenPoint)
        }
    }

    // MARK: - Drop target (reorder within, or adopt from another window)

    private func updateDropCaret(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.string(forType: .suitTab) != nil else {
            dropCaret.isHidden = true
            return []
        }
        let point = convert(sender.draggingLocation, from: nil)
        let index = insertionIndex(atX: point.x)
        let x: CGFloat
        if index < orderedItems.count {
            x = orderedItems[index].frame.minX - 2
        } else if let last = orderedItems.last {
            x = last.frame.maxX + 1
        } else {
            x = Self.leftInset
        }
        dropCaret.frame = NSRect(x: x, y: 5, width: 2, height: bounds.height - 10)
        dropCaret.isHidden = false
        return .generic
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropCaret(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropCaret(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropCaret.isHidden = true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropCaret.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropCaret.isHidden = true
        guard let id = sender.draggingPasteboard.string(forType: .suitTab) else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        return onDropTab?(id, insertionIndex(atX: point.x)) ?? false
    }
}
