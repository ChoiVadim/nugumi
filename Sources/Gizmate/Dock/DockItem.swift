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
    /// Built-ins whose surface can already be placed on an edge.
    ///
    /// A screen edge is an alternative *panel*, not a second Ring: the choice
    /// only means something for a tool that shows something. Today that is Note
    /// alone, because the notes list is the one surface that already exists as a
    /// view — Ask, Live and the result panel still create their own windows, so
    /// there is nothing to hand a dock.
    ///
    /// Explain, Reply, Ask, Capture, Summarize and Live all join this list the
    /// moment their panels become views. Rewrite and Dictate never will: they
    /// write into the app you were in and show no panel at all.
    /// See `docs/superpowers/specs/2026-08-03-one-tool-model-design.md`, phase 3.
    static let dockableBuiltIns: [RingActionID] = [.saveNote]

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

    /// None yet. A gizmo with `output == .panel` earns a placement choice as
    /// soon as the result panel is a view rather than a window; until then the
    /// only honest answer is that it has none. A run button on an edge is a
    /// second launcher, which is what this replaced.
    static func gizmos(host: any SettingsHost) -> [DockItem] { [] }

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

    /// Note's surface is the notes list — which is what "keep this" is *for*.
    /// Nothing else is in `dockableBuiltIns` yet, so nothing else reaches here.
    private static func surface(for action: RingActionID, host: (any SettingsHost)?) -> AnyView {
        guard action == .saveNote, let host else { return AnyView(EmptyView()) }
        return AnyView(DockNotesView(notes: host.notes))
    }

    private static func hosted(_ view: AnyView) -> NSView {
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        return hosting
    }
}
