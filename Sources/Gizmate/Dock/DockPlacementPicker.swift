import SwiftUI

/// Where a tool's panel opens: floating, or flush to a screen edge.
///
/// Not a launcher. A screen edge replaces the *panel*, never the Ring — the Ring
/// is how a tool is triggered, this is where what it shows turns up. "Floating"
/// is the default every tool has always had. Deliberately not wrapped in a `SettingRow`: four pills are
/// `.fixedSize` at `minWidth: 78`, so they demand ~320pt and clip the panel when
/// they share a row with a label — the same trap `kindPicker` documents.
struct DockPlacementPicker: View {
    @ObservedObject var store: DockStore
    let itemID: String

    private static let options: [DockEdge?] = [nil, .top, .left, .right]

    var body: some View {
        PillPicker(
            options: Self.options,
            selection: Binding(
                get: { store.edge(of: itemID) },
                set: { store.dock(itemID, to: $0) }
            ),
            label: { $0?.displayName ?? "Floating" }
        )
    }
}
