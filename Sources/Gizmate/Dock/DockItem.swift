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
/// Built-ins first, then every usable gizmo the user has built. A gizmo's
/// placement is chosen in its own editor rather than in Settings, because that
/// is where everything else about it lives.
///
/// Gizmos render as a run card for now. When they learn to describe their own
/// output they will hand back that view instead, and nothing here changes but
/// the closure — see `docs/superpowers/specs/2026-08-03-edge-dock-design.md`.
@MainActor
enum DockCatalog {
    static let notesID = "notes"

    /// Built-ins are configured in Settings; there is no editor to put them in.
    static func builtIns(host: any SettingsHost) -> [DockItem] {
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

    /// A gizmo's dock id is its UUID string — `DockStore` keys on `String`
    /// precisely so built-ins and gizmos can share one placement table.
    static func id(for tool: GizmateTool) -> String { tool.id.uuidString }

    static func gizmos(host: any SettingsHost) -> [DockItem] {
        host.tools.usableTools().map { tool in
            DockItem(
                id: id(for: tool),
                title: tool.name,
                symbolName: tool.resolvedSymbolName
            ) { [weak host] in
                let view = DockGizmoView(tool: tool) { [weak host] chosen in
                    host?.runTool(chosen, selection: "")
                }
                let hosting = NSHostingView(rootView: view)
                hosting.translatesAutoresizingMaskIntoConstraints = false
                return hosting
            }
        }
    }

    static func all(host: any SettingsHost) -> [DockItem] {
        builtIns(host: host) + gizmos(host: host)
    }

    static func item(id: String, host: any SettingsHost) -> DockItem? {
        all(host: host).first { $0.id == id }
    }

    static func knownIDs(host: any SettingsHost) -> Set<String> {
        Set(all(host: host).map(\.id))
    }
}
