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
    /// The chip the pointer is over, by path — what reveals its remove ✕.
    @State private var hoveredChip: String?

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
            // The selected folder itself may have just been removed from the
            // chip row's own context menu — fall back the same way a fresh
            // open would rather than keep rendering a chip that no longer
            // exists.
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

    private var folderChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if isBrowsingDeeper { backChip }
                ForEach(store.folders, id: \.path) { folder in
                    chip(for: folder)
                }
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 24)
    }

    private var isBrowsingDeeper: Bool { current?.path != selected?.path }

    /// Back is a chip in the chips' own row rather than a disc beside the `+`:
    /// it has a name to carry. Two folders down, an unlabelled arrow says you
    /// can leave but not where you are, and the chip you started from is still
    /// lit two chips to its right.
    private var backChip: some View {
        Button {
            current = current?.deletingLastPathComponent()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold))
                // Capped: a folder saved by a browser is named after a page
                // title, and one of those spends the whole row on its own —
                // the root chips it sits beside got pushed off the edge.
                Text(current?.lastPathComponent ?? "")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 140, alignment: .leading)
            }
            .foregroundStyle(FlowTheme.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(FlowTheme.raised))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
    }

    /// Not a `Button` wrapping the whole capsule any more: the ✕ inside it is
    /// its own button, and a button nested in another button's label never
    /// gets the click.
    private func chip(for folder: URL) -> some View {
        let isSelected = folder.path == selected?.path
        return HStack(spacing: 4) {
            Image(systemName: "folder").font(.system(size: 9))
            Text(folder.lastPathComponent).font(.system(size: 11, weight: .medium))
            // Laid out always, faded until hover — inserting it on hover would
            // shove every chip to its right by 12pt as the pointer crosses the
            // row. Same trade `SnippetDisplayRow` makes for its own actions.
            // The context menu below stays: it is the only route on a trackpad
            // where hover and click are the same gesture.
            Button {
                store.remove(folder)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(FlowTheme.inkTertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hoveredChip == folder.path ? 1 : 0)
            .accessibilityLabel("Remove \(folder.lastPathComponent)")
        }
        .foregroundStyle(isSelected ? FlowTheme.ink : FlowTheme.inkSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(isSelected ? FlowTheme.raised : FlowTheme.subtleFill))
        .contentShape(Capsule())
        .onTapGesture { selected = folder }
        // Guarded rather than assigned outright: the exit of one chip can
        // arrive after the entry of the next, and clearing unconditionally
        // would blank the ✕ on the chip the pointer just moved onto.
        .onHover { inside in
            if inside {
                hoveredChip = folder.path
            } else if hoveredChip == folder.path {
                hoveredChip = nil
            }
        }
        .contextMenu {
            Button("Remove", role: .destructive) {
                store.remove(folder)
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

    private func refresh(in folder: URL?) {
        rows = folder.map { FolderHubRows.rows(in: $0, limit: FolderHubRows.defaultLimit) } ?? []
    }
}
