import Foundation

enum GlobalShortcutStore {
    static func shortcut(
        for action: GlobalShortcutAction,
        defaults: UserDefaults = .standard
    ) -> GlobalShortcut {
        guard let data = defaults.data(forKey: action.defaultsKey),
              let shortcut = try? JSONDecoder().decode(GlobalShortcut.self, from: data),
              shortcut.isValid
        else {
            return action.defaultShortcut
        }
        return shortcut
    }

    static func set(
        _ shortcut: GlobalShortcut,
        for action: GlobalShortcutAction,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(shortcut) else {
            return
        }
        defaults.set(data, forKey: action.defaultsKey)
    }

    /// One-time move of the retired `translateOrReply` binding.
    ///
    /// ⌃⌥T meant "act on the selection using my default mode" back when the
    /// built-ins had no keys of their own. It now lands on the built-in that
    /// mode names, so a user who rebound it keeps their key doing what it did.
    /// Untouched installs need nothing: `explainSelection` already defaults to
    /// ⌃⌥T.
    ///
    /// Safe to call repeatedly — it removes the legacy key on the first pass.
    static func migrateRetiredSelectionShortcut(defaults: UserDefaults = .standard) {
        let legacyKey = "globalShortcut.translateOrReply"
        guard let data = defaults.data(forKey: legacyKey) else { return }
        defer { defaults.removeObject(forKey: legacyKey) }

        let mode = FloatingButtonDefaultMode.storedMode(
            rawValue: defaults.string(forKey: "floatingButtonDefaultMode")
        )
        let target: GlobalShortcutAction = mode == .smartReply
            ? .replyToSelection
            : .explainSelection
        // Never clobber a binding the user already set on the target itself.
        guard defaults.data(forKey: target.defaultsKey) == nil else { return }
        defaults.set(data, forKey: target.defaultsKey)
    }

    static func resetToDefaults(defaults: UserDefaults = .standard) {
        for action in GlobalShortcutAction.allCases {
            defaults.removeObject(forKey: action.defaultsKey)
        }
    }
}
