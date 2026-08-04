import AppKit
import SwiftUI

/// One thing a dock can hold.
///
/// A struct with a closure rather than a protocol: `NSView` is the only thing a
/// dock ever needs from its contents, and a protocol with one conformer is a
/// shape waiting for a second. A built-in's surface, a gizmo's run card, and in
/// time a gizmo's own rendered output all arrive through `makeView`, and the
/// dock cannot tell them apart.
struct DockItem {
    /// `ToolRef.storageID` — stable across launches, and what `DockStore` keys on.
    let id: String
    let title: String
    /// The same icon type the ring draws, not an SF Symbol name: five built-ins
    /// wear bundled Phosphor art, and inventing SF Symbol stand-ins for them
    /// would put a different glyph in the dock than on the ring button.
    let icon: RingIconKind
    let makeView: () -> NSView
}

/// Everything dockable: the shipped actions, then every usable gizmo.
///
/// Built against `SettingsHost` rather than `GizmateSettingsBridge` — the bridge
/// belongs to `MainWindowController` and dies with the main window, while a dock
/// has to work when no window is open at all.
@MainActor
enum DockCatalog {
    /// Everything that ships, minus Summarize: its ring button is built from the
    /// frontmost app — an app icon plus a time-range orbit — so there is nothing
    /// meaningful to park on an edge waiting. `performBuiltIn` ignores it for
    /// the same reason.
    static let dockableBuiltIns: [RingActionID] =
        RingActionID.allCases.filter { $0 != .summarize }

    static func builtIns(host: any SettingsHost) -> [DockItem] {
        let overrides = host.builtInOverrides
        return dockableBuiltIns.map { action in
            DockItem(
                id: ToolRef.builtIn(action).storageID,
                title: overrides.displayName(for: action),
                icon: overrides.icon(for: action)
            ) { [weak host] in
                hosted(surface(for: action, host: host))
            }
        }
    }

    static func gizmos(host: any SettingsHost) -> [DockItem] {
        host.tools.usableTools().map { tool in
            DockItem(
                id: ToolRef.generated(tool.id).storageID,
                title: tool.name,
                icon: .symbol(tool.resolvedSymbolName)
            ) { [weak host] in
                hosted(
                    AnyView(
                        DockRunCard(
                            title: tool.name,
                            icon: .symbol(tool.resolvedSymbolName),
                            subtitle: tool.output.displayName,
                            footnote: tool.input.displayName,
                            options: tool.options
                        ) { option in
                            var chosen = tool
                            chosen.chosenOption = option
                            host?.runTool(chosen, selection: "")
                        }
                    )
                )
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

    // MARK: - Surfaces

    /// Note already has a view — the notes list, which is what "keep this" is
    /// *for*. Every other built-in still owns its own window, so it docks as a
    /// run card until those become views.
    private static func surface(for action: RingActionID, host: (any SettingsHost)?) -> AnyView {
        let overrides = host?.builtInOverrides
        if action == .saveNote, let host {
            return AnyView(DockNotesView(notes: host.notes))
        }
        return AnyView(
            DockRunCard(
                title: overrides?.displayName(for: action) ?? action.displayName,
                icon: overrides?.icon(for: action) ?? action.icon,
                subtitle: action.summary,
                footnote: "",
                options: []
            ) { _ in
                host?.performBuiltIn(action)
            }
        )
    }

    private static func hosted(_ view: AnyView) -> NSView {
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        return hosting
    }
}
