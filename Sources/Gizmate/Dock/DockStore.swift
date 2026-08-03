import Combine
import Foundation

/// Which screen edge a dock hangs off.
///
/// No `bottom`: the Dock and every app's window controls already own that edge,
/// and a reveal zone there would fight both.
enum DockEdge: String, Codable, CaseIterable {
    case top
    case left
    case right

    var displayName: String {
        switch self {
        case .top: return "Top"
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

/// Which items sit on which edge, and in what order.
///
/// Same `@Published` + `onChange` contract as `NotesStore` and `SnippetsStore`,
/// so the settings UI binds the same way and the dock controllers get one
/// callback to rebuild from.
///
// ponytail: a plain dictionary in UserDefaults. This is three short arrays of
// short strings; a file under `GizmatePaths` would buy nothing.
@MainActor
final class DockStore: ObservableObject {
    /// Edge to the ids docked there, in tab order. An edge with nothing on it
    /// is absent rather than present-and-empty, so `save` never writes noise.
    @Published private(set) var placement: [DockEdge: [String]] = [:]
    var onChange: (() -> Void)?

    static let defaultsKey = "com.nugumi.app.dock.v1"

    private let defaults: UserDefaults

    /// Injectable so tests run against a scratch suite rather than the user's
    /// real dock — the pattern `BuiltInOverridesStore` already uses.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func items(on edge: DockEdge) -> [String] {
        placement[edge] ?? []
    }

    /// An item lives on at most one edge, so this is a lookup, not a list.
    func edge(of id: String) -> DockEdge? {
        DockEdge.allCases.first { placement[$0]?.contains(id) == true }
    }

    /// Moves `id` to `edge`, or undocks it when `edge` is nil. Removes it from
    /// everywhere first — "at most one edge" is enforced here rather than
    /// trusted of every caller.
    func dock(_ id: String, to edge: DockEdge?) {
        for existing in DockEdge.allCases {
            placement[existing]?.removeAll { $0 == id }
            if placement[existing]?.isEmpty == true { placement[existing] = nil }
        }
        if let edge {
            placement[edge, default: []].append(id)
        }
        save()
        onChange?()
    }

    /// Drops ids nothing resolves any more — a gizmo the user deleted after
    /// docking it. Silent on purpose: the item is gone, and a tab that opens
    /// nothing is worse than a tab that quietly went with it.
    func prune(keeping known: Set<String>) {
        var changed = false
        for edge in DockEdge.allCases {
            guard let ids = placement[edge] else { continue }
            let kept = ids.filter(known.contains)
            guard kept.count != ids.count else { continue }
            placement[edge] = kept.isEmpty ? nil : kept
            changed = true
        }
        guard changed else { return }
        save()
        onChange?()
    }

    // MARK: - Persistence

    private func load() {
        guard let raw = defaults.dictionary(forKey: Self.defaultsKey) as? [String: [String]] else {
            return
        }
        // Lenient, same reasoning as `Note` and `GizmateTool`: an edge this
        // version doesn't know is skipped, not thrown, so one unknown key does
        // not wipe the whole dock.
        var loaded: [DockEdge: [String]] = [:]
        for (key, ids) in raw {
            guard let edge = DockEdge(rawValue: key), !ids.isEmpty else { continue }
            loaded[edge] = ids
        }
        placement = loaded
    }

    private func save() {
        var raw: [String: [String]] = [:]
        for (edge, ids) in placement where !ids.isEmpty {
            raw[edge.rawValue] = ids
        }
        defaults.set(raw, forKey: Self.defaultsKey)
    }
}
