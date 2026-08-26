import Foundation

/// Bindings for gizmos the user built, beside `GlobalShortcutStore`'s bindings
/// for the built-ins. A separate store because the shapes differ: a built-in
/// always has a key, falling back to its shipped default, while a gizmo has
/// one only when the user recorded it — there is no default to fall back to,
/// so `shortcut(for:)` here is honestly optional.
///
/// Keys are namespaced through `ToolRef.generated(id).storageID`
/// ("globalShortcut.tool.<uuid>"), which cannot collide with an action's
/// "globalShortcut.<rawValue>" key — that prefix discipline is the whole
/// reason `ToolRef` exists. Deliberately UserDefaults rather than a field in
/// tool.json: a binding is placement-shaped state, and an edit or rebuild of
/// the gizmo, which rewrites its manifest, must not be able to touch it.
enum ToolShortcutStore {
    private static let keyPrefix = "globalShortcut.tool."

    static func defaultsKey(for id: UUID) -> String {
        "globalShortcut.\(ToolRef.generated(id).storageID)"
    }

    static func shortcut(for id: UUID, defaults: UserDefaults = .standard) -> GlobalShortcut? {
        guard let data = defaults.data(forKey: defaultsKey(for: id)),
              let shortcut = try? JSONDecoder().decode(GlobalShortcut.self, from: data),
              shortcut.isValid
        else { return nil }
        return shortcut
    }

    static func set(
        _ shortcut: GlobalShortcut,
        for id: UUID,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: defaultsKey(for: id))
    }

    static func clear(for id: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey(for: id))
    }

    /// Every stored binding among `ids`, for one registration pass or one
    /// conflict scan without a defaults read per tool per candidate key.
    static func assignments(
        ids: [UUID],
        defaults: UserDefaults = .standard
    ) -> [UUID: GlobalShortcut] {
        var found: [UUID: GlobalShortcut] = [:]
        for id in ids {
            if let shortcut = shortcut(for: id, defaults: defaults) {
                found[id] = shortcut
            }
        }
        return found
    }

    /// Drops bindings whose gizmo is gone, the way `DockStore.prune` drops
    /// placements. A deleted tool's key must go dead with it, not linger in
    /// defaults waiting for a future tool to inherit a stranger's binding.
    static func prune(keeping ids: Set<UUID>, defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            let id = UUID(uuidString: String(key.dropFirst(keyPrefix.count)))
            guard let id, ids.contains(id) else {
                defaults.removeObject(forKey: key)
                continue
            }
        }
    }
}
