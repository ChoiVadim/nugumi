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

    static func resetToDefaults(defaults: UserDefaults = .standard) {
        for action in GlobalShortcutAction.allCases {
            defaults.removeObject(forKey: action.defaultsKey)
        }
    }
}
