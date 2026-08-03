import SwiftUI

/// Off / Top / Left / Right for one dockable thing.
///
/// Shared by the gizmo editor and Settings so the mapping from "no edge" to Off
/// exists once. Deliberately not wrapped in a `SettingRow`: four pills are
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
            label: { $0?.displayName ?? "Off" }
        )
    }
}
