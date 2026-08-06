import AppKit
import GizmateToolAgentCore
import SwiftUI

/// The built-in edge dock item for dragging a file straight out of a folder.
///
/// Deliberately not a gizmo: a folder listing is `FileManager`, not an
/// arbitrary data source, so the script/agent/approval machinery a gizmo
/// carries would buy nothing here and would cost a cold start every time the
/// pointer nears the edge. This view is a sibling of `DockNotesView` — same
/// chip row, same `+`, same reuse of `SurfaceView` a `.surface` gizmo already
/// draws through, per `DESIGN.md` §12.
struct FolderHubView: View {
    @ObservedObject var store: FolderHubStore

    /// The chip in the header — the folder the user added, and the root of
    /// whatever is being browsed under it.
    @State private var selected: URL?
    /// The folder actually listed: `selected`, or a descendant of it after a
    /// double-click walked in. Separate from `selected` so back has a floor —
    /// you can only ever descend from a chip, so trimming one path component
    /// at a time can never climb above the folder that was added, and there is
    /// no trail to keep in step with anything.
    @State private var current: URL?
    @State private var rows: [SurfaceRow]
    /// The chip a double-click armed for removal, by path. At most one: arming
    /// a second disarms the first for free, since one string can only hold one.
    @State private var armedChip: String?
    /// The chip under the pointer, by path — the only thing that gives an
    /// unselected chip a background. Shared by chips and crumbs; a path
    /// identifies either one, and only one of the two rows is ever on screen.
    @State private var hoveredChip: String?
    /// The cards lit for a drag, by row id. Cleared whenever the listing
    /// changes: an id that is no longer on screen would keep contributing a
    /// file to every drag from a folder it isn't even in.
    @State private var selectedFiles: Set<String> = []

    /// The one layout this hub ever draws — declared once rather than built
    /// per render, the same way a gizmo's candidate layout is decoded once
    /// and reused across refreshes.
    /// No size line, deliberately. A cell is square and roughly 110pt wide, so
    /// the two lines it can spend go to the preview or to the metadata, not
    /// both — and you pick a file out of a shelf by recognising it, not by its
    /// byte count. The rows still carry `size` for anything that wants it.
    private static let layout: ToolAgentLayoutV1 = .grid(
        cell: .card(
            title: .key("name"),
            subtitle: nil,
            icon: .file(key: "path"),
            drag: .file(key: "path"),
            // No layout tap: what a click does here depends on what was
            // clicked — a file opens, a folder is walked into — and a layout
            // action is bound to a row, not to the hub's own position in a
            // tree. `activate` below does both, on double-click.
            tap: nil
        ),
        minimumWidth: 96,
        empty: "Nothing here yet."
    )

    /// Seeded synchronously, the same reasoning `SurfaceHostView` gives for
    /// seeding `rows` from its cache in `init`: a folder listing costs
    /// milliseconds, so there is no reason to show an empty grid for even one
    /// frame before the real contents land.
    init(store: FolderHubStore) {
        self.store = store
        let initial = store.folders.first
        _selected = State(initialValue: initial)
        // Every open builds a fresh view (`EdgeDockController.expandedView`
        // calls `makeView()` each time it expands), so a hub always opens at
        // the chip's own folder rather than wherever the last visit wandered.
        _current = State(initialValue: initial)
        _rows = State(initialValue: initial.map { FolderHubRows.rows(in: $0, limit: FolderHubRows.defaultLimit) } ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider().background(FlowTheme.hairline)
            // A folder listing never fails to refresh — it's a synchronous
            // `FileManager` read, not a script that can be unapproved, throw,
            // or exit non-zero — so there is no failure caption to show.
            SurfaceView(layout: Self.layout, rows: rows, stale: nil)
                .environment(\.surfaceActivate, activate)
                .environment(\.surfaceSelection, SurfaceSelection(
                    ids: selectedFiles,
                    click: { row, command in
                        if command {
                            // The only way back to nothing selected — there is
                            // no empty space to click in a grid that fills its
                            // panel, and a shelf you have to close and reopen
                            // to deselect is a shelf with a mode.
                            if selectedFiles.contains(row.id) {
                                selectedFiles.remove(row.id)
                            } else {
                                selectedFiles.insert(row.id)
                            }
                        } else {
                            selectedFiles = [row.id]
                        }
                    },
                    dragURLs: dragURLs
                ))
        }
        .padding(14)
        .foregroundStyle(FlowTheme.ink)
        // Picking a chip is picking a root: it lands you at the top of that
        // folder, never inside wherever the previous chip was browsed to.
        .onChange(of: selected) { _, folder in
            current = folder
        }
        .onChange(of: current) { _, folder in
            refresh(in: folder)
        }
        .onChange(of: store.folders) { _, folders in
            // The selected folder itself may have just been removed by its own
            // armed ✕ — fall back the same way a fresh open would rather than
            // keep rendering a chip that no longer exists.
            guard selected == nil || !folders.contains(where: { $0.path == selected?.path }) else { return }
            selected = folders.first
        }
    }

