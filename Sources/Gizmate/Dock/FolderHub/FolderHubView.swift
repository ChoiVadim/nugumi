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

    @State private var selected: URL?
    @State private var rows: [SurfaceRow]

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
            tap: .reveal(key: "path")
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
        }
        .padding(14)
        .foregroundStyle(FlowTheme.ink)
        .onChange(of: selected) { _, folder in
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
                ForEach(store.folders, id: \.path) { folder in
                    chip(for: folder)
                }
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 24)
    }

    private func chip(for folder: URL) -> some View {
        let isSelected = folder.path == selected?.path
        return Button {
            selected = folder
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder").font(.system(size: 9))
                Text(folder.lastPathComponent).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isSelected ? FlowTheme.ink : FlowTheme.inkSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(isSelected ? FlowTheme.raised : FlowTheme.subtleFill))
        }
        .buttonStyle(.plain)
        // Native, no new UI to design — the same way a note's tag chip has no
        // remove button of its own.
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

    private func refresh(in folder: URL?) {
        rows = folder.map { FolderHubRows.rows(in: $0, limit: FolderHubRows.defaultLimit) } ?? []
    }
}
