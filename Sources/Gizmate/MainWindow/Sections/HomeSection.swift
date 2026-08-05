import SwiftUI

/// The front door: every tool in one list, whichever way it came to exist — a
/// shipped ring action or a gizmo the user built — with where it currently
/// lives, plus the one place to start building a new one without picking a
/// ring slot first. Before Task 4 of the navigation restructure this screen
/// *was* the ring (see `MainWindowSection`'s doc comment); the ring moved to
/// its own section, and this one now answers a different question: not "how
/// do I summon a tool" but "what do I have, and where is it" — Task 5 (the
/// header's "New gizmo" button) adds "and how do I make one" beside it.
///
/// Home never edits placement — picking a row opens the same editor its ring
/// slot or Edges row would (`RingSheet.builtInEditor` / `.toolEditor`), and
/// moving a tool between the ring and an edge stays the Ring tab's and
/// `EdgesSection`'s job. "New gizmo" opens that same tool editor with
/// `assignTo: nil` — exactly what already happens when editing any tool that
/// isn't sitting on a ring slot — so a freshly built gizmo lands unplaced,
/// findable right here afterwards as "Lives nowhere yet." This is a
/// directory with one door into the builder, not a placement picker.
struct HomeSection: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    var body: some View {
        HomeSectionContent(
            tools: bridge.tools,
            ringLayout: bridge.ringLayout,
            dock: bridge.dock,
            overrides: bridge.builtInOverrides
        )
    }
}

/// Split out so the stores it reads can be `@ObservedObject` — same reasoning
/// as `EdgesSectionContent`: `GizmateSettingsBridge` holds these as plain
/// `let` properties and never forwards their own publishers, so a tool being
/// added, renamed or moved needs its own subscription to redraw this list.
///
/// Internal, not private: `DockPlacementParityTests` builds one directly on
/// scratch `ToolsStore`/`RingLayoutStore`/`DockStore` instances and calls
/// `location(for:storageID:)` on it, the same reason
/// `ToolEditorPanel.outputsWithPlacementControl` is internal rather than
/// private — a test that reimplemented "is this reachable" as its own second
/// formula would guard nothing against this one drifting from it.
struct HomeSectionContent: View {
    @ObservedObject var tools: ToolsStore
    @ObservedObject var ringLayout: RingLayoutStore
    @ObservedObject var dock: DockStore
    @ObservedObject var overrides: BuiltInOverridesStore
    @EnvironmentObject var bridge: GizmateSettingsBridge
    /// Where a built-in's bound key is read from for `location(for:storageID:)`
    /// — the real suite in production, a scratch one in a test that wants to
    /// pin a specific binding without touching every other test's
    /// `UserDefaults.standard`.
    var shortcutDefaults: UserDefaults = .standard

    private var builtInRows: [HomeRow] {
        RingActionID.allCases.map { action in
            HomeRow(
                identity: .builtIn(action),
                title: overrides.displayName(for: action),
                icon: overrides.icon(for: action),
                location: location(
                    for: .builtIn(action),
                    storageID: ToolRef.builtIn(action).storageID
                )
            )
        }
    }

    /// Oldest first, the same order the ring's own "Your gizmos" tab uses
    /// (`RingSlotPickerPanel.tools`) — scanning both lists lands on the same
    /// gizmo in the same relative spot.
    private var gizmoRows: [HomeRow] {
        tools.usableTools()
            .sorted { $0.createdAt < $1.createdAt }
            .map { tool in
                HomeRow(
                    identity: .tool(tool),
                    title: tool.name,
                    icon: .symbol(tool.resolvedSymbolName),
                    location: location(
                        for: .tool(tool.id),
                        storageID: ToolRef.generated(tool.id).storageID
                    )
                )
            }
    }

    var body: some View {
        DetailContainer(
            "Home",
            subtitle: "Every tool you have, and where it lives.",
            accessory: AnyView(headerButtons)
        ) {
            group(title: "Built-in actions", rows: builtInRows, emptyText: nil)
            group(
                title: "Your gizmos",
                rows: gizmoRows,
                emptyText: "No gizmos yet. Use “New gizmo” above to build one."
            )
        }
    }

    /// The front door itself: opens the same builder chat a ring slot's "New
    /// gizmo" button does, but with no slot to land in — `assignTo: nil` is
    /// already the value `select(_:)` passes when editing a tool that isn't
    /// on the ring, so nothing downstream needed to learn a new state for
    /// this. The tool comes back unplaced, findable in the "Your gizmos" list
    /// below as "Lives nowhere yet."; giving it somewhere to live is a ring
    /// slot or an Edges pick away, same as for any other unplaced tool today.
    private var headerButtons: some View {
        ResetDiscButton(
            symbol: "plus",
            label: "New gizmo",
            accessibilityTitle: "New gizmo"
        ) {
            bridge.ringSheet = .toolEditor(id: nil, assignTo: nil)
        }
    }

    // MARK: - Groups