    // MARK: - Header

    /// Folder chips, then the `+` that adds one — the same shape
    /// `DockNotesView.header` uses for tags and its own add button.
    private var header: some View {
        HStack(spacing: 8) {
            if !store.folders.isEmpty { folderChips }
            Spacer(minLength: 0)
            ResetDiscButton(symbol: "plus", label: "", accessibilityTitle: "Add folder") {
                addFolder()
            }
        }
    }

    /// One row, two jobs, never both at once: the folders you added, or the
    /// path you are standing in. Showing the roots beside a trail asks the row
    /// to mean "pick a folder" and "you are here" in the same six chips, and
    /// the trail is the only one of the two that answers a question you have
    /// while you're deep in a folder. The roots come back the moment the trail
    /// collapses to its first crumb.
    private var folderChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if isBrowsingDeeper {
                    ForEach(Array(trail.enumerated()), id: \.element.path) { index, folder in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(FlowTheme.inkTertiary)
                        }
                        crumb(for: folder)
                    }
                } else {
                    ForEach(store.folders, id: \.path) { folder in
                        chip(for: folder)
                    }
                }
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 24)
    }

    private var isBrowsingDeeper: Bool { current?.path != selected?.path }

    /// The root chip, then every folder walked into on the way here.
    ///
    /// Built by trimming components off `current` rather than by keeping a
    /// stack: a stack is a second copy of where you are, and the two disagree
    /// the first time anything else moves `current`. The loop terminates on
    /// the root's own path because descending is the only way `current` is
    /// ever set — the length guard is what keeps a mismatch from walking to
    /// the volume root instead of hanging.
    private var trail: [URL] {
        guard let root = selected, var url = current else { return [] }
        var crumbs: [URL] = []
        while url.path != root.path, url.path.count > root.path.count {
            crumbs.append(url)
            url = url.deletingLastPathComponent()
        }
        crumbs.append(root)
        return crumbs.reversed()
    }

    /// A step in the trail. Tapping one goes there, which makes the crumb to
    /// the left of the last one the back button — there is no separate arrow
    /// to keep in step with the path any more.
    private func crumb(for folder: URL) -> some View {
        let isCurrent = folder.path == current?.path
        return Button {
            current = folder
        } label: {
            HStack(spacing: 4) {
                if folder.path == selected?.path {
                    Image(systemName: "folder").font(.system(size: 9))
                }
                // Capped: a folder saved by a browser is named after a page
                // title, and one of those spends a whole row on its own.
                Text(folder.lastPathComponent)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 140, alignment: .leading)
            }
            .foregroundStyle(isCurrent ? FlowTheme.ink : FlowTheme.inkSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(fill(here: isCurrent, folder: folder)))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hoveredChip = folder.path
            } else if hoveredChip == folder.path {
                hoveredChip = nil
            }
        }
    }

    /// What a chip or crumb is painted with. Bare is the resting state: a row
    /// of filled capsules is six painted pills saying nothing, and the label
    /// already carries the meaning. A fill has to earn itself — you are
    /// pointing at it, it is where you are, or it is armed to be deleted.
    private func fill(here: Bool, folder: URL) -> Color {
        if armedChip == folder.path { return FlowTheme.danger.opacity(0.18) }
        if here { return FlowTheme.raised }
        return hoveredChip == folder.path ? FlowTheme.subtleFill : .clear
    }

    /// A root folder, and the only place one can be taken off the shelf.
    ///
    /// Removal is two gestures, not one: a double-click arms the chip — red,
    /// with a ✕ — and the ✕ is what actually removes it. A ✕ that appeared on
    /// hover was one stray click away from deleting a folder the user was only
    /// reaching past, and nothing here can be undone: the store saves `[]`
    /// deliberately rather than revive the Downloads default (see `DESIGN.md`
    /// §11). Not a `Button` around the whole capsule, because the ✕ inside is
    /// its own button and a button nested in another button's label never gets
    /// the click.
    private func chip(for folder: URL) -> some View {
        let isSelected = folder.path == selected?.path
        let isArmed = armedChip == folder.path
        return HStack(spacing: 4) {
            Image(systemName: "folder").font(.system(size: 9))
            Text(folder.lastPathComponent)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: 140, alignment: .leading)
            if isArmed {
                // Inserted rather than faded in, unlike a hover affordance:
                // arming is a state the user asked for and is looking at, so
                // the row shifting under a chip that just turned red is the
                // feedback, not a glitch.
                Button {
                    store.remove(folder)
                    armedChip = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(folder.lastPathComponent)")
            }
        }
        .foregroundStyle(isArmed ? FlowTheme.danger : (isSelected ? FlowTheme.ink : FlowTheme.inkSecondary))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(fill(here: isSelected, folder: folder)))
        .contentShape(Capsule())
        // Declared before the single tap, which is what lets SwiftUI hand a
        // double click to this one instead of firing the single twice.
        .onTapGesture(count: 2) { armedChip = folder.path }
        .onTapGesture {
            selected = folder
            armedChip = nil
        }
        // Leaving the chip disarms it: an armed chip left behind is a red
        // capsule sitting in the row with no way back except deleting it.
        .onHover { inside in
            if inside {
                hoveredChip = folder.path
            } else {
                if hoveredChip == folder.path { hoveredChip = nil }
                if isArmed { armedChip = nil }
            }
        }
    }

    // MARK: - Actions

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a folder to show on the edge."
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        store.add(picked)
        // Read back from the store rather than trust `picked` directly: `add`
        // is what decides the canonical form a folder is compared by, and
        // matching it here is what keeps the new chip lit as selected.
        selected = store.folders.first { $0.path == picked.path } ?? picked
    }

    /// Double-click: a file opens in whatever owns it, a folder is browsed in
    /// place. Reading the path through `SurfaceCard.path` rather than the row
    /// directly keeps the one "there is no path here" rule shared with the
    /// icon and the drag — `URL(fileURLWithPath: "")` is the working
    /// directory, not nothing.
    private func activate(_ row: SurfaceRow) {
        guard let path = SurfaceCard.path(for: "path", in: row) else { return }
        let url = URL(fileURLWithPath: path)
        if FolderHubRows.isBrowsable(url) {
            current = url
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// What a drag off this card carries. Dragging a card that isn't in the
    /// selection drags that card alone and makes it the selection — Finder's
    /// own rule, and the one that stops a selection made three folders ago
    /// from riding along with the file actually under the pointer. Order is
    /// the grid's, not the selection's: a `Set` has none, and a drop that
    /// reshuffles the files is a drop the user has to sort out afterwards.
    private func dragURLs(from row: SurfaceRow) -> [URL] {
        guard selectedFiles.contains(row.id) else {
            selectedFiles = [row.id]
            return SurfaceCard.path(for: "path", in: row).map { [URL(fileURLWithPath: $0)] } ?? []
        }
        return rows
            .filter { selectedFiles.contains($0.id) }
            .compactMap { SurfaceCard.path(for: "path", in: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private func refresh(in folder: URL?) {
        rows = folder.map { FolderHubRows.rows(in: $0, limit: FolderHubRows.defaultLimit) } ?? []
        selectedFiles = []
    }
}
