import SwiftUI

/// Where a tool's panel opens: floating, or flush to a screen edge — or, for a
/// surface, whether it runs at all.
///
/// Not a launcher. A screen edge replaces the *panel*, never the Ring — the Ring
/// is how a tool is triggered, this is where what it shows turns up. Deliberately not wrapped in a `SettingRow`: four pills are
/// `.fixedSize` at `minWidth: 78`, so they demand ~320pt and clip the panel when
/// they share a row with a label — the same trap `kindPicker` documents.
///
/// `unplacedLabel` names the `nil` pill. "Floating" is the right word when
/// undocked still means the tool works — every tool that isn't a surface. A
/// surface has no floating form: `nil` there means it never runs, so the
/// caller names that state instead of reusing a word that would misdescribe it.
struct DockPlacementPicker: View {
    @ObservedObject var store: DockStore
    let itemID: String
    var unplacedLabel: String = "Floating"

    private static let options: [DockEdge?] = [nil, .top, .left, .right]

    var body: some View {
        PillPicker(
            options: Self.options,
            selection: Binding(
                get: { store.edge(of: itemID) },
                set: { store.dock(itemID, to: $0) }
            ),
            label: { $0?.displayName ?? unplacedLabel }
        )
    }
}
