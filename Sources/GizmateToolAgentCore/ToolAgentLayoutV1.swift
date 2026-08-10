import Foundation

/// What a surface gizmo draws, composed by the agent out of components Gizmate
/// ships and nothing else.
///
/// Four nodes. `grid` and `list` repeat their child once per row of data;
/// `card` and `text` are leaves. There is deliberately no node for an empty
/// state — only a repeater can have zero children, so the copy is its
/// property, and a sibling node could never be reached anyway.
///
/// The wire format tags each node with a `"node"` discriminator and spells
/// modifiers as short prefixed strings (`"drag": "file:$path"`) rather than
/// nested objects, because the author on the other end is a model writing
/// this JSON by hand — a third level of nesting is more places to slip, a
/// prefix string is not. `Codable` is written by hand to enforce that grammar:
/// decode `node`, switch on it, assert the exact key set that node accepts,
/// and recurse.
public indirect enum ToolAgentLayoutV1: Equatable, Sendable {
    case grid(cell: ToolAgentLayoutV1, minimumWidth: Int, empty: String)
    case list(row: ToolAgentLayoutV1, empty: String)
    case card(
        title: ToolAgentLayoutBindingV1,
        subtitle: ToolAgentLayoutBindingV1?,
        icon: ToolAgentLayoutIconV1?,
        drag: ToolAgentLayoutDragV1?,
        tap: ToolAgentLayoutTapV1?
    )
    case text(ToolAgentLayoutBindingV1)

    /// A surface is a strip on a screen edge, not a document.
    public static let maximumDepth = 3
    public static let minimumGridWidth = 48
    public static let maximumGridWidth = 400
    public static let maximumEmptyBytes = 120

    /// How deep this node's own subtree goes. A leaf is depth 1, so the root
    /// of a legal tree reports at most `maximumDepth`. Checking here — after
    /// a node's children have already decoded — rather than threading a
    /// counter through `Decoder.userInfo` means every node only ever asks
    /// "is my own subtree small enough", and a subtree's depth can never
    /// exceed the whole tree's, so no inner node can reject a tree that
    /// actually fits. Purely a `Codable` implementation detail, so it stays
    /// internal — nothing outside this file needs to ask a layout its depth.
    var depth: Int {
        switch self {
        case let .grid(cell, _, _): return 1 + cell.depth
        case let .list(row, _): return 1 + row.depth
        case .card, .text: return 1
        }
    }

    /// Every row key the tree reads. `CandidateValidation` checks these against
    /// keys the script really printed, so a binding that names nothing is
    /// refused before the user ever docks the gizmo.
    public var referencedKeys: Set<String> {
        switch self {
        case let .grid(cell, _, _): return cell.referencedKeys
        case let .list(row, _): return row.referencedKeys
        case let .card(title, subtitle, icon, drag, tap):
            var keys: Set<String> = []
            if let key = title.key { keys.insert(key) }
            if let key = subtitle?.key { keys.insert(key) }
            if let key = icon?.key { keys.insert(key) }
            if let key = drag?.key { keys.insert(key) }
            if let key = tap?.key { keys.insert(key) }
            return keys
        case let .text(binding): return binding.key.map { Set([$0]) } ?? []
        }
    }

    /// The subset of `referencedKeys` that has to hold a file URL.
    public var fileKeys: Set<String> {
        switch self {
        case let .grid(cell, _, _): return cell.fileKeys
        case let .list(row, _): return row.fileKeys
        case let .card(_, _, icon, drag, tap):
            var keys: Set<String> = []
            if case let .file(key) = icon { keys.insert(key) }
            if case let .file(key) = drag { keys.insert(key) }
            if let tap { keys.insert(tap.key) }
            return keys
        case .text: return []
        }
    }

    /// The literal `symbol:` names an icon binds. Unlike `fileKeys`, this never
    /// depends on the rows a script prints — a symbol name is either a real
    /// SF Symbol on this OS or it isn't, checkable from the layout alone.
    /// `SurfaceLayoutCheck` uses this to catch a name the model invented
    /// before the user ever docks the gizmo, rather than let it draw a
    /// silent blank icon. A `symbol:$key` icon is deliberately absent: its
    /// name is data, so it belongs to `symbolKeys` below instead.
    public var iconSymbols: Set<String> {
        switch self {
        case let .grid(cell, _, _): return cell.iconSymbols
        case let .list(row, _): return row.iconSymbols
        case let .card(_, _, icon, _, _):
            if case let .symbol(name) = icon { return [name] }
            return []
        case .text: return []
        }
    }

    /// The subset of `referencedKeys` whose value has to be an SF Symbol name.
    /// The same shape as `fileKeys`: a promise about what a script prints,
    /// checkable only against rows it really printed.
    public var symbolKeys: Set<String> {
        switch self {
        case let .grid(cell, _, _): return cell.symbolKeys
        case let .list(row, _): return row.symbolKeys
        case let .card(_, _, icon, _, _):
            if case let .symbolKey(key) = icon { return [key] }
            return []
        case .text: return []
        }
    }

    public var isRepeater: Bool {
        switch self {
        case .grid, .list: return true
        case .card, .text: return false
        }
    }

    /// Whether a repeater appears anywhere below this node — a grid or list
    /// nested inside another repeater's own cell. `SurfaceRow` is flat, so an
    /// inner repeater would have no second collection to iterate; every shape
    /// this vocabulary can express is supposed to mean something, and a
    /// nested repeater is the one that doesn't. `validate` uses this to
    /// refuse the candidate outright rather than let the renderer collapse it
    /// to a single iteration at render time.
    public var containsNestedRepeater: Bool {
        switch self {
        case let .grid(cell, _, _): return cell.isRepeater || cell.containsNestedRepeater
        case let .list(row, _): return row.isRepeater || row.containsNestedRepeater
        case .card, .text: return false
        }
    }
}

