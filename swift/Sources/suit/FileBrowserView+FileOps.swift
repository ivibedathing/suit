import Cocoa

extension FileBrowserView {
    // MARK: - Context menu

    func contextMenu(for event: NSEvent) -> NSMenu? {
        guard index != nil else { return nil }
        let point = outlineView.convert(event.locationInWindow, from: nil)
        let row = outlineView.row(at: point)
        let node = row >= 0 ? outlineView.item(atRow: row) as? FileNode : nil

        let menu = NSMenu()
        addItem(to: menu, title: "New File…", action: #selector(menuNewFile(_:)), node: node)
        addItem(to: menu, title: "New Folder…", action: #selector(menuNewFolder(_:)), node: node)
        if let node {
            menu.addItem(.separator())
            addItem(to: menu, title: "Rename…", action: #selector(menuRename(_:)), node: node)
            addItem(to: menu, title: "Duplicate", action: #selector(menuDuplicate(_:)), node: node)
            addItem(to: menu, title: "Move to Trash", action: #selector(menuTrash(_:)), node: node)
        }
        menu.addItem(.separator())
        addItem(to: menu, title: "Reveal in Finder", action: #selector(menuReveal(_:)), node: node)
        return menu
    }

    @discardableResult
    private func addItem(to menu: NSMenu, title: String, action: Selector, node: FileNode?) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = node
        return item
    }

    // MARK: - Menu actions

    @objc private func menuNewFile(_ sender: NSMenuItem) {
        let directory = newItemDirectory(for: sender.representedObject as? FileNode)
        OverlayPromptController.shared.ask(caption: "New File", placeholder: "filename.swift", over: window) { [weak self] name in
            self?.createFile(named: name, in: directory)
        }
    }

    @objc private func menuNewFolder(_ sender: NSMenuItem) {
        let directory = newItemDirectory(for: sender.representedObject as? FileNode)
        OverlayPromptController.shared.ask(caption: "New Folder", placeholder: "folder", over: window) { [weak self] name in
            self?.createFolder(named: name, in: directory)
        }
    }

    @objc private func menuRename(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode else { return }
        let source = absolute(node.relativePath)
        OverlayPromptController.shared.ask(caption: "Rename", text: node.name, over: window) { [weak self] name in
            self?.rename(node: node, from: source, to: name)
        }
    }

    @objc private func menuDuplicate(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode else { return }
        let source = absolute(node.relativePath)
        let directory = (source as NSString).deletingLastPathComponent
        let base = (node.name as NSString).deletingPathExtension
        let ext = (node.name as NSString).pathExtension
        let fm = FileManager.default
        // …copy, …copy 2, … until a free name.
        var candidate = ""
        var attempt = 1
        repeat {
            let suffix = attempt == 1 ? " copy" : " copy \(attempt)"
            let name = ext.isEmpty ? base + suffix : base + suffix + "." + ext
            candidate = directory + "/" + name
            attempt += 1
        } while fm.fileExists(atPath: candidate)
        do {
            try fm.copyItem(atPath: source, toPath: candidate)
        } catch {
            NSSound.beep()
            return
        }
        index?.rescan()
    }

    @objc private func menuTrash(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode else { return }
        let url = URL(fileURLWithPath: absolute(node.relativePath))
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            NSSound.beep()
            return
        }
        if node.isDirectory {
            createdDirectories = createdDirectories.filter { $0 != node.relativePath && !$0.hasPrefix(node.relativePath + "/") }
        }
        index?.rescan()
        rebuild()
    }

    @objc private func menuReveal(_ sender: NSMenuItem) {
        let node = sender.representedObject as? FileNode
        let path = node.map { absolute($0.relativePath) } ?? rootPath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - File operations

    private func createFile(named rawName: String, in directory: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let destination = directory + "/" + name
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination) else { NSSound.beep(); return }
        // A name like "sub/file.txt" creates the intermediate folders too.
        let parent = (destination as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        guard fm.createFile(atPath: destination, contents: nil) else { NSSound.beep(); return }
        index?.rescan()
        onOpenFile?(destination)
    }

    private func createFolder(named rawName: String, in directory: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let destination = directory + "/" + name
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination) else { NSSound.beep(); return }
        do {
            try fm.createDirectory(atPath: destination, withIntermediateDirectories: true)
        } catch {
            NSSound.beep()
            return
        }
        // Empty folders aren't in the index, so track and inject it, then
        // rebuild for instant feedback (rescan alone wouldn't surface it).
        if let rel = relative(destination) {
            createdDirectories.insert(rel)
            rebuild()
            expandDirectory(rel)
        }
    }

    private func rename(node: FileNode, from source: String, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != node.name else { return }
        let destination = (source as NSString).deletingLastPathComponent + "/" + name
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination) else { NSSound.beep(); return }
        do {
            try fm.moveItem(atPath: source, toPath: destination)
        } catch {
            NSSound.beep()
            return
        }
        if node.isDirectory, let newRel = relative(destination) {
            remapCreatedDirectories(from: node.relativePath, to: newRel)
        }
        index?.rescan()
        rebuild()
    }

    // Keep injected empty folders visible after a folder they live under is
    // moved or renamed by rewriting their path prefix.
    func remapCreatedDirectories(from oldRel: String, to newRel: String) {
        createdDirectories = Set(createdDirectories.map { rel in
            if rel == oldRel { return newRel }
            if rel.hasPrefix(oldRel + "/") { return newRel + String(rel.dropFirst(oldRel.count)) }
            return rel
        })
    }

    // Expand a folder and all its ancestors so a just-created child is visible.
    private func expandDirectory(_ relativePath: String) {
        func find(_ rel: String) -> FileNode? {
            var stack = rootNodes
            while let node = stack.popLast() {
                if node.relativePath == rel { return node }
                stack.append(contentsOf: node.children)
            }
            return nil
        }
        var path = ""
        for component in relativePath.split(separator: "/") {
            path = path.isEmpty ? String(component) : path + "/" + component
            if let node = find(path), node.isDirectory {
                outlineView.expandItem(node)
            }
        }
    }
}
