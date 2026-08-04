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
    /// actually fits.
    public var depth: Int {
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

    public var isRepeater: Bool {
        switch self {
        case .grid, .list: return true
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
            guard empty.utf8.count <= Self.maximumEmptyBytes else {
                throw ToolAgentFailureCodeV1.invalidProtocol
            }
            let cell = try container.decode(ToolAgentLayoutV1.self, forKey: .required("cell"))
            self = .grid(cell: cell, minimumWidth: minimumWidth, empty: empty)

        case .list:
            guard keys == Set(["node", "empty", "row"]) else {
                throw ToolAgentFailureCodeV1.invalidProtocol
            }
            let empty = try container.decode(String.self, forKey: .required("empty"))
            guard empty.utf8.count <= Self.maximumEmptyBytes else {
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

    public var key: String? {
        if case let .file(key) = self { return key }
        return nil
    }

    public init(wire: String) throws {
        if let glyph = wire.stripping(prefix: "symbol:") {
            self = .symbol(glyph)
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
