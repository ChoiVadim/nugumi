import AppKit
import Combine
import Foundation

/// One position in one ring: an empty `path` is the root ring, each id descends
/// into that folder's own ring.
struct RingSlotAddress: Equatable {
    var path: [UUID] = []
    var index: Int
}

/// What sits in one ring position.
enum RingSlotContent: Codable, Equatable {
    case empty
    case builtIn(RingActionID)
    case tool(UUID)
    /// A sub-ring. Hovering the button fans this folder's own slots out as the
    /// next orbit, the same machinery Summarize uses for its time ranges.
    case folder(UUID)
}

/// A named, iconed ring behind one button. Stored flat and referenced by id —
/// the same arrangement as tools — so editing a nested ring is one array write
/// instead of a recursive tree mutation.
struct RingFolder: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var symbolName: String
    var layout: RingLayout

    init(id: UUID = UUID(), name: String, symbolName: String, layout: RingLayout = RingLayout(slots: [])) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.layout = layout
    }

    /// Falls back when a saved symbol no longer resolves on this OS version —
    /// same contract as `GizmateTool.resolvedSymbolName`.
    var resolvedSymbolName: String {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) != nil
            ? symbolName
            : RingFolder.defaultSymbolName
    }

    /// Circles arranged on a ring — the shape the fan actually draws, so the
    /// button reads as "opens another ring" rather than as file storage.
    static let defaultSymbolName = "circle.hexagonpath"
}

/// How deep folders may go. The radial menu draws three orbits — the ring
/// itself, a hovered button's fan, and that button's own fan — so a folder can
/// sit in the root ring (opening orbit 2) or one level in (opening orbit 3).
/// A fourth orbit has nowhere to draw: `RadialMenuLayoutPolicy.thirdRingRadius`
/// already reaches the panel edge.
enum RingFolderDepth {
    /// Deepest ring that may still contain a folder, counted in path length.
    static let maxNesting = 2