extension ToolAgentLayoutV1: Codable {
    private enum NodeKind: String {
        case grid, list, card, text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ToolAgentDynamicCodingKeyV1.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        let name = try container.decode(String.self, forKey: .required("node"))
        guard let node = NodeKind(rawValue: name) else {
            throw ToolAgentFailureCodeV1.invalidProtocol
        }

        switch node {
        case .grid:
            guard keys == Set(["node", "minimumWidth", "empty", "cell"]) else {
                throw ToolAgentFailureCodeV1.invalidProtocol
            }
            let minimumWidth = try container.decode(Int.self, forKey: .required("minimumWidth"))
            guard (Self.minimumGridWidth...Self.maximumGridWidth).contains(minimumWidth) else {
                throw ToolAgentFailureCodeV1.invalidProtocol
            }
            let empty = try container.decode(String.self, forKey: .required("empty"))
            // A repeater whose empty copy is "" puts a blank panel on the
            // user's screen edge with nothing explaining why, which reads as
            // broken — so this is the one string in the tree that must not
            // be blank even though it is short enough to allow it.
            guard !empty.isEmpty, empty.utf8.count <= Self.maximumEmptyBytes else {
                throw ToolAgentFailureCodeV1.invalidProtocol
            }
            let cell = try container.decode(ToolAgentLayoutV1.self, forKey: .required("cell"))
            self = .grid(cell: cell, minimumWidth: minimumWidth, empty: empty)

        case .list:
            guard keys == Set(["node", "empty", "row"]) else {
                throw ToolAgentFailureCodeV1.invalidProtocol
            }
            let empty = try container.decode(String.self, forKey: .required("empty"))
            guard !empty.isEmpty, empty.utf8.count <= Self.maximumEmptyBytes else {
                throw ToolAgentFailureCodeV1.invalidProtocol
            }
            let row = try container.decode(ToolAgentLayoutV1.self, forKey: .required("row"))
            self = .list(row: row, empty: empty)

        case .card:
            guard keys.subtracting(["node", "title", "subtitle", "icon", "drag", "tap"]).isEmpty,
                  keys.contains("title") else {
                throw ToolAgentFailureCodeV1.invalidProtocol
            }
            let title = try ToolAgentLayoutBindingV1(
                wire: container.decode(String.self, forKey: .required("title"))
            )
            let subtitle = try container.decodeIfPresent(String.self, forKey: .required("subtitle"))
                .map(ToolAgentLayoutBindingV1.init(wire:))
            let icon = try container.decodeIfPresent(String.self, forKey: .required("icon"))
                .map(ToolAgentLayoutIconV1.init(wire:))
            let drag = try container.decodeIfPresent(String.self, forKey: .required("drag"))
                .map(ToolAgentLayoutDragV1.init(wire:))
            let tap = try container.decodeIfPresent(String.self, forKey: .required("tap"))
                .map(ToolAgentLayoutTapV1.init(wire:))
            self = .card(title: title, subtitle: subtitle, icon: icon, drag: drag, tap: tap)

        case .text:
            guard keys == Set(["node", "value"]) else {
                throw ToolAgentFailureCodeV1.invalidProtocol
            }
            let binding = try ToolAgentLayoutBindingV1(
                wire: container.decode(String.self, forKey: .required("value"))
            )
            self = .text(binding)
        }

        guard depth <= Self.maximumDepth else {
            throw ToolAgentFailureCodeV1.invalidProtocol
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ToolAgentDynamicCodingKeyV1.self)
        switch self {
        case let .grid(cell, minimumWidth, empty):
            try container.encode(NodeKind.grid.rawValue, forKey: .required("node"))
            try container.encode(minimumWidth, forKey: .required("minimumWidth"))
            try container.encode(empty, forKey: .required("empty"))
            try container.encode(cell, forKey: .required("cell"))

        case let .list(row, empty):
            try container.encode(NodeKind.list.rawValue, forKey: .required("node"))
            try container.encode(empty, forKey: .required("empty"))
            try container.encode(row, forKey: .required("row"))

        case let .card(title, subtitle, icon, drag, tap):
            try container.encode(NodeKind.card.rawValue, forKey: .required("node"))
            try container.encode(title.wire, forKey: .required("title"))
            try container.encodeIfPresent(subtitle?.wire, forKey: .required("subtitle"))
            try container.encodeIfPresent(icon?.wire, forKey: .required("icon"))
            try container.encodeIfPresent(drag?.wire, forKey: .required("drag"))
            try container.encodeIfPresent(tap?.wire, forKey: .required("tap"))

        case let .text(binding):
            try container.encode(NodeKind.text.rawValue, forKey: .required("node"))
            try container.encode(binding.wire, forKey: .required("value"))
        }
    }
}

