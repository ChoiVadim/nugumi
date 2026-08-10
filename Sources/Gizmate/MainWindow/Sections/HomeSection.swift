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
        DetailCard {
            HStack(spacing: 0) {
                if let host = bridge.host {
                    HomeChatPane(
                        tools: tools,
                        conversation: host.homeChat,
                        builder: host.gizmoBuilder
                    )
                }
                if bridge.showsGizmoRail {
                    Divider().background(FlowTheme.hairline)
                    rail
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .overlay(alignment: .topTrailing) {
                // Beside the panel toggle rather than in the composer: both are
                // things you do to the whole conversation, not to the message
                // you are writing, and chrome for the window belongs in the
                // window's chrome. Same quiet-until-hovered treatment for the
                // same reason — see `PanelToggleButton`.
                HStack(spacing: 2) {
                    if let host = bridge.host {
                        ChromeIconButton(
                            symbol: "square.and.pencil",
                            help: "Start a new chat"
                        ) {
                            host.homeChat.clear()
                            host.gizmoBuilder.startFresh()
                        }
                    }
                    PanelToggleButton(
                        isOpen: bridge.showsGizmoRail,
                        edge: .trailing,
                        help: bridge.showsGizmoRail ? "Hide your gizmos" : "Show your gizmos"
                    ) {
                        withAnimation(.easeOut(duration: 0.18)) { bridge.showsGizmoRail.toggle() }
                    }
                }
                .padding(10)
            }
        }
    }

    /// Everything Gizmate can do, beside the chat rather than instead of it.
    ///
    /// The tile grid this replaces answered Home's half of the sidebar contract
    /// — what can Gizmate do, and where does each one live — and it still has
    /// to, which is why every row keeps its `location` line and the group keeps
    /// its count. What it stops being is the way you *reach* a gizmo: clicking
    /// one used to open a modal, and now it just tells the chat what you are
    /// talking about.
    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No `+`. It opened a second builder in a modal, with a second
            // chat inside it saying "tell me what you want to happen" beside a
            // chat already asking exactly that. Two ways to start one thing is
            // two things to keep working, and the one this rail sits next to is
            // the one that is the product.
            HStack(alignment: .firstTextBaseline) {
                cardHeading("Your gizmos")
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if gizmoRows.isEmpty {
                        Text("Nothing built yet. Describe what you want in the chat.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(FlowTheme.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 10)
                    }
                    ForEach(gizmoRows) { row in
                        railRow(row, isActive: isActive(row))
                    }
                    if let unplacedNote {
                        Text(unplacedNote)
                            .font(.system(size: 11))
                            .foregroundStyle(FlowTheme.inkTertiary)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }
                    cardHeading("Built-in actions")
                        .padding(.horizontal, 16)
                        .padding(.top, 22)
                        .padding(.bottom, 8)
                    ForEach(builtInRows) { row in
                        railRow(row, isActive: false)
                    }
                }
                .padding(.bottom, 20)
            }
            .scrollIndicators(.never)
        }
        .frame(width: 268)
        .padding(.top, 24)
    }

    /// Lit when the build in flight is about this gizmo, so the rail and the
    /// transcript never disagree about what is being worked on.
    private func isActive(_ row: HomeRow) -> Bool {
        guard case .tool(let tool) = row.identity,
              case .existing(let building)? = bridge.host?.gizmoBuilder.live?.subject
        else { return false }
        return building == tool.id
    }

    private func railRow(_ row: HomeRow, isActive: Bool) -> some View {
        Button { select(row) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: row.icon.image(pointSize: 14))
                    .renderingMode(.template)
                    .foregroundStyle(FlowTheme.ink)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(FlowTheme.ink)
                        .lineLimit(1)
                    HomeRowLocationLabel(location: row.location, emphasised: false)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? FlowTheme.accentSoft : .clear)
                    .padding(.horizontal, 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(row.detail ?? row.title)
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

    // MARK: - Groups

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
            // The same modal a built-in gets, on the same click, showing the
            // same kind of thing: what this gizmo *is*. What it *does* is
            // changed by talking to the chat, which is why this no longer
            // opens a second conversation per gizmo.
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

/// Where a tool lives, said the same way wherever it is said.
///
/// DESIGN.md §11: nothing may live nowhere without saying so, and that outlives
/// whichever view happens to be drawing the list this week.
struct HomeRowLocationLabel: View {
    let location: HomeLocation

    /// Whether the capsule is drawn at all.
    ///
    /// Off in a list, on in isolation, and the reason is that emphasis is
    /// relative. Nine rows of "Nowhere" capsules mark nothing — DESIGN.md §11
    /// says exactly that about the tile grid this replaced, and the rail
    /// reintroduced it — because when most of a list shares a value, the value
    /// is the background. The words stay on every row either way, which is what
    /// keeps "nothing lives nowhere without saying so" true; only the shouting
    /// goes.
    var emphasised: Bool = true

    @ViewBuilder
    var body: some View {
        if location.needsAttention, emphasised {
            // Quiet tag, not the accent one. The capsule alone already does the
            // whole job — it is present or absent, which is what a tertiary grey
            // sentence among nine other tertiary grey values could never be —
            // and tinting it as well assumed this state would be rare. It isn't:
            // a real library turns out to be mostly unplaced gizmos, and eight
            // lit capsules down one column mark nothing. Emphasis is relative,
            // so the treatment has to survive the case where the exception is
            // the majority.
            RingTag(text: location.label)
        } else {
            Text(location.label)
                .font(.system(size: 11))
                .foregroundStyle(FlowTheme.inkTertiary)
                .lineLimit(1)
        }
    }
}
