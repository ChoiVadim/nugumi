import AppKit
import SwiftUI

/// One thing a dock can hold.
///
/// A struct with a closure rather than a protocol: `NSView` is the only thing a
/// dock ever needs from its contents, and a protocol with one conformer is a
/// shape waiting for a second. When gizmos learn to render themselves they
/// become `DockItem`s too, and the dock learns nothing new.
struct DockItem {
    /// Stable across launches — this is what `DockStore` persists.
    let id: String
    let title: String
    /// SF Symbol drawn on the tab.
    let symbolName: String
    let makeView: () -> NSView
}

/// Everything dockable today.
///
/// One entry. It grows when gizmos can render their own content — see
/// `docs/superpowers/specs/2026-08-03-edge-dock-design.md`.
@MainActor
enum DockCatalog {
    static let notesID = "notes"

    static func all(bridge: GizmateSettingsBridge) -> [DockItem] {
        [
            DockItem(id: notesID, title: "Notes", symbolName: "note.text") {
                let host = NSHostingView(rootView: DockNotesView().environmentObject(bridge))
                host.translatesAutoresizingMaskIntoConstraints = false
                return host
            }
        ]
    }

    static func item(id: String, bridge: GizmateSettingsBridge) -> DockItem? {
        all(bridge: bridge).first { $0.id == id }
    }

    static func knownIDs(bridge: GizmateSettingsBridge) -> Set<String> {
        Set(all(bridge: bridge).map(\.id))
    }
}
