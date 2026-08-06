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

/// How a dock leaves the screen.
///
/// This used to be decided by which edge it was: the notch was a peek and a
/// side dock stayed until dismissed. That is still what each edge does by
/// default, but it was never really a fact about the edge — it is a fact about
/// how someone works. Reaching across the screen past a pinned side dock is
/// annoying; a notch that vanishes while you read it is worse.
enum DockDismissal: String, Codable, CaseIterable {
    /// Closes when the pointer leaves, or on a click elsewhere.
    case autoHide
    /// Stays until dismissed on purpose: dragged shut by its handle, or Escape.
    case pinned

    var displayName: String {
        switch self {
        case .autoHide: return "Auto-hide"
        case .pinned: return "Pinned"
        }
    }
}

extension DockEdge {
    /// What this edge did before the choice existed. Kept as the default so
    /// nobody's dock changes behaviour under them on the update that adds it.
    var defaultDismissal: DockDismissal {
        self == .top ? .autoHide : .pinned
    }
}

/// Which items sit on which edge, in what order, and how each edge closes.
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
    /// Absent means "whatever this edge does by default" — the same
    /// absent-rather-than-present-and-default rule `placement` follows, so a
    /// user who never touched this writes nothing.
    @Published private(set) var dismissals: [DockEdge: DockDismissal] = [:]
    var onChange: (() -> Void)?

    static let defaultsKey = "com.nugumi.app.dock.v1"
    static let dismissalsDefaultsKey = "com.nugumi.app.dock.dismissal.v1"

    private let defaults: UserDefaults

    /// Injectable so tests run against a scratch suite rather than the user's
    /// real dock — the pattern `BuiltInOverridesStore` already uses.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        // Its own call, not a line at the end of `load()`: that function
        // returns early when no placement has ever been saved, which would
        // silently drop this setting for anyone whose dock is empty.
        loadDismissals()
    }

    func items(on edge: DockEdge) -> [String] {
        placement[edge] ?? []
    }

    func dismissal(on edge: DockEdge) -> DockDismissal {
        dismissals[edge] ?? edge.defaultDismissal
    }

    /// `onChange` fires like every other write here. The controllers read this
    /// live, but the drag handle is installed with the panel, so an edge whose
    /// setting changed while its dock was open would otherwise carry the wrong
    /// affordance until the next time it opened.
    func setDismissal(_ value: DockDismissal, on edge: DockEdge) {
        guard dismissal(on: edge) != value else { return }
        dismissals[edge] = value == edge.defaultDismissal ? nil : value
        save()
        onChange?()
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

    /// Moves `id` to `edge`, landing at `index` in the tab order there.
    ///
    /// `index` names the position `id` occupies in the edge's list **as it
    /// will look after the move** — not an offset into the list as it looked
    /// before `id` was pulled out. `id` is removed from every edge first,
    /// then `index` is clamped against whatever remains and inserted there.
    /// No separate correction is applied for the item's own removal: the
    /// clamp against that already-reduced count *is* the whole adjustment.
    ///
    /// This is the detail a caller wiring up SwiftUI's `.onMove(perform:)`
    /// cannot skip straight past: `.onMove`'s `destination` is measured in
    /// the list as it looked *before* the drag, one coordinate space earlier
    /// than what this method expects. Pass it through unconverted and
    /// forward drags land one short of where the user dropped them while
    /// backward drags happen to work anyway — which reads as the user's own
    /// hand slipping, not as a bug. Convert first (subtract one from
    /// `destination` when it is past `source`).
    func move(_ id: String, to edge: DockEdge, at index: Int) {
        for existing in DockEdge.allCases {
            placement[existing]?.removeAll { $0 == id }
            if placement[existing]?.isEmpty == true { placement[existing] = nil }
        }
        var ids = placement[edge] ?? []
        let clamped = min(max(index, 0), ids.count)
        ids.insert(id, at: clamped)
        placement[edge] = ids
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
        var migrated = false
        for (key, ids) in raw {
            guard let edge = DockEdge(rawValue: key), !ids.isEmpty else { continue }
            let mapped = ids.map(ToolRef.migratedID(from:))
            if mapped != ids { migrated = true }
            loaded[edge] = mapped
        }
        placement = loaded
        // Written back so the mapping runs once rather than on every launch.
        if migrated { save() }
    }

    /// Lenient in both directions, the same reason `load` above is: an edge or
    /// a mode this version doesn't know is skipped rather than throwing, so one
    /// unknown key cannot take the rest of the dock with it.
    private func loadDismissals() {
        guard let raw = defaults.dictionary(forKey: Self.dismissalsDefaultsKey) as? [String: String]
        else { return }
        var loaded: [DockEdge: DockDismissal] = [:]
        for (key, value) in raw {
            guard let edge = DockEdge(rawValue: key),
                  let mode = DockDismissal(rawValue: value)
            else { continue }
            loaded[edge] = mode
        }
        dismissals = loaded
    }

    private func save() {
        var raw: [String: [String]] = [:]
        for (edge, ids) in placement where !ids.isEmpty {
            raw[edge.rawValue] = ids
        }
        defaults.set(raw, forKey: Self.defaultsKey)

        var modes: [String: String] = [:]
        for (edge, mode) in dismissals where mode != edge.defaultDismissal {
            modes[edge.rawValue] = mode.rawValue
        }
        defaults.set(modes, forKey: Self.dismissalsDefaultsKey)
    }
}
