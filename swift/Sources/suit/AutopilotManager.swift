import Foundation

// The Autopilot manager: the registry that lets several autopilots run at
// once, one per git repo. Each AutopilotEngine drives a single project root
// (with its own per-repo store under ~/.suit/autopilot/repos/<slug>/); the
// manager owns the set of them, ticks them all off AppDelegate's 3 s
// heartbeat, and enforces the one invariant the shared Claude budget demands:
// at most one instance holds a live run at a time (§budget "one active worker
// at a time"). The others sit in idle/queued and take the slot the moment it
// frees.
//
// Instances are born two ways: the configured primary project root (Settings ▸
// Autopilot) auto-adopts/auto-runs on launch as before, and "Autopilot: Start
// Here" spins one up for the active tab's repo on demand. A persisted repo
// slot (state.json on disk) is re-adopted on the next launch so a running
// autopilot survives a restart.
final class AutopilotManager {
    static let shared = AutopilotManager()

    // Set once in applicationDidFinishLaunching; propagated to every engine.
    weak var appDelegate: AppDelegate? {
        didSet { engines.values.forEach { $0.appDelegate = appDelegate } }
    }

    // Keyed by normalized project root — one engine per repo.
    private var engines: [String: AutopilotEngine] = [:]

    private init() {}

    // MARK: - Root normalization

    // Collapse the common spellings of one repo path (tilde, trailing slash) to
    // a single key so the same repo doesn't spawn two engines or two store
    // slots. Deliberately does NOT run through URL.standardizedFileURL: on macOS
    // that rewrites the `/private` symlink (`/private/tmp` → `/tmp`), which
    // would make run.worktreePath disagree with the worker shell's resolved cwd
    // and break session pinning. The root is otherwise used verbatim, exactly
    // as the old single-autopilot path did with autopilotProjectRoot.
    static func normalize(_ root: String) -> String {
        var expanded = (root as NSString).expandingTildeInPath
        while expanded.count > 1 && expanded.hasSuffix("/") { expanded = String(expanded.dropLast()) }
        return expanded
    }

    // MARK: - Instance registry

    // Get-or-create the engine for a repo. Never nil for a non-empty root.
    @discardableResult
    func engine(for root: String) -> AutopilotEngine {
        let key = Self.normalize(root)
        if let existing = engines[key] { return existing }
        let engine = AutopilotEngine(projectRoot: key)
        engine.appDelegate = appDelegate
        engines[key] = engine
        return engine
    }

    func existingEngine(for root: String) -> AutopilotEngine? {
        engines[Self.normalize(root)]
    }

    // All engines, ordered for a stable dashboard/list display.
    var allEngines: [AutopilotEngine] {
        engines.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var activeEngines: [AutopilotEngine] { allEngines.filter { $0.isActive } }

    // MARK: - One-active-run gate (shared Claude budget)

    // May this engine take the single active-run slot? Only if no OTHER engine
    // currently holds it. This is the whole of the "one active worker at a
    // time" policy — an occupied slot keeps every idle sibling queued.
    func mayEngineBeginRun(_ engine: AutopilotEngine) -> Bool {
        for other in engines.values where other !== engine {
            if other.isOccupyingRunSlot { return false }
        }
        return true
    }

    var runningCount: Int { engines.values.filter { $0.isOccupyingRunSlot }.count }

    // MARK: - Tick (main queue, every 3 s)

    func tick() {
        // Snapshot: an engine may transition (and the dashboard may Stop one)
        // mid-loop, but the dictionary itself isn't mutated during a tick.
        for engine in engines.values { engine.tick() }
    }

    // MARK: - Launch adoption

    // Re-establish every autopilot that was live before the last quit: migrate
    // the legacy single-autopilot layout into the primary repo's slot, ensure
    // the configured primary engine exists, then re-create an engine for each
    // persisted repo slot and adopt them all (§2.2 truth table, per engine).
    func adoptOnLaunch() {
        let primary = Self.normalize(appDelegate?.autopilotProjectRoot ?? "")
        if !primary.isEmpty {
            AutopilotStore.migrateLegacyIfNeeded(primaryRoot: primary)
            engine(for: primary)
        }
        for slug in AutopilotStore.persistedRepoSlugs() {
            guard let root = AutopilotStore.projectRoot(forSlug: slug) else { continue }
            let key = Self.normalize(root)
            guard !key.isEmpty, engines[key] == nil else { continue }
            engine(for: key)
        }
        for engine in engines.values { engine.adoptOnLaunch() }
    }

    // Settings that are global (mode, ceilings, stall, extra args, …) changed —
    // poke every engine so the next decision reflects them without a throttle.
    func settingsChangedAll() {
        // The primary root may have just been set/changed: ensure its engine.
        let primary = Self.normalize(appDelegate?.autopilotProjectRoot ?? "")
        if !primary.isEmpty, appDelegate?.autopilotEnabled == true {
            engine(for: primary)
        }
        engines.values.forEach { $0.settingsChanged() }
    }

    // MARK: - Start Here (active tab's repo)

    enum StartResult {
        case started(AutopilotEngine)
        case alreadyRunning(AutopilotEngine)
        case notAGitRepo
        case noRoadmap(root: String)
        case notEnabled
    }

    // Resolve a directory (the active tab's cwd) up to its git root, require a
    // ROADMAP.md there, and stand up (or focus) an autopilot for it. The engine
    // is persisted immediately so it survives a relaunch even before its first
    // run.
    @discardableResult
    func startHere(directory: String) -> StartResult {
        guard appDelegate?.autopilotEnabled == true else { return .notEnabled }
        guard let gitRoot = FileIndex.gitRoot(of: directory) else { return .notAGitRepo }
        let key = Self.normalize(gitRoot)
        guard FileManager.default.fileExists(atPath: key + "/ROADMAP.md") else {
            return .noRoadmap(root: key)
        }
        if let existing = engines[key], existing.isActive {
            return .alreadyRunning(existing)
        }
        let engine = engine(for: key)
        engine.store.markActive()
        engine.store.log("Start Autopilot Here — \(key)")
        engine.activate()
        return .started(engine)
    }

    // MARK: - Per-instance control (dashboard / palette)

    // Stop an instance for good: park it, drop its run memory, and delete its
    // persisted slot so it isn't re-adopted next launch. The worktree/branch of
    // any in-flight run is left in place (the user Stops to take it over
    // manually) — Skip Current Phase is the path that also tears those down.
    func stop(_ engine: AutopilotEngine) {
        engine.deactivateAndForget()
        engines[engine.projectRoot] = nil
    }

    // The engine that owns a given worker tab (the tabProcessDidExit intercept
    // and notification click-through both need to find the right instance).
    func engineOwningTab(withId id: String) -> AutopilotEngine? {
        engines.values.first { $0.ownsTab(withId: id) }
    }

    // The instance a global (single-target) command or the footer should act
    // on: prefer whichever holds the active-run slot, then the frontmost
    // window's repo, then the configured primary, then any active one.
    func targetEngine(preferredRoot: String? = nil) -> AutopilotEngine? {
        if let running = engines.values.first(where: { $0.isOccupyingRunSlot }) { return running }
        if let preferredRoot, let e = engines[Self.normalize(preferredRoot)], e.isActive { return e }
        let primary = Self.normalize(appDelegate?.autopilotProjectRoot ?? "")
        if !primary.isEmpty, let e = engines[primary], e.isActive { return e }
        return activeEngines.first
    }
}
