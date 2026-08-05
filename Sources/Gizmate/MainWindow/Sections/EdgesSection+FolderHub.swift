import AppKit
import SwiftUI

/// The folder hub's own configuration — which folders it offers — folded in
/// here rather than left reachable only after docking it and opening its
/// panel, which was discovery by accident. `FolderHubView`'s chips and `+`
/// stay exactly where they are for use once it's docked; this file is a
/// second, independent view onto the same `FolderHubStore` so setup doesn't
/// require placing it on an edge first. Not shared code with `FolderHubView`:
/// that view's chips also select which folder its own preview grid shows, a
/// behavior this list has no use for — see DESIGN.md §12 on making a real
/// difference a parameter rather than forcing one shape to do two jobs.
///
/// Split out of `EdgesSection.swift` (Task 3 fix round 1): this concern never
/// needs `residents`, `unplaced`, or the drag machinery declared there, and
/// vice versa — the only thing shared is `cardHeading`, which is why that
/// one symbol is `internal` there instead of `private`.
extension EdgesSectionContent {
    /// Called from `EdgesSectionContent.body` in `EdgesSection.swift`, which
    /// is why this one is `internal` rather than `private` like the rest of
    /// this file.
    var folderHubSetupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeading("Files' folders")
            SubCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Which folders the Files edge shows.")
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.inkSecondary)
                    HStack(spacing: 8) {
                        if !folderHub.folders.isEmpty { folderChips }
                        Spacer(minLength: 0)
                        ResetDiscButton(symbol: "plus", label: "", accessibilityTitle: "Add folder") {
                            addFolder()
                        }
                    }
                }
            }
        }
    }

    private var folderChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(folderHub.folders, id: \.path) { folder in
                    folderChip(folder)
                }
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 24)
    }

    private func folderChip(_ folder: URL) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "folder").font(.system(size: 9))
            Text(folder.lastPathComponent).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(FlowTheme.inkSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(FlowTheme.subtleFill))
        // Native, no new UI to design — the same way `FolderHubView`'s own
        // chip has no remove button of its own.
        .contextMenu {
            Button("Remove", role: .destructive) { folderHub.remove(folder) }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a folder to show on the edge."
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        folderHub.add(picked)
    }
}
