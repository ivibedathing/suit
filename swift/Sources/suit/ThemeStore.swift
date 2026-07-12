import Cocoa

// The theme catalog and selection state behind Suit's swappable `Theme.current`
// palette (see Theme.swift). Built-in palettes ship in code and always exist;
// user themes live one-file-per-theme under ~/.suit/themes/ as ".suittheme"
// JSON, so sharing a theme is literally copying a file. This deliberately
// depends only on Theme.swift + system frameworks (no other app file) so it
// compiles standalone in scripts/test-themes.sh.
//
// Follows the FavoritesStore pattern: `shared` singleton, a `didUpdate`
// notification, $HOME-resolved paths (ProcessInfo HOME so harnesses can sandbox
// them), atomic writes. The selected theme id persists in ~/.suit/theme.json;
// `applySelectedThemeAtLaunch()` loads it into `Theme.current` before the first
// window is built, so the app opens already themed. `apply(id:)` swaps the live
// palette and posts `Theme.didChange` for the central repaint observer.
final class ThemeStore {
    static let shared = ThemeStore()
    static let didUpdate = Notification.Name("ThemeStoreDidUpdate")

    /// A theme as the catalog sees it: a stable `id`, the palette, its author,
    /// and whether it is a built-in (built-ins can't be edited or deleted —
    /// duplicate to get an editable copy). `id` is the on-disk filename stem for
    /// user themes and the name-slug for built-ins; it never changes on rename,
    /// so a renamed user theme keeps its selection and file.
    struct ThemeInfo {
        let id: String
        var palette: Theme.Palette
        var author: String
        let isBuiltIn: Bool
    }

    private var userThemes: [ThemeInfo] = []
    private(set) var selectedId: String?

    /// The shipped palettes as catalog entries, built once (built-ins are a
    /// `static let`, so their infos and reserved ids never change).
    private static let builtInInfos: [ThemeInfo] = Theme.Palette.builtIns.map {
        ThemeInfo(id: slug($0.name), palette: $0, author: "Suit", isBuiltIn: true)
    }
    /// Built-in ids are reserved — a user file can't shadow a built-in.
    private static let builtInIds: Set<String> = Set(builtInInfos.map { $0.id })

    private init() {
        loadUserThemes()
        selectedId = loadSelection()
    }

    // MARK: - Paths ($HOME-resolved so harnesses can sandbox them)

