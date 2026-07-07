import Cocoa

extension TabStripView {
    // MARK: - Drag start

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation else { return }
        guard hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        mouseDownLocation = nil

        let startPoint = convert(start, from: nil)
        // Background drags are inert: the title bar above owns window moves.
        guard let id = tabId(at: startPoint), let item = itemViews[id] else { return }
        draggedTabId = id
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(id, forType: .suitTab)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(item.frame, contents: snapshotImage(of: item))
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func snapshotImage(of view: NSView) -> NSImage {
        let image = NSImage(size: view.bounds.size)
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
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
