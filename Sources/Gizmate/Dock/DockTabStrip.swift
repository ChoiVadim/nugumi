import SwiftUI

/// The row (top) or column (sides) of tabs a dock shows.
///
/// Never drawn for a single item — `EdgeDockController.expandedView` skips it
/// there, because one tab only names the thing you are already looking at.
struct DockTabStrip: View {
    let items: [DockItem]
    let activeID: String?
    let axis: Axis
    let onPick: (String) -> Void

    var body: some View {
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: DockGeometry.tabSpacing))
            : AnyLayout(VStackLayout(spacing: DockGeometry.tabSpacing))

        layout {
            ForEach(items, id: \.id) { item in
                Button { onPick(item.id) } label: {
                    Image(systemName: item.symbolName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(item.id == activeID ? FlowTheme.ink : FlowTheme.inkSecondary)
                        .frame(width: DockGeometry.tabSize, height: DockGeometry.tabSize)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(item.id == activeID ? FlowTheme.raised : FlowTheme.subtleFill)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.title)
            }
        }
        .padding(DockGeometry.stripPadding)
    }
}
