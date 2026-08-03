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
/// Built against `SettingsHost` rather than `GizmateSettingsBridge`: the bridge
/// is created by `MainWindowController` and dies with the main window, while a
/// dock outlives it. The host is `GizmateApp` itself and owns the stores, which
/// is all a docked item has ever needed.
///
/// One entry today. It grows when gizmos can render their own content — see
/// `docs/superpowers/specs/2026-08-03-edge-dock-design.md`.
@MainActor
enum DockCatalog {
    static let notesID = "notes"

    static func all(host: any SettingsHost) -> [DockItem] {
        [
            DockItem(id: notesID, title: "Notes", symbolName: "note.text") { [weak host] in
                let view = DockNotesView(
                    notes: host?.notes ?? NotesStore(),
                    onOpenAll: { host?.presentMainWindow(section: .notes) }
                )
                let hosting = NSHostingView(rootView: view)
                hosting.translatesAutoresizingMaskIntoConstraints = false
                return hosting
            }
        ]
    }

    static func item(id: String, host: any SettingsHost) -> DockItem? {
        all(host: host).first { $0.id == id }
    }

    static func knownIDs(host: any SettingsHost) -> Set<String> {
        Set(all(host: host).map(\.id))
    }
}
