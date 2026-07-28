import AppKit
import Combine
import Foundation

/// What sits in one ring position.
enum RingSlotContent: Codable, Equatable {
    case empty
    case builtIn(RingActionID)
    case tool(UUID)
}

/// The ring's contents, in geometric slot order. Slot *i* maps to
/// `RadialMenuLayoutPolicy.buttonCenters(count: 8)[i]` — right, bottom,
/// top-right, bottom-right, bottom-left, left, top, top-left. Empty and
/// unavailable slots are dropped when the ring is built, so the remaining
/// buttons redistribute exactly like they do today when Summarize is absent.
struct RingLayout: Codable, Equatable {
    /// The ring geometry tops out at eight positions.
    static let slotCount = 8

    var slots: [RingSlotContent]

    init(slots: [RingSlotContent]) {
        // Always exactly `slotCount` entries, so slot indexing never traps on
        // a hand-edited or older-format value.
        var padded = Array(slots.prefix(Self.slotCount))
        padded.append(contentsOf: Array(repeating: .empty, count: Self.slotCount - padded.count))
        self.slots = padded
    }

    /// The ring as it shipped: Summarize sixth, matching the old
    /// `items.insert(…, at: 5)`.
    static let `default` = RingLayout(slots: [
        .builtIn(.explain),
        .builtIn(.rewrite),
        .builtIn(.reply),
        .builtIn(.ask),
        .builtIn(.capture),
        .builtIn(.summarize),
        .builtIn(.dictate),
        .builtIn(.live),
    ])

    private enum CodingKeys: String, CodingKey { case slots }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(slots: try container.decode([RingSlotContent].self, forKey: .slots))
    }
}

/// Everything the ring needs to build itself. Presenters read this through
/// `RingConfigurationProvider` at open time rather than storing a copy, so a
/// layout edit — and a fresh clipboard reading — lands on the very next ring.
struct RingConfiguration {
    var layout: RingLayout
    /// Only tools that could actually run: named, with a prompt or a script.
    var tools: [GizmateTool]
    /// What's in front of the user right now, used to test each tool's trigger.
    var context: ToolContext

    static let `default` = RingConfiguration(layout: .default, tools: [], context: .empty)
}

/// Live ring contents, published once by the app delegate at launch. Same
/// arrangement as `AppCategoryClassifier.userOverrides`: read-only configuration
/// the presenters need, kept out of four construction sites. Takes the armed
/// selection because only the presenter knows it.
@MainActor
enum RingConfigurationProvider {
    static var current: (_ selection: String) -> RingConfiguration = { _ in .default }
}

/// The user's ring layout, persisted in UserDefaults. Same shape and contract
/// as `SnippetsStore`.
@MainActor
final class RingLayoutStore: ObservableObject {
    @Published private(set) var layout: RingLayout
    var onChange: (() -> Void)?

    private static let defaultsKey = "ringLayout"

    init() {
        layout = Self.loaded() ?? .default
    }

    func assign(_ content: RingSlotContent, to index: Int) {
        guard layout.slots.indices.contains(index) else { return }
        // A built-in or a tool lives in one slot only — assigning it somewhere
        // new vacates wherever it was, so the ring can't show it twice.
        if content != .empty {
            for (i, existing) in layout.slots.enumerated() where existing == content {
                layout.slots[i] = .empty
            }
        }
        layout.slots[index] = content
        commit()
    }

    func clear(_ index: Int) {
        guard layout.slots.indices.contains(index) else { return }
        layout.slots[index] = .empty
        commit()
    }

    /// Drag one slot onto another: the two trade places.
    func swap(_ a: Int, _ b: Int) {
        guard a != b,
              layout.slots.indices.contains(a),
              layout.slots.indices.contains(b)
        else { return }
        layout.slots.swapAt(a, b)
        commit()
    }

    /// Called when a prompt tool is deleted, so its slot doesn't linger as a
    /// dangling id.
    func removeTool(_ id: UUID) {
        var changed = false
        for (i, slot) in layout.slots.enumerated() where slot == .tool(id) {
            layout.slots[i] = .empty
            changed = true
        }
        if changed { commit() }
    }

    func resetToDefault() {
        layout = .default
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        onChange?()
    }

    private func commit() {
        if let data = try? JSONEncoder().encode(layout) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        onChange?()
    }

    private static func loaded() -> RingLayout? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(RingLayout.self, from: data)
    }
}
