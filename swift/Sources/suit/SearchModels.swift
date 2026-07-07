import Cocoa

// Where a search looks (ROADMAP Phase 2 "scope control"): the whole project,
// the sub-project the focused pane is in, or just the pane's cwd. For monorepos
// this is the difference between usable and noise. The window controller
// resolves each case to a concrete directory at search time (scopeResolver),
// since "current pane" changes from moment to moment.
enum SearchScope: Int, CaseIterable {
    case project
    case subproject
    case paneDirectory

    var label: String {
        switch self {
        case .project: return "Project"
        case .subproject: return "Sub-project"
        case .paneDirectory: return "Pane Directory"
        }
    }
}

// One file's worth of results in the outline. Equality follows the path (like
// FileNode) so reloadData preserves expansion state while batches stream in
// and groups are mutated in place.
final class SearchFileGroup: NSObject {
    let relativePath: String
    var matches: [SearchMatchNode] = []

    init(relativePath: String) {
        self.relativePath = relativePath
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? SearchFileGroup)?.relativePath == relativePath
    }

    override var hash: Int { relativePath.hashValue }
}

// NSOutlineView items must be objects; this wraps one SearchMatch.
final class SearchMatchNode: NSObject {
    let match: SearchMatch
    init(match: SearchMatch) {
        self.match = match
    }
}
