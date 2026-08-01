import Foundation

/// What the user changed about one built-in ring action.
///
/// Every field is optional and `nil` means "use what shipped". That is the whole
/// point of the shape: "Reset to default" is a removal rather than a copy of
/// today's defaults back over the top, so a user who never touched Explain's
/// prompt still picks up improvements to it in a later release.
struct BuiltInOverride: Codable, Equatable {
    var name: String?
    /// An SF Symbol name, picked with the same `IconGrid` gizmos use. Set, it
    /// replaces the bundled Phosphor glyph on the built-ins that ship one.
    var symbol: String?
    /// Token template replacing the shipped prompt. Only Explain, Rewrite and
    /// Reply have one — see `RingActionID.promptMode`.
    var prompt: String?
    var isEnabled: Bool = true

    /// Nothing set and still switched on is indistinguishable from never having
    /// been edited, so saving one is stored as a removal.
    var isShipped: Bool {
        name == nil && symbol == nil && prompt == nil && isEnabled
    }
}

/// The user's edits to the built-in ring actions, persisted in UserDefaults.
/// Same `@Published` + `onChange` + injectable-defaults contract as
/// `RingLayoutStore` and `ToolsStore`, so the bridge wires it identically.
@MainActor
final class BuiltInOverridesStore: ObservableObject {
    @Published private(set) var overrides: [RingActionID: BuiltInOverride] = [:]
    var onChange: (() -> Void)?

    private static let defaultsKey = "builtInOverrides.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Resolved reads

    /// The ring's hover label. Empty for Summarize by design — its live button
    /// wears the frontmost app's icon, which already names it.
    func name(for id: RingActionID) -> String {
        overrides[id]?.name ?? id.label
    }

    /// The name a settings screen shows, which needs a real word for Summarize.
    func displayName(for id: RingActionID) -> String {
        overrides[id]?.name ?? id.displayName
    }

    func icon(for id: RingActionID) -> RingIconKind {
        overrides[id]?.symbol.map { .symbol($0) } ?? id.icon
    }

    /// nil when the user has not written one — the caller falls back to the
    /// shipped template.
    func prompt(for id: RingActionID) -> String? {
        overrides[id]?.prompt
    }

    func isEnabled(_ id: RingActionID) -> Bool {
        overrides[id]?.isEnabled ?? true
    }

    /// Every prompt the user has written, in the shape `TranslationMode` reads.
    func promptOverrides() -> [RingActionID: String] {
        overrides.compactMapValues(\.prompt)
    }

    // MARK: - Writes

    func save(_ override: BuiltInOverride, for id: RingActionID) {
        if override.isShipped {
            overrides.removeValue(forKey: id)
        } else {
            overrides[id] = override
        }
        persist()
    }

    func resetToDefault(_ id: RingActionID) {
        overrides.removeValue(forKey: id)
        persist()
    }

    // MARK: - Storage

    /// Stored keyed by raw value rather than by `RingActionID` so the JSON stays
    /// readable and an action retired in a later build decodes as a skipped key
    /// instead of failing the whole blob.
    private func persist() {
        let raw = Dictionary(
            uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) }
        )
        guard let data = try? JSONEncoder().encode(raw) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
        onChange?()
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let raw = try? JSONDecoder().decode([String: BuiltInOverride].self, from: data)
        else { return }
        overrides = Dictionary(
            uniqueKeysWithValues: raw.compactMap { key, value in
                RingActionID(rawValue: key).map { ($0, value) }
            }
        )
    }
}