    private var suitDir: URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home + "/.suit")
    }
    private var themesDir: URL { suitDir.appendingPathComponent("themes", isDirectory: true) }
    private var selectionURL: URL { suitDir.appendingPathComponent("theme.json") }

    private func fileURL(forUserId id: String) -> URL {
        themesDir.appendingPathComponent(id + ".suittheme")
    }

    // MARK: - Catalog

    /// Built-ins (in display order, not editable) followed by user themes sorted
    /// by display name (case-insensitive). Rebuilt from `Theme.Palette.builtIns`
    /// each call so it always reflects the shipped set.
    var allThemes: [ThemeInfo] {
        let users = userThemes.sorted {
            $0.palette.name.localizedCaseInsensitiveCompare($1.palette.name) == .orderedAscending
        }
        return Self.builtInInfos + users
    }

    func theme(id: String) -> ThemeInfo? { allThemes.first { $0.id == id } }

    /// The active theme's info — the selection if it resolves, else the first
    /// built-in (Suit Dark).
    var selected: ThemeInfo {
        if let id = selectedId, let t = theme(id: id) { return t }
        return Self.builtInInfos[0]  // Suit Dark; built-ins are never empty
    }

    // MARK: - Launch

    /// Load the persisted selection into `Theme.current` before any window is
    /// built. No `didChange` is posted — nothing has drawn yet, so there is
    /// nothing to repaint; windows read the palette fresh on first draw.
    func applySelectedThemeAtLaunch() {
        // `init` (first `shared` access) already loaded the user themes and the
        // persisted selection; just push the resolved palette live.
        Theme.current = selected.palette
    }

    // MARK: - Apply / persist selection

    /// Swap the live palette to theme `id`, persist the selection, and post
    /// `Theme.didChange` (repaint) + `didUpdate` (catalog/selection changed).
    /// A no-op for an unknown id.
    @discardableResult
    func apply(id: String) -> Bool {
        guard let t = theme(id: id) else { return false }
        Theme.current = t.palette
        selectedId = id
        saveSelection(id)
        NotificationCenter.default.post(name: Theme.didChange, object: self)
        NotificationCenter.default.post(name: Self.didUpdate, object: self)
        return true
    }

    // MARK: - Duplicate / update / delete (user themes)

    /// Turn any theme (built-in or user) into a new editable user theme written
    /// to disk, and return it. The copy gets a fresh, unique id and a "Copy"
    /// name so it never collides with its source.
    @discardableResult
    func duplicate(id: String) -> ThemeInfo? {
        guard let source = theme(id: id) else { return nil }
        let name = source.palette.name + " Copy"
        let newId = uniqueSlug(for: name)
        var palette = source.palette
        palette.name = name
        let info = ThemeInfo(id: newId, palette: palette, author: source.author, isBuiltIn: false)
        writeUserTheme(info)
        loadUserThemes()
        NotificationCenter.default.post(name: Self.didUpdate, object: self)
        return theme(id: newId) ?? info
    }

    /// Persist edits to a user theme (colors, name, author). Built-ins are
    /// immutable and ignored. `id` is stable across renames, so the display name
    /// can change while the file and selection stay put. If the edited theme is
    /// the active one, the live palette is refreshed too.
    func update(_ theme: ThemeInfo) {
        guard !theme.isBuiltIn else { return }
        writeUserTheme(theme)
        loadUserThemes()
        if selectedId == theme.id {
            Theme.current = theme.palette
            NotificationCenter.default.post(name: Theme.didChange, object: self)
        }
        NotificationCenter.default.post(name: Self.didUpdate, object: self)
    }

    /// Delete a user theme's file. Built-ins can't be deleted (ignored). If the
    /// deleted theme was selected, fall back to the first built-in and apply it.
    func delete(id: String) {
        guard let t = theme(id: id), !t.isBuiltIn else { return }
        try? FileManager.default.removeItem(at: fileURL(forUserId: id))
        loadUserThemes()
        if selectedId == id {
            apply(id: Self.builtInInfos[0].id)  // fall back to Suit Dark
        } else {
            NotificationCenter.default.post(name: Self.didUpdate, object: self)
        }
    }

    // MARK: - Import / export (.suittheme files)

    /// Copy an external `.suittheme` into the store as a new user theme and
    /// return it. The imported theme gets a unique id derived from its name so
    /// it never overwrites an existing theme. Returns nil if the file can't be
    /// decoded.
    @discardableResult
    func importTheme(from url: URL) -> ThemeInfo? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(ThemeFile.self, from: data) else { return nil }
        let newId = uniqueSlug(for: file.palette.name)
        let info = ThemeInfo(id: newId, palette: file.palette, author: file.author, isBuiltIn: false)
        writeUserTheme(info)
        loadUserThemes()
        NotificationCenter.default.post(name: Self.didUpdate, object: self)
        return theme(id: newId) ?? info
    }

    /// Write theme `id`'s `.suittheme` file to an arbitrary location (for
    /// sharing). Returns false for an unknown id or a write failure.
    @discardableResult
    func exportTheme(id: String, to url: URL) -> Bool {
        guard let t = theme(id: id) else { return false }
        let file = ThemeFile(palette: t.palette, author: t.author)
        guard let data = try? Self.encoder.encode(file) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    // MARK: - Disk IO

    private func loadUserThemes() {
        var loaded: [ThemeInfo] = []
        let files = (try? FileManager.default.contentsOfDirectory(
            at: themesDir, includingPropertiesForKeys: nil
        )) ?? []
        for url in files where url.pathExtension == "suittheme" {
            let id = url.deletingPathExtension().lastPathComponent
            guard !Self.builtInIds.contains(id) else { continue }
            guard let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(ThemeFile.self, from: data) else { continue }
            loaded.append(ThemeInfo(
                id: id, palette: file.palette, author: file.author, isBuiltIn: false
            ))
        }
        userThemes = loaded
    }

    private func writeUserTheme(_ theme: ThemeInfo) {
        try? FileManager.default.createDirectory(
            at: themesDir, withIntermediateDirectories: true
        )
        let file = ThemeFile(palette: theme.palette, author: theme.author)
        if let data = try? Self.encoder.encode(file) {
            try? data.write(to: fileURL(forUserId: theme.id), options: .atomic)
        }
    }

    private struct Selection: Codable { var selected: String? }

    private func loadSelection() -> String? {
        guard let data = try? Data(contentsOf: selectionURL),
              let sel = try? JSONDecoder().decode(Selection.self, from: data) else { return nil }
        return sel.selected
    }

    private func saveSelection(_ id: String) {
        try? FileManager.default.createDirectory(
            at: suitDir, withIntermediateDirectories: true
        )
        if let data = try? Self.encoder.encode(Selection(selected: id)) {
            try? data.write(to: selectionURL, options: .atomic)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    // MARK: - Slug

    /// A filesystem/id-safe slug: lowercase, non-alphanumerics collapsed to
    /// single dashes, trimmed. Empty input (or all-punctuation) yields "theme".
    static func slug(_ name: String) -> String {
        var out = ""
        var lastDash = false
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "theme" : trimmed
    }

    /// A slug unique across built-ins and existing user themes (appends -2, -3…).
    private func uniqueSlug(for name: String) -> String {
        let base = Self.slug(name)
        var taken = Self.builtInIds
        taken.formUnion(userThemes.map(\.id))
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}

// MARK: - .suittheme file format

/// The on-disk shape of a shared theme: `{ name, author, schema, colors }`,
/// where `colors` is the palette's `"#RRGGBB"` token set. Reuses
/// `Theme.Palette`'s Codable for the nested `colors`, so per-token fallback,
/// hex parsing, and unknown-color-key tolerance all come for free. Unknown
/// top-level keys are ignored on decode (forward-compat). `schema` records the
/// format version (1); missing/other metadata falls back gracefully.
struct ThemeFile: Codable {
    var palette: Theme.Palette
    var author: String
    var schema: Int

    init(palette: Theme.Palette, author: String, schema: Int = 1) {
        self.palette = palette
        self.author = author
        self.schema = schema
    }

    private enum CodingKeys: String, CodingKey { case name, author, schema, colors }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        author = (try? c.decode(String.self, forKey: .author)) ?? ""
        schema = (try? c.decode(Int.self, forKey: .schema)) ?? 1
        // `colors` decodes as a Palette (per-token fallback happens inside it);
        // an absent/invalid `colors` object yields the all-default Suit Dark set.
        var p = (try? c.decode(Theme.Palette.self, forKey: .colors)) ?? .suitDark
        // The top-level `name` is authoritative for the display name.
        p.name = (try? c.decode(String.self, forKey: .name)) ?? p.name
        palette = p
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(palette.name, forKey: .name)
        try c.encode(author, forKey: .author)
        try c.encode(schema, forKey: .schema)
        try c.encode(palette, forKey: .colors)
    }
}
