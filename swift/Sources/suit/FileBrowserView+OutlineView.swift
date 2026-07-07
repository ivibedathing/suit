import Cocoa

extension FileBrowserView {
    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else { return rootNodes.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode else { return rootNodes[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    // MARK: - Drag & drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? FileNode else { return nil }
        // The file URL doubles as the drag payload (identifying the row for an
        // internal move) and as what Finder reads for a drag-out copy.
        return URL(fileURLWithPath: absolute(node.relativePath)) as NSURL
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex childIndex: Int) -> NSDragOperation {
        guard let sources = draggedFileURLs(info) else { return [] }
        // Only folders (and the root) are drop targets; retarget a drop that
        // lands on a file to its parent, and always "drop on" — the tree is
        // sorted, not manually ordered, so there's no between-rows insert.
        let destinationNode: FileNode?
        if let node = item as? FileNode {
            destinationNode = node.isDirectory ? node : node.parent
        } else {
            destinationNode = nil
        }
        outlineView.setDropItem(destinationNode, dropChildIndex: NSOutlineViewDropOnItemIndex)

        let destination = absolute(destinationNode?.relativePath ?? "")
        var anyValid = false
        var anyExternal = false
        for source in sources.map(\.path) {
            guard isValidMove(source: source, intoDirectory: destination) else { continue }
            anyValid = true
            if !source.hasPrefix(rootPath + "/") { anyExternal = true }
        }
        guard anyValid else { return [] }
        // Files from inside the project move; files dragged in from elsewhere
        // are copied so nothing leaves its original home unexpectedly.
        return anyExternal ? .copy : .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex: Int) -> Bool {
        guard let sources = draggedFileURLs(info) else { return false }
        let destinationNode = item as? FileNode  // always a directory (retargeted) or root
        let destination = absolute(destinationNode?.relativePath ?? "")
        let fm = FileManager.default
        var moved = false
        for source in sources.map(\.path) {
            guard isValidMove(source: source, intoDirectory: destination) else { continue }
            let target = destination + "/" + (source as NSString).lastPathComponent
            do {
                if source.hasPrefix(rootPath + "/") {
                    try fm.moveItem(atPath: source, toPath: target)
                    if let oldRel = relative(source), let newRel = relative(target) {
                        remapCreatedDirectories(from: oldRel, to: newRel)
                    }
                } else {
                    try fm.copyItem(atPath: source, toPath: target)
                }
                moved = true
            } catch {
                NSSound.beep()
            }
        }
        guard moved else { return false }
        index?.rescan()
        rebuild()
        if let destinationNode {
            outlineView.expandItem(destinationNode)
        }
        return true
    }

    private func draggedFileURLs(_ info: NSDraggingInfo) -> [URL]? {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        guard let urls, !urls.isEmpty else { return nil }
        return urls
    }

    // A move/copy is valid when the source isn't already in the destination,
    // nothing there would be clobbered, and a folder isn't dropped into itself
    // or one of its own descendants.
    private func isValidMove(source: String, intoDirectory destination: String) -> Bool {
        let target = destination + "/" + (source as NSString).lastPathComponent
        if source == target { return false }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: source, isDirectory: &isDir)
        if isDir.boolValue, (destination + "/").hasPrefix(source + "/") { return false }
        if FileManager.default.fileExists(atPath: target) { return false }
        return true
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("hoverRow")
        if let view = outlineView.makeView(withIdentifier: identifier, owner: self) as? HoverRowView {
            return view
        }
        let created = HoverRowView(frame: .zero)
        created.identifier = identifier
        return created
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("fileRow")
        let view = outlineView.makeView(withIdentifier: identifier, owner: self) as? FileRowView ?? {
            let created = FileRowView(frame: .zero)
            created.identifier = identifier
            return created
        }()
        view.configure(with: node, gitStatus: gitStatus(for: node))
        return view
    }

    private func gitStatus(for node: FileNode) -> Character? {
        guard let gitMonitor else { return nil }
        let path = gitPathPrefix + node.relativePath
        if node.isDirectory {
            return gitMonitor.changedDirectories.contains(path) ? "•" : nil
        }
        return gitMonitor.statusByPath[path]
    }
}