    private func group(title: String, rows: [HomeRow], emptyText: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeading(title)
            if rows.isEmpty {
                SubCard {
                    Text(emptyText ?? "Nothing here yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(FlowTheme.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                SubCard {
                    VStack(spacing: 2) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { Divider().background(FlowTheme.hairline) }
                            HomeToolRow(row: row, onSelect: { select(row) })
                        }
                    }
                }
            }
        }
    }

    private func cardHeading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(FlowTheme.inkSecondary)
            .textCase(.uppercase)
            .kerning(0.6)
    }

    /// Opens the same editor a ring slot or an Edges row would — a built-in's
    /// settings sheet, or a gizmo's own editor, both already rendered by
    /// `RingSheetOverlay` at the window root regardless of which sidebar
    /// section is showing.
    private func select(_ row: HomeRow) {
        switch row.identity {
        case .builtIn(let action):
            bridge.ringSheet = .builtInEditor(action)
        case .tool(let tool):
            bridge.ringSheet = .toolEditor(id: tool.id, assignTo: nil)
        }
    }

    /// Where `content` sits, out of every home a tool can have: a slot in the
    /// root ring, a slot in one of its sub-rings, an edge, a built-in's own
    /// global shortcut, or nowhere.
    ///
    /// The ring and `DockStore` never write to each other — `RingLayoutStore
    /// .assign` only vacates other slots in the *same* ring, and the only
    /// `dock.dock(` call site is `EdgesSection` — so a tool can genuinely sit
    /// on both at once, not "never both" the way an earlier version of this
    /// comment claimed. The ordinary way that happens is a `.surface` gizmo:
    /// `SurfaceRefresh` tells an unapproved one to "run it once from the
    /// ring", which needs a slot, for a gizmo whose entire point is the edge
    /// it draws rows on. When both are true for `.surface` content, the edge
    /// is checked first and wins — it is the answer that actually describes
    /// what the gizmo is for, where the ring slot is very possibly a leftover
    /// from approving it once. Everything else still checks the ring first,
    /// purely because it keeps the common case (a freshly-placed built-in)
    /// cheap, not because the two stores are mutually exclusive.
    ///
    /// A built-in with no ring slot and no edge still isn't `.nowhere`: every
    /// `RingActionID` with a `shortcutAction` always resolves a binding, saved
    /// or default — `GlobalShortcutStore.shortcut(for:)` never returns nil —
    /// so the key keeps running it regardless of ring or edge state.
    ///
    /// This is the one place that answers "is this tool reachable" for every
    /// kind of result, dockable or not — a `.clipboard` or `.notify` gizmo has
    /// no edge to ever sit on, so for one of those "reachable" collapses to
    /// "on a ring slot", and this function is what still gets that right.
    /// `.surface` is the only output kind it branches on, and only to prefer
    /// the edge when both homes are true; every other kind falls through the
    /// same ring/edge/shortcut/nowhere checks with no special-casing at all.
    func location(for content: RingSlotContent, storageID: String) -> HomeLocation {
        if case .tool(let id) = content,
           let tool = tools.tool(id: id), tool.output == .surface,
           let edge = dock.edge(of: storageID) {
            return .edge(edge)
        }
        if ringLayout.layout.slots.contains(content) {
            return .ring(folder: nil)
        }
        if let folder = ringLayout.folders.first(where: { $0.layout.slots.contains(content) }) {
            return .ring(folder: folder.name)
        }
        if let edge = dock.edge(of: storageID) {
            return .edge(edge)
        }
        if case .builtIn(let action) = content, let shortcutAction = action.shortcutAction {
            return .shortcut(GlobalShortcutStore.shortcut(for: shortcutAction, defaults: shortcutDefaults))
        }
        return .nowhere
    }
}

// MARK: - Row model

/// One entry in Home's list: a shipped ring action or a generated gizmo,
/// resolved down to what a row needs to draw itself and find its own editor.
private struct HomeRow: Identifiable {
    enum Identity {
        case builtIn(RingActionID)
        case tool(GizmateTool)
    }

    let identity: Identity
    let title: String
    let icon: RingIconKind
    let location: HomeLocation

    var id: String {
        switch identity {
        case .builtIn(let action): return ToolRef.builtIn(action).storageID
        case .tool(let tool): return ToolRef.generated(tool.id).storageID
        }
    }
}

/// Where a tool lives today, worded the same way the "locality pointer" text
/// in `BuiltInEditorPanel` and `ToolEditorPanel` already describes an edge
/// (see DESIGN.md §11) — this just also has a ring slot to name, since Home
/// is the one screen that has to speak for both. Internal for the same
/// reason `location(for:storageID:)` is: `DockPlacementParityTests` matches
/// on `.nowhere` and reads `.label` back from a real instance.
enum HomeLocation {
    case ring(folder: String?)
    case edge(DockEdge)
    /// A built-in with a `shortcutAction` and no ring slot or edge: it still
    /// runs, from the key `GlobalShortcutStore` resolves for it.
    case shortcut(GlobalShortcut)
    /// Saved but unreachable from anywhere a user would think to look — not a
    /// warning, just the plain truth about a tool nothing points at yet.
    case nowhere

    var label: String {
        switch self {
        case .ring(let folder):
            guard let folder else { return "In the ring." }
            return "In the ring, inside \u{201C}\(folder)\u{201D}."
        case .edge(let edge):
            return "On the \(edge.displayName) edge."
        case .shortcut(let shortcut):
            return "Runs with \(shortcut.displayString)."
        case .nowhere:
            return "Lives nowhere yet."
        }
    }
}

// MARK: - Row

/// One row: icon, name, and where it lives. Mirrors `EdgesSectionContent`'s
/// list rows (icon, title, spacer, trailing detail) rather than the ring slot
/// picker's option row (`RingSlotPickerPanel.optionRow` in
/// `RingSlotPicker.swift`) — that row is a private detail of a selection
/// modal, so it isn't reusable here, and Home already sits beside Edges in
/// the same flat-page family this restructure is building.
private struct HomeToolRow: View {
    let row: HomeRow
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: row.icon.image(pointSize: 15))
                .renderingMode(.template)
                .foregroundStyle(FlowTheme.inkSecondary)
                .frame(width: 18)
            Text(row.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FlowTheme.ink)
            Spacer(minLength: 12)
            Text(row.location.label)
                .font(.system(size: 11))
                .foregroundStyle(FlowTheme.inkTertiary)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}
