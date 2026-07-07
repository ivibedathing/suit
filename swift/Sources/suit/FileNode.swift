import Cocoa

// One row of the Files outline. NSObject equality/hash follow relativePath so
// NSOutlineView can preserve expansion state across the full-tree rebuilds the
// FSEvents-driven index updates cause.
final class FileNode: NSObject {
    let name: String
    let relativePath: String
    let isDirectory: Bool
    // Sub-project language badge ("go", "js", …) for directories that contain
    // a marker file (see FileIndex.subprojectMarkers).
    var badge: String?
    var children: [FileNode] = []
    // The containing directory node, nil for top-level rows. Used by drag-drop
    // to retarget a drop hovering a file onto its parent folder.
    weak var parent: FileNode?

    init(name: String, relativePath: String, isDirectory: Bool) {
        self.name = name
        self.relativePath = relativePath
        self.isDirectory = isDirectory
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? FileNode else { return false }
        return relativePath == other.relativePath && isDirectory == other.isDirectory
    }

    override var hash: Int {
        relativePath.hashValue &* 31 &+ (isDirectory ? 1 : 0)
    }

    // Builds the display tree from the index's flat sorted path list —
    // directories first, then files, both case-insensitively sorted. Working
    // off the index (rather than live FileManager listings) keeps the browser
    // gitignore-consistent with the fuzzy opener for free. `extraDirectories`
    // are folder paths that hold no indexed files (empty folders the user just
    // created); `git ls-files` never reports those, so the browser injects them
    // itself so a fresh New Folder shows up right away.
    static func buildTree(from index: FileIndex, extraDirectories: [String] = []) -> [FileNode] {
        let root = FileNode(name: "", relativePath: "", isDirectory: true)
        var directories: [String: FileNode] = ["": root]

        func directoryNode(for path: String) -> FileNode {
            if let existing = directories[path] {
                return existing
            }
            let parent = directoryNode(for: (path as NSString).deletingLastPathComponent)
            let node = FileNode(name: (path as NSString).lastPathComponent, relativePath: path, isDirectory: true)
            node.badge = index.subprojectBadges[path]
            node.parent = parent === root ? nil : parent
            directories[path] = node
            parent.children.append(node)
            return node
        }

        for path in index.files {
            let parent = directoryNode(for: (path as NSString).deletingLastPathComponent)
            let node = FileNode(name: (path as NSString).lastPathComponent, relativePath: path, isDirectory: false)
            node.parent = parent === root ? nil : parent
            parent.children.append(node)
        }
        // Materialize empty folders (and their ancestor chains) that no file
        // pulled in. Idempotent: a folder already created from a file is reused.
        for path in extraDirectories where !path.isEmpty {
            _ = directoryNode(for: path)
        }

        func sortChildren(_ node: FileNode) {
            node.children.sort {
                if $0.isDirectory != $1.isDirectory {
                    return $0.isDirectory
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            for child in node.children where child.isDirectory {
                sortChildren(child)
            }
        }
        sortChildren(root)
        return root.children
    }
}

// Small SF-Symbol icons for the Files tree: a folder for directories, a
// per-type tinted symbol for files (by extension, with a few well-known
// filenames special-cased). Images are cached per symbol name; the tint is
// applied by the row's image view, so one template image serves every color.
enum FileTreeIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(for node: FileNode) -> (image: NSImage?, tint: NSColor) {
        let (symbol, tint) = descriptor(for: node)
        if let cached = cache[symbol] {
            return (cached, tint)
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        if let image {
            cache[symbol] = image
        }
        return (image, tint)
    }

    private static func descriptor(for node: FileNode) -> (symbol: String, tint: NSColor) {
        if node.isDirectory {
            return ("folder.fill", .systemBlue)
        }
        let code = "chevron.left.forwardslash.chevron.right"
        switch node.name.lowercased() {
        case "makefile", "dockerfile":
            return ("terminal", .systemGreen)
        default:
            break
        }
        switch (node.name as NSString).pathExtension.lowercased() {
        case "swift":
            return ("swift", .systemOrange)
        case "go":
            return (code, .systemTeal)
        case "js", "jsx", "mjs", "cjs":
            return (code, .systemYellow)
        case "ts", "tsx":
            return (code, .systemBlue)
        case "py":
            return (code, .systemGreen)
        case "rb":
            return (code, .systemRed)
        case "c", "h", "m", "mm", "cpp", "hpp", "cc", "rs", "java", "kt":
            return (code, .systemIndigo)
        case "html", "htm":
            return (code, .systemOrange)
        case "css", "scss", "less":
            return (code, .systemBlue)
        case "sh", "bash", "zsh":
            return ("terminal", .systemGreen)
        case "json":
            return ("curlybraces", .systemYellow)
        case "yaml", "yml", "toml", "ini", "conf", "plist", "xml", "entitlements":
            return ("gearshape", .systemPurple)
        case "md", "markdown", "txt", "rst":
            return ("doc.text", Theme.textDim)
        case "pdf":
            return ("doc.richtext", .systemRed)
        case "csv", "tsv":
            return ("tablecells", .systemGreen)
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "icns", "ico", "bmp", "heic":
            return ("photo", .systemPink)
        case "mp4", "mov", "mkv", "avi":
            return ("film", .systemPink)
        case "mp3", "wav", "flac", "m4a", "aiff":
            return ("music.note", .systemPink)
        case "zip", "tar", "gz", "bz2", "xz", "7z", "jar":
            return ("archivebox", .systemBrown)
        default:
            // Dotfiles (.gitignore, .zshrc, …) read as configuration.
            if node.name.hasPrefix(".") {
                return ("gearshape", .systemPurple)
            }
            return ("doc", Theme.textDim)
        }
    }
}
