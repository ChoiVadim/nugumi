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
private struct HomeSectionContent: View {
    @ObservedObject var tools: ToolsStore
    @ObservedObject var ringLayout: RingLayoutStore
    @ObservedObject var dock: DockStore
    @ObservedObject var overrides: BuiltInOverridesStore
    @EnvironmentObject var bridge: GizmateSettingsBridge

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
            PageBanner(
                title: "Everything you've built",
                message: "Shipped actions and your own gizmos, all in one place, each one saying "
                    + "where it currently sits — a ring slot, a screen edge, or nowhere yet. "
                    + "Pick one to open its editor, or start a new one above.",
                symbol: "square.grid.2x2",
                dismissKey: "homeBannerDismissed"
            )
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

    /// Where `content` sits: a slot in the root ring, a slot in one of its
    /// sub-rings, an edge, or nowhere. The ring is checked first — assigning a
    /// slot never touches `DockStore` and vice versa, so nothing can ever
    /// match both, but checking ring-then-edge keeps the search cheap for the
    /// common case of a freshly-placed built-in.
    private func location(for content: RingSlotContent, storageID: String) -> HomeLocation {
        if ringLayout.layout.slots.contains(content) {
            return .ring(folder: nil)
        }
        if let folder = ringLayout.folders.first(where: { $0.layout.slots.contains(content) }) {
            return .ring(folder: folder.name)
        }
        if let edge = dock.edge(of: storageID) {
            return .edge(edge)
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
/// is the one screen that has to speak for both.
private enum HomeLocation {
    case ring(folder: String?)
    case edge(DockEdge)
    /// Saved but unreachable from anywhere a user would think to look — not a
    /// warning, just the plain truth about a tool nothing points at yet. A
    /// later task makes this state fixable straight from this row.
    case nowhere

    var label: String {
        switch self {
        case .ring(let folder):
            guard let folder else { return "In the ring." }
            return "In the ring, inside \u{201C}\(folder)\u{201D}."
        case .edge(let edge):
            return "On the \(edge.displayName) edge."
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
