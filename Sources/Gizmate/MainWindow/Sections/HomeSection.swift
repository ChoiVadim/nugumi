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
/// `EdgesSection`'s job. "New gizmo" opens that same tool editor, and the
/// editor never places what it saves, so a freshly built gizmo lands unplaced,
/// findable right here afterwards marked "Nowhere". This is a directory with
/// one door into the builder, not a placement picker.
///
/// This is now the *only* door: the ring's slot picker used to carry its own
/// "New gizmo" button, which meant building one and placing one were the same
/// gesture and a gizmo could not be made without first choosing a slot.
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
                detail: action.summary,
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
                    // The request it was built from, which is the closest thing
                    // a generated gizmo has to `RingActionID.summary`. Empty for
                    // one written by hand, and then the row simply has no second
                    // line — a made-up sentence would be worse than none.
                    detail: tool.brief.isEmpty ? nil : tool.brief,
                    location: location(
                        for: .tool(tool.id),
                        storageID: ToolRef.generated(tool.id).storageID
                    )
                )
            }
    }

    /// Your own gizmos lead, the ten shipped actions follow. The built-ins are a
    /// fixed set you learn once; the gizmo list is the one that changes, and it
    /// is the one the header button writes into — so putting it second meant
    /// scrolling past ten unchanging rows to reach the only part of this screen
    /// that ever differs between two visits. On a fresh install the empty state
    /// leads instead, which is where the second "New gizmo" button lives: the
    /// old copy pointed at a control ("Use “New gizmo” above") whose label is
    /// only drawn on hover, so it named a string that was not on screen.
    var body: some View {
        DetailContainer(
            "Home",
            subtitle: "Everything Gizmate can do, and where each one lives.",
            accessory: AnyView(newGizmoButton)
        ) {
            group(
                title: "Your gizmos",
                note: unplacedNote,
                rows: gizmoRows,
                empty: AnyView(noGizmosYet)
            )
            group(title: "Built-in actions", note: nil, rows: builtInRows, empty: nil)
        }
    }

    /// The count said once, at the group, instead of once per tile. A library
    /// that is mostly unplaced turns the per-tile marker into wallpaper — every
    /// tile carrying the same tag marks nothing — and "7 of 8 live nowhere" is
    /// the one sentence that actually sizes the problem. Absent when there is
    /// nothing to report, so it never becomes another permanent label.
    private var unplacedNote: String? {
        let unplaced = gizmoRows.filter(\.location.needsAttention).count
        guard unplaced > 0 else { return nil }
        return "\(unplaced) of \(gizmoRows.count) live nowhere"
    }

    /// The front door itself: opens the builder chat with no slot to land in.
    /// The tool comes back unplaced, findable in the "Your gizmos" list below
    /// marked "Nowhere"; giving it somewhere to live is a ring slot or an Edges
    /// pick away, same as for any other unplaced tool today.
    ///
    /// A labelled button rather than the `ResetDiscButton` this used to be. That
    /// control is right for a reset — a bare glyph whose label appears on hover,
    /// so a destructive-ish affordance nobody is looking for stays quiet — and
    /// wrong for the one action this whole screen exists to offer. "Build me a
    /// new one" is half of Home's job per the sidebar's own contract, and a
    /// naked `+` states none of it until the pointer happens to land on it.
    private var newGizmoButton: some View {
        SecondaryButton(title: "New gizmo") {
            bridge.ringSheet = .toolEditor(id: nil)
        }
    }

    /// An empty state that *is* the action, rather than a sentence describing
    /// where to find it.
    private var noGizmosYet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nothing built yet. Describe what you want and Gizmate writes it.")
                .font(.system(size: 13))
                .foregroundStyle(FlowTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            SecondaryButton(title: "New gizmo") {
                bridge.ringSheet = .toolEditor(id: nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Groups

    /// Tiles, not rows in a `SubCard`. Home was the only section drawing a flat
    /// list while Ring and Edges each draw a figure, and a two-column table of
    /// name-and-place read as a spreadsheet next to them. The grid also spends
    /// width this page had going spare — the old row put a name at the left edge
    /// and one short value at the right with two thirds of the line empty — and
    /// it is what finally gives the icons weight: at 15pt in `inkSecondary` they
    /// were decoration, at 17pt on a tinted disc they are how you find a tool
    /// without reading.
    ///
    /// No `SubCard` around them: a tile is already a card, and DESIGN.md §4
    /// forbids the nesting. The empty state keeps its `SubCard`, because that
    /// one really is a single panel rather than a grid of them.
    private func group(title: String, note: String?, rows: [HomeRow], empty: AnyView?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                cardHeading(title)
                Spacer(minLength: 8)
                if let note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(FlowTheme.inkTertiary)
                }
            }
            if rows.isEmpty {
                SubCard { empty ?? AnyView(EmptyView()) }
            } else {
                // Same idiom and same 14pt rhythm as `NotesSection`'s grid, and
                // lazy for the same reason it is safe there: `DetailContainer`
                // is a plain `ScrollView` with a bounded viewport, not the
                // `OverlayScrollHost` that DESIGN.md §8 bans lazy containers in.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 232), spacing: 14)],
                    alignment: .leading,
                    spacing: 14
                ) {
                    ForEach(rows) { row in
                        HomeToolTile(row: row, onSelect: { select(row) })
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
            bridge.ringSheet = .toolEditor(id: tool.id)
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
    /// What this tool does, in one line. Home's stated job is "what can Gizmate
    /// do", and a row carrying only a name and a place never answered it — the
    /// sentences already existed (`RingActionID.summary`, `GizmateTool.brief`)
    /// and were shown only in the ring's slot picker. nil where a hand-written
    /// gizmo has no brief to show.
    let detail: String?
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

    /// A **value**, not a sentence. These used to read "In the ring." / "On the
    /// Right edge." / "Lives nowhere yet.", and with ten built-ins nearly all of
    /// them on the ring, the trailing column printed the same sentence eight
    /// times over. A repeated default drowns the exception it sits next to: the
    /// two rows that genuinely differed had to be *found* inside the repetition
    /// rather than standing out from it. Short tokens make the column scannable
    /// — the eye reads the shape of "Ring" against "⌃⌥Z" without parsing prose —
    /// and the crumb separator is the one the folder hub already uses for a path.
    var label: String {
        switch self {
        case .ring(let folder):
            guard let folder else { return "Ring" }
            return "Ring \u{203A} \(folder)"
        case .edge(let edge):
            return "\(edge.displayName) edge"
        case .shortcut(let shortcut):
            return shortcut.displayString
        case .nowhere:
            return "Nowhere"
        }
    }

    /// Whether this row's location gets a shape rather than a shade — DESIGN.md
    /// §11's rule, applied to the one state on this screen that is worth
    /// noticing. It is still not a warning (§11: "just the plain truth about a
    /// tool nothing points at yet"), so it takes no `danger` tint; a capsule is
    /// present or absent, which is what a tertiary grey sentence among nine
    /// other tertiary grey values could never be.
    var needsAttention: Bool {
        if case .nowhere = self { return true }
        return false
    }
}

// MARK: - Row

/// One tile: glyph on a tinted disc, name, what it does, and where it lives
/// along the bottom.
///
/// Height comes from the row, not from a constant. `LazyVGrid` already gives
/// every tile in a row the tallest one's height, so `maxHeight: .infinity` plus
/// a `Spacer` above the footer is all it takes to line the footers up — while a
/// row whose tiles are all one-liners stays short. Pinning a constant instead
/// bought that same alignment and charged every short tile a hole beneath its
/// text: "Sends the selected text to Telegram." sat above 47pt of nothing.
/// DESIGN.md §13's fixed cell is a different case — a square grid of files
/// inherits its height from the column width, and uniform cells there are the
/// point because a two-line filename must not outgrow its neighbours.
private struct HomeToolTile: View {
    let row: HomeRow
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: row.icon.image(pointSize: 17))
                .renderingMode(.template)
                .foregroundStyle(FlowTheme.ink)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(0.08)))
            Text(row.title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(FlowTheme.ink)
                .lineLimit(2)
                .padding(.top, 12)
            if let detail = row.detail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(FlowTheme.inkSecondary)
                    .lineLimit(2)
                    .padding(.top, 4)
            }
            Spacer(minLength: 10)
            location
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        // A fill that says "you are pointing at me" and nothing else — the tile
        // rests on `subtleFill` like every other panel on this page, and lifts
        // to `raised` under the pointer. No shadow: DESIGN.md §7 builds depth
        // from tonal fills and hairlines, not from drop shadows.
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(hovering ? FlowTheme.raised : FlowTheme.subtleFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(hovering ? FlowTheme.edge : FlowTheme.hairline, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: onSelect)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.13)) { hovering = inside }
        }
    }

    @ViewBuilder
    private var location: some View {
        if row.location.needsAttention {
            // Quiet tag, not the accent one. The capsule alone already does the
            // whole job — it is present or absent, which is what a tertiary grey
            // sentence among nine other tertiary grey values could never be —
            // and tinting it as well assumed this state would be rare. It isn't:
            // a real library turns out to be mostly unplaced gizmos, and eight
            // lit capsules down one column mark nothing. Emphasis is relative,
            // so the treatment has to survive the case where the exception is
            // the majority.
            RingTag(text: row.location.label)
        } else {
            Text(row.location.label)
                .font(.system(size: 11))
                .foregroundStyle(FlowTheme.inkTertiary)
                .lineLimit(1)
        }
    }
}
