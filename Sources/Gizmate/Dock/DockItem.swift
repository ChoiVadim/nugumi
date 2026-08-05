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
    /// Ask and Live are still missing: they build their own windows, so there
    /// is nothing to hand a dock yet. Rewrite and Dictate never join — they
    /// write into the app you were in and show no panel at all.
    /// See `docs/superpowers/specs/2026-08-03-one-tool-model-design.md`, phase 3.
    static let dockableBuiltIns: [RingActionID] = [.saveNote, .explain, .reply, .summarize]

    /// Only surfaces that can sit on an edge *waiting*. A result panel is not
    /// one: it exists after a run, and until then there is nothing to show, so
    /// it must not put a tab there implying otherwise. `gizmos(host:)` below
    /// applies the same rule to user-built tools — a `.surface` gizmo is
    /// resident for the same reason Note is: both have something to draw
    /// before any run starts.
    static let residentBuiltIns: [RingActionID] = [.saveNote]

    /// Which gizmo outputs `gizmos(host:)` is willing to list. `.surface` is
    /// the only member today, for the same reason `residentBuiltIns` above is
    /// just Note — but this is its own named set, not an inline filter,
    /// because `ToolEditorPanel.outputsWithPlacementControl` has to be
    /// checked against it: an output added here without a matching entry
    /// there is a gizmo the dock will list and no control can ever dock.
    static let dockableGizmoOutputs: Set<ToolOutput> = [.surface]

    static func builtIns(host: any SettingsHost) -> [DockItem] {
        let overrides = host.builtInOverrides
        return residentBuiltIns.map { action in
            DockItem(
                id: ToolRef.builtIn(action).storageID,
                title: overrides.displayName(for: action),
                icon: overrides.icon(for: action)
            ) { [weak host] in
                hosted(surface(for: action, host: host))
            }
        }
    }

    /// Every usable `.surface` gizmo. A surface is the one result that exists
    /// while nothing is running — its script already printed rows the last
    /// time it ran, and the dock can draw those before it ever calls the
    /// script again (`SurfaceHostView`). Every other result — `.panel`,
    /// `.clipboard`, `.notes`, and the rest — is still something you summon:
    /// there is nothing to show until a run finishes, so a tab for one of
    /// those on an edge would either sit empty or imply a run that never
    /// happened. A run button on an edge is a second launcher, which is what
    /// this replaced.
    static func gizmos(host: any SettingsHost) -> [DockItem] {
        host.tools.usableTools()
            .filter { dockableGizmoOutputs.contains($0.output) }
            .map { tool in
                DockItem(
                    id: ToolRef.generated(tool.id).storageID,
                    title: tool.name,
                    // User tools draw from SF Symbols, never the bundled
                    // Phosphor set built-ins use — see `resolvedSymbolName`.
                    icon: .symbol(tool.resolvedSymbolName)
                ) { [weak host] in
                    guard let host else { return NSView() }
                    return hosted(AnyView(SurfaceHostView(tool: tool, host: host)))
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

    /// Everything a placement may name — resident surfaces *and* the tools whose
    /// result panel can open on an edge. `prune` keys off this, not `knownIDs`:
    /// a docked Explain has no waiting tab, and dropping its placement for that
    /// reason would silently undo the user's choice.
    static func placeableIDs(host: any SettingsHost) -> Set<String> {
        knownIDs(host: host)
            .union(dockableBuiltIns.map { ToolRef.builtIn($0).storageID })
            .union(host.tools.usableTools().map { ToolRef.generated($0.id).storageID })
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