    static func allowsFolder(at path: [UUID]) -> Bool { path.count < maxNesting }
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
        // At least `slotCount` entries, so slot indexing never traps on a
        // hand-edited or older-format value. Never trimmed back down: an orbit
        // holds more than eight, and truncating here would drop a folder's
        // outer slots every time it was read from disk.
        var padded = slots
        if padded.count < Self.slotCount {
            padded.append(contentsOf: Array(repeating: .empty, count: Self.slotCount - padded.count))
        }
        self.slots = padded
    }

    /// The main ring has eight positions. Each orbit outside it is further from
    /// the centre, so holding the gap between neighbours fixed buys more of
    /// them: sixteen at the second orbit, twenty-four at the third. Those are
    /// the counts whose chord length matches the main ring's to within a point.
    static func capacity(atDepth depth: Int) -> Int {
        switch depth {
        case 0: return slotCount
        case 1: return slotCount * 2
        default: return slotCount * 3
        }
    }

    /// Rings are stored no longer than they need to be, so reading past the end
    /// is an empty slot rather than a trap.
    func content(at index: Int) -> RingSlotContent {
        slots[safe: index] ?? .empty
    }

    /// Grows to fit before writing — assigning slot 20 of a twenty-four slot
    /// orbit has to work on a ring that has only ever held eight.
    mutating func set(_ content: RingSlotContent, at index: Int, capacity: Int) {
        guard index >= 0, index < capacity else { return }
        if slots.count <= index {
            slots.append(contentsOf: Array(repeating: .empty, count: index + 1 - slots.count))
        }
        slots[index] = content
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
    /// Every sub-ring, flat. Slots reference these by id.
    var folders: [RingFolder] = []
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
    /// Sub-rings, flat. Kept in a separate defaults key so the root layout keeps
    /// decoding exactly as it did before folders existed — an install that
    /// predates this feature reads its ring back unchanged.
    @Published private(set) var folders: [RingFolder]
    var onChange: (() -> Void)?

    private static let defaultsKey = "ringLayout"
    private static let foldersKey = "ringFolders"

    /// Injectable so tests can exercise folder deletion — which throws away a
    /// whole sub-tree — against a scratch suite instead of the real ring.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        layout = Self.loaded(from: defaults) ?? .default
        folders = Self.loadedFolders(from: defaults)
    }

    // MARK: - Paths

    /// The ring at `path`: empty is the root ring, each id descends into that
    /// folder. `nil` once a path component has been deleted.
    func ring(at path: [UUID]) -> RingLayout? {
        guard let last = path.last else { return layout }
        return folder(last)?.layout
    }

    func folder(_ id: UUID) -> RingFolder? {
        folders.first { $0.id == id }
    }

    /// Drops components whose folder is gone, so a stale path degrades to the
    /// nearest ring that still exists instead of showing nothing.
    func sanitized(_ path: [UUID]) -> [UUID] {
        var result: [UUID] = []
        for id in path {
            guard folder(id) != nil else { break }
            result.append(id)
        }
        return result
    }

    // MARK: - Slot edits

    func assign(_ content: RingSlotContent, to index: Int, in path: [UUID] = []) {
        let capacity = RingLayout.capacity(atDepth: path.count)
        mutate(path) { ring in
            guard index >= 0, index < capacity else { return false }
            // A built-in, tool or folder lives in one slot of this ring only —
            // assigning it somewhere new vacates wherever it was.
            if content != .empty {
                for (i, existing) in ring.slots.enumerated() where existing == content {
                    ring.slots[i] = .empty
                }
            }
            ring.set(content, at: index, capacity: capacity)
            return true
        }
    }

    func clear(_ index: Int, in path: [UUID] = []) {
        let capacity = RingLayout.capacity(atDepth: path.count)
        mutate(path) { ring in
            guard index >= 0, index < min(capacity, ring.slots.count) else { return false }
            ring.slots[index] = .empty
            return true
        }
    }

    /// Drag one slot onto another: the two trade places.
    func swap(_ a: Int, _ b: Int, in path: [UUID] = []) {
        let capacity = RingLayout.capacity(atDepth: path.count)
        mutate(path) { ring in
            guard a != b, a >= 0, b >= 0, a < capacity, b < capacity else { return false }
            let (first, second) = (ring.content(at: a), ring.content(at: b))
            ring.set(second, at: a, capacity: capacity)
            ring.set(first, at: b, capacity: capacity)
            return true
        }
    }

    /// Drag one slot onto another across rings: the two trade places, and an
    /// empty target is simply a move. Carrying a button out of a folder — or
    /// into one — is the whole reason this exists; a drag that stays inside one
    /// ring is just `swap`.
    func move(from source: RingSlotAddress, to target: RingSlotAddress) {
        guard canMove(from: source, to: target) else { return }
        guard source.path != target.path else {
            swap(source.index, target.index, in: source.path)
            return
        }
        guard let sourceRing = ring(at: source.path), let targetRing = ring(at: target.path) else { return }
        let moving = sourceRing.content(at: source.index)
        // Two rings, one change: the displaced content goes back the other way
        // before either write reaches disk.
        write(targetRing.content(at: target.index), at: source)
        write(moving, at: target)
        commit()
    }

    /// Whether `move(from:to:)` would land. The drag asks before it lights a
    /// slot up, so an impossible drop never offers itself as a target.
    func canMove(from source: RingSlotAddress, to target: RingSlotAddress) -> Bool {
        guard source != target,
              let sourceRing = ring(at: source.path),
              let targetRing = ring(at: target.path),
              source.index >= 0, source.index < RingLayout.capacity(atDepth: source.path.count),
              target.index >= 0, target.index < RingLayout.capacity(atDepth: target.path.count)
        else { return false }
        let moving = sourceRing.content(at: source.index)
        guard moving != .empty else { return false }
        // Both directions: the slot being vacated has to be able to hold
        // whatever the swap sends back into it.
        return accepts(moving, at: target) && accepts(targetRing.content(at: target.index), at: source)
    }

    /// Called when a prompt tool is deleted, so no slot — in the root ring or
    /// any folder — lingers as a dangling id.
    func removeTool(_ id: UUID) {
        var changed = vacate(.tool(id), in: &layout)
        for i in folders.indices where vacate(.tool(id), in: &folders[i].layout) {
            changed = true
        }
        if changed { commit() }
    }

    // MARK: - Folders

    /// Creates a folder and drops it into `index` of the ring at `path`.
    @discardableResult
    func addFolder(name: String, symbolName: String, to index: Int, in path: [UUID]) -> RingFolder {
        let folder = RingFolder(name: name, symbolName: symbolName)
        folders.append(folder)
        assign(.folder(folder.id), to: index, in: path)
        return folder
    }

    func updateFolder(_ id: UUID, name: String, symbolName: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].name = name
        folders[i].symbolName = symbolName
        commit()
    }

    /// Deletes a folder along with every folder nested inside it, and vacates
    /// every slot that pointed at any of them. Tools themselves are untouched —
    /// only their placement in this sub-ring goes away.
    func removeFolder(_ id: UUID) {
        let doomed = subtree(of: id)
        for victim in doomed {
            _ = vacate(.folder(victim), in: &layout)
            for i in folders.indices { _ = vacate(.folder(victim), in: &folders[i].layout) }
        }
        folders.removeAll { doomed.contains($0.id) }
        commit()
    }

    func resetToDefault() {
        layout = .default
        folders = []
        defaults.removeObject(forKey: Self.defaultsKey)
        defaults.removeObject(forKey: Self.foldersKey)
        onChange?()
    }

    // MARK: - Plumbing

    /// Applies `body` to the ring at `path` and commits when it reports a change.
    private func mutate(_ path: [UUID], _ body: (inout RingLayout) -> Bool) {
        let changed: Bool
        if let last = path.last {
            guard let i = folders.firstIndex(where: { $0.id == last }) else { return }
            changed = body(&folders[i].layout)
        } else {
            changed = body(&layout)
        }
        if changed { commit() }
    }

    /// Places `content` without committing — `move` writes two slots, in two
    /// different rings, and both have to land as one change.
    private func write(_ content: RingSlotContent, at address: RingSlotAddress) {
        let capacity = RingLayout.capacity(atDepth: address.path.count)
        if let last = address.path.last {
            guard let i = folders.firstIndex(where: { $0.id == last }) else { return }
            folders[i].layout.set(content, at: address.index, capacity: capacity)
        } else {
            layout.set(content, at: address.index, capacity: capacity)
        }
    }

    /// Only folders are picky about where they land: a folder filed inside
    /// itself would be unreachable, and the orbits it opens have to fit inside
    /// the three the menu draws. Everything else goes anywhere.
    private func accepts(_ content: RingSlotContent, at address: RingSlotAddress) -> Bool {
        guard case .folder(let id) = content else { return true }
        let contained = subtree(of: id)
        guard !address.path.contains(where: { contained.contains($0) }) else { return false }
        // A folder carrying folders of its own needs room for their orbits too,
        // so how deep it may sit depends on how deep it already is.
        return address.path.count + nesting(of: id) < RingFolderDepth.maxNesting
    }

    /// `id` plus every folder reachable inside it. Visits are recorded, so a
    /// hand-edited defaults file holding a cycle can't spin here.
    private func subtree(of id: UUID) -> Set<UUID> {
        var seen: Set<UUID> = []
        var queue = [id]
        while let next = queue.popLast() {
            guard seen.insert(next).inserted, let folder = folder(next) else { continue }
            for slot in folder.layout.slots {
                if case .folder(let child) = slot { queue.append(child) }
            }
        }
        return seen
    }

    /// How many further orbits this folder's own contents need: 0 when it holds
    /// no folders, 1 when it holds one that holds none.
    private func nesting(of id: UUID) -> Int {
        var depth = 0
        var level = [id]
        var seen: Set<UUID> = []
        while true {
            var next: [UUID] = []
            for parent in level where seen.insert(parent).inserted {
                for slot in folder(parent)?.layout.slots ?? [] {
                    if case .folder(let child) = slot { next.append(child) }
                }
            }
            if next.isEmpty { return depth }
            depth += 1
            level = next
        }
    }

    private func vacate(_ content: RingSlotContent, in ring: inout RingLayout) -> Bool {
        var changed = false
        for (i, slot) in ring.slots.enumerated() where slot == content {
            ring.slots[i] = .empty
            changed = true
        }
        return changed
    }

    private func commit() {
        if let data = try? JSONEncoder().encode(layout) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        if let data = try? JSONEncoder().encode(folders) {
            defaults.set(data, forKey: Self.foldersKey)
        }
        onChange?()
    }

    private static func loaded(from defaults: UserDefaults) -> RingLayout? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(RingLayout.self, from: data)
    }

    private static func loadedFolders(from defaults: UserDefaults) -> [RingFolder] {
        guard let data = defaults.data(forKey: foldersKey) else { return [] }
        return (try? JSONDecoder().decode([RingFolder].self, from: data)) ?? []
    }
}
