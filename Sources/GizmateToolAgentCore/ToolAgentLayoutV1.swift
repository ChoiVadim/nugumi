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
    case card(ToolAgentLayoutCardV1)
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
        case let .card(card): return card.referencedKeys
        case let .text(binding): return binding.key.map { Set([$0]) } ?? []
        }
    }

    /// The subset of `referencedKeys` that has to hold a file URL.
    public var fileKeys: Set<String> {
        switch self {
        case let .grid(cell, _, _): return cell.fileKeys
        case let .list(row, _): return row.fileKeys
        case let .card(card):
            var keys: Set<String> = []
            if case let .file(key) = card.icon { keys.insert(key) }
            if case let .file(key) = card.drag { keys.insert(key) }
            if let tap = card.tap { keys.insert(tap.key) }
            return keys
        case .text: return []
        }
    }

    /// The subset of `referencedKeys` whose value has to be a fraction — the
    /// same kind of promise about a script's output as `fileKeys`, and checked
    /// the same way, against rows a validation run really printed.
    public var meterKeys: Set<String> {
        switch self {
        case let .grid(cell, _, _): return cell.meterKeys
        case let .list(row, _): return row.meterKeys
        case let .card(card): return card.meter.map { Set([$0]) } ?? []
        case .text: return []
        }
    }

    /// The subset of `referencedKeys` whose value has to be a series of
    /// numbers. A row is flat by design (`SurfaceRow`), so a series arrives as
    /// one comma-separated string rather than a JSON array — the same trade
    /// `file:$path` already makes, where a string promises a shape and the
    /// host checks the promise against a real run.
    public var chartKeys: Set<String> {
        switch self {
        case let .grid(cell, _, _): return cell.chartKeys
        case let .list(row, _): return row.chartKeys
        case let .card(card): return card.chart.map { Set([$0]) } ?? []
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
        case let .card(card):
            if case let .symbol(name) = card.icon { return [name] }
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
        case let .card(card):
            if case let .symbolKey(key) = card.icon { return [key] }
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

    public var isCard: Bool {
        if case .card = self { return true }
        return false
    }

    /// The names of any modifiers a grid's cell carries that only a list row
    /// can draw, for a diagnostic that says which ones. A grid cell is a
    /// square sized from its own column (DESIGN.md §13), so three detail lines
    /// and a bar have nowhere to go in one; drawing them anyway would clip
    /// silently, and dropping them silently is worse. Refusing names the fix,
    /// which is "make it a list".
    public var rowOnlyFieldsInsideAGrid: [String] {
        switch self {
        case let .grid(cell, _, _):
            if case let .card(card) = cell { return card.rowOnlyFields }
            return cell.rowOnlyFieldsInsideAGrid
        case let .list(row, _): return row.rowOnlyFieldsInsideAGrid
        case .card, .text: return []
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
            let accepted = ["node", "title", "subtitle", "icon", "details", "meter", "chart",
                            "drag", "tap"]
            guard keys.subtracting(accepted).isEmpty, keys.contains("title") else {
                throw ToolAgentFailureCodeV1.invalidProtocol
            }
            let title = try ToolAgentLayoutBindingV1(
                wire: container.decode(String.self, forKey: .required("title"))
            )
            let subtitle = try container.decodeIfPresent(String.self, forKey: .required("subtitle"))
                .map(ToolAgentLayoutBindingV1.init(wire:))
            let icon = try container.decodeIfPresent(String.self, forKey: .required("icon"))
                .map(ToolAgentLayoutIconV1.init(wire:))
            let details = try container
                .decodeIfPresent([String].self, forKey: .required("details"))?
                .map(ToolAgentLayoutBindingV1.init(wire:)) ?? []
            guard details.count <= ToolAgentLayoutCardV1.maximumDetails else {
                throw ToolAgentFailureCodeV1.invalidProtocol
            }
            let meter = try container.decodeIfPresent(String.self, forKey: .required("meter"))
                .map(ToolAgentLayoutCardV1.key(fromWire:))
            let chart = try container.decodeIfPresent(String.self, forKey: .required("chart"))
                .map(ToolAgentLayoutCardV1.key(fromWire:))
            let drag = try container.decodeIfPresent(String.self, forKey: .required("drag"))
                .map(ToolAgentLayoutDragV1.init(wire:))
            let tap = try container.decodeIfPresent(String.self, forKey: .required("tap"))
                .map(ToolAgentLayoutTapV1.init(wire:))
            self = .card(ToolAgentLayoutCardV1(
                title: title, subtitle: subtitle, icon: icon, details: details,
                meter: meter, chart: chart, drag: drag, tap: tap
            ))

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

        case let .card(card):
            try container.encode(NodeKind.card.rawValue, forKey: .required("node"))
            try container.encode(card.title.wire, forKey: .required("title"))
            try container.encodeIfPresent(card.subtitle?.wire, forKey: .required("subtitle"))
            try container.encodeIfPresent(card.icon?.wire, forKey: .required("icon"))
            // Absent rather than `[]` when there are none: an empty array is a
            // key the decoder's own strict key-set check would then have to
            // accept as meaning nothing, and a round trip must produce the
            // document it started from.
            if !card.details.isEmpty {
                try container.encode(card.details.map(\.wire), forKey: .required("details"))
            }
            try container.encodeIfPresent(card.meter.map { "$" + $0 }, forKey: .required("meter"))
            try container.encodeIfPresent(card.chart.map { "$" + $0 }, forKey: .required("chart"))
            try container.encodeIfPresent(card.drag?.wire, forKey: .required("drag"))
            try container.encodeIfPresent(card.tap?.wire, forKey: .required("tap"))

        case let .text(binding):
            try container.encode(NodeKind.text.rawValue, forKey: .required("node"))
            try container.encode(binding.wire, forKey: .required("value"))
        }
    }
}

/// One leaf of a surface: what a single row of a script's output looks like.
///
/// A struct rather than eight associated values on the enum case. Every field
/// but `title` is optional, and a case cannot give an associated value a
/// default — so each new modifier would otherwise have to be spelled out at all
/// twenty-odd construction sites, including the ones that want none of it.
///
/// Everything here is flat and prefixed, never nested, for the reason in
/// `ToolAgentLayoutV1`'s own doc comment: the author writing this JSON is a
/// model doing it by hand.
public struct ToolAgentLayoutCardV1: Equatable, Sendable {
    public let title: ToolAgentLayoutBindingV1
    public let subtitle: ToolAgentLayoutBindingV1?
    public let icon: ToolAgentLayoutIconV1?
    /// Lines under the title, in the order given — "System: 7.5%", "User:
    /// 12.3%". Ordinary bindings, so a line can be a row's value or fixed
    /// text, and a line whose key is missing from a row simply isn't drawn.
    public let details: [ToolAgentLayoutBindingV1]
    /// The row key holding how full something is, drawn as a bar.
    public let meter: String?
    /// The row key holding a series of numbers, drawn as a sparkline.
    public let chart: String?
    public let drag: ToolAgentLayoutDragV1?
    public let tap: ToolAgentLayoutTapV1?

    /// Enough for the busiest row on a real stats panel (a battery has four:
    /// source, capacity, cycles, temperature) with room to spare. A cap at all
    /// because a surface is a strip on a screen edge, and a row that scrolls
    /// past the panel is a row nobody can read.
    public static let maximumDetails = 6

    public init(
        title: ToolAgentLayoutBindingV1,
        subtitle: ToolAgentLayoutBindingV1? = nil,
        icon: ToolAgentLayoutIconV1? = nil,
        details: [ToolAgentLayoutBindingV1] = [],
        meter: String? = nil,
        chart: String? = nil,
        drag: ToolAgentLayoutDragV1? = nil,
        tap: ToolAgentLayoutTapV1? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.details = details
        self.meter = meter
        self.chart = chart
        self.drag = drag
        self.tap = tap
    }

    public var referencedKeys: Set<String> {
        var keys: Set<String> = []
        if let key = title.key { keys.insert(key) }
        if let key = subtitle?.key { keys.insert(key) }
        if let key = icon?.key { keys.insert(key) }
        for detail in details { if let key = detail.key { keys.insert(key) } }
        if let meter { keys.insert(meter) }
        if let chart { keys.insert(chart) }
        if let key = drag?.key { keys.insert(key) }
        if let key = tap?.key { keys.insert(key) }
        return keys
    }

    /// The modifiers only a list row can draw. See
    /// `ToolAgentLayoutV1.rowOnlyFieldsInsideAGrid`.
    var rowOnlyFields: [String] {
        var names: [String] = []
        if !details.isEmpty { names.append("details") }
        if meter != nil { names.append("meter") }
        if chart != nil { names.append("chart") }
        return names
    }

    /// `meter` and `chart` name a row key and nothing else — unlike `title`,
    /// where fixed text is a sensible thing to want, a fixed bar or a fixed
    /// graph would be a picture of data that isn't there. So the `$` is
    /// required rather than optional, and a bare `"$"` is refused the same way
    /// `ToolAgentLayoutBindingV1` refuses it.
    static func key(fromWire wire: String) throws -> String {
        guard wire.hasPrefix("$"), wire.count > 1 else {
            throw ToolAgentFailureCodeV1.invalidProtocol
        }
        return String(wire.dropFirst())
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