public enum ToolAgentLayoutBindingV1: Equatable, Sendable {
    case key(String)
    case literal(String)

    public var key: String? {
        if case let .key(name) = self { return name }
        return nil
    }

    /// `"$name"` is a key, anything else is the text itself. `"$"` alone is
    /// neither and throws.
    public init(wire: String) throws {
        guard wire.hasPrefix("$") else {
            self = .literal(wire)
            return
        }
        let name = String(wire.dropFirst())
        guard !name.isEmpty else { throw ToolAgentFailureCodeV1.invalidProtocol }
        self = .key(name)
    }

    public var wire: String {
        switch self {
        case let .key(name): return "$" + name
        case let .literal(text): return text
        }
    }
}

public enum ToolAgentLayoutIconV1: Equatable, Sendable {
    case file(key: String)
    case symbol(String)
    /// The glyph name comes from the row, not from the layout. `.symbol` holds
    /// one literal for every card a repeater draws, so a surface whose rows are
    /// unlike each other — a CPU card beside a disk card — had no way to say so
    /// and settled for the same glyph on all of them. This is the same
    /// `"prefix:$key"` grammar `drag` and `tap` already speak, applied to the
    /// one modifier that was missing it.
    case symbolKey(key: String)

    public var key: String? {
        switch self {
        case let .file(key), let .symbolKey(key): return key
        case .symbol: return nil
        }
    }

    public init(wire: String) throws {
        if let glyph = wire.stripping(prefix: "symbol:") {
            // A `$` names a row key here exactly as it does everywhere else in
            // this grammar; anything else is the glyph itself. Both the bare
            // `"symbol:$"` and the empty `"symbol:"` throw rather than decode
            // to something that draws nothing — the sidecar's schema refuses
            // both too, and these two validators disagreeing is what puts a
            // candidate in front of the host with no repair diagnostic.
            if glyph.hasPrefix("$") {
                guard glyph.count > 1 else { throw ToolAgentFailureCodeV1.invalidProtocol }
                self = .symbolKey(key: String(glyph.dropFirst()))
            } else {
                guard !glyph.isEmpty else { throw ToolAgentFailureCodeV1.invalidProtocol }
                self = .symbol(glyph)
            }
            return
        }
        guard let key = try wire.strippingKeyed(prefix: "file:") else {
            throw ToolAgentFailureCodeV1.invalidProtocol
        }
        self = .file(key: key)
    }

    public var wire: String {
        switch self {
        case let .file(key): return "file:$" + key
        case let .symbol(glyph): return "symbol:" + glyph
        case let .symbolKey(key): return "symbol:$" + key
        }
    }
}

public enum ToolAgentLayoutDragV1: Equatable, Sendable {
    case file(key: String)
    case text(key: String)

    public var key: String {
        switch self {
        case let .file(key): return key
        case let .text(key): return key
        }
    }

    public init(wire: String) throws {
        if let key = try wire.strippingKeyed(prefix: "file:") {
            self = .file(key: key)
        } else if let key = try wire.strippingKeyed(prefix: "text:") {
            self = .text(key: key)
        } else {
            throw ToolAgentFailureCodeV1.invalidProtocol
        }
    }

    public var wire: String {
        switch self {
        case let .file(key): return "file:$" + key
        case let .text(key): return "text:$" + key
        }
    }
}

public enum ToolAgentLayoutTapV1: Equatable, Sendable {
    case open(key: String)
    case reveal(key: String)

    public var key: String {
        switch self {
        case let .open(key): return key
        case let .reveal(key): return key
        }
    }

    public init(wire: String) throws {
        if let key = try wire.strippingKeyed(prefix: "open:") {
            self = .open(key: key)
        } else if let key = try wire.strippingKeyed(prefix: "reveal:") {
            self = .reveal(key: key)
        } else {
            throw ToolAgentFailureCodeV1.invalidProtocol
        }
    }

    public var wire: String {
        switch self {
        case let .open(key): return "open:$" + key
        case let .reveal(key): return "reveal:$" + key
        }
    }
}

/// Shared parsing for the `"prefix:$key"` modifier grammar. A prefix that
/// isn't present returns `nil` so callers can try the next one; a prefix
/// that's present but not followed by a `$key` throws — `"file:Downloads"`
/// named a candidate for `file:`, not a fallthrough to another case.
private extension String {
    func stripping(prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }

    func strippingKeyed(prefix: String) throws -> String? {
        guard let rest = stripping(prefix: prefix) else { return nil }
        guard rest.hasPrefix("$"), rest.count > 1 else {
            throw ToolAgentFailureCodeV1.invalidProtocol
        }
        return String(rest.dropFirst())
    }
}
