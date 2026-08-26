import AppKit
import SwiftUI

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            brandHeader
                // The same inset a row's own content sits at (the row adds 10
                // inside its capsule), so the wordmark and the section icons
                // stand on one line. At 6 the logo sat four points left of
                // every icon under it, which is the kind of misalignment you
                // see without being able to name.
                .padding(.horizontal, 10)
                .padding(.bottom, 20)

            ForEach(MainWindowSection.primary) { NavItem(section: $0) }

            Spacer(minLength: 16)

            Divider().background(FlowTheme.hairline).padding(.vertical, 6)
            ForEach(MainWindowSection.secondary) { NavItem(section: $0) }
        }
        // A row's margin is measured against what the eye can see, and on the
        // right that is the detail card's edge, not this view's frame. Padding
        // both sides by 12 put the row 12 from the window and 22 from the card,
        // because the card's own leading inset lands in the same gap. Subtract
        // it and both margins read as 12.
        .padding(.leading, 12)
        .padding(.trailing, 12 - DetailCardMetrics.leadingInset)
        .padding(.top, 30)   // clear the traffic lights
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var brandHeader: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(nsImage: Self.brandIcon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 32, height: 32)
            // "Gizmate" with a small round β badge raised like a superscript.
            HStack(alignment: .top, spacing: 1) {
                Text("Gizmate")
                    .font(.gizmatePixel(18))
                    .foregroundStyle(.white)
                    .fixedSize()
                Text("β")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(FlowTheme.accent)
                    .offset(y: -2)
            }
            Spacer(minLength: 0)
            if bridge.updateAvailable {
                Button(action: { bridge.installUpdate() }) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(FlowTheme.accent)
                }
                .plainButton()
                .help("Update available - click to install")
            }
        }
        .frame(height: 34)
    }

    private static let brandIcon: NSImage = BrandMark.trimmedIcon ?? NSApp.applicationIconImage
}

struct NavItem: View {
    let section: MainWindowSection
    @EnvironmentObject var bridge: GizmateSettingsBridge

    var body: some View {
        let isSelected = bridge.section == section
        Button {
            bridge.section = section
        } label: {
            HStack(spacing: 11) {
                Image(systemName: section.symbol)
                    .font(.system(size: 14))
                    .frame(width: 20)
                Text(section.title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.white : Color(white: 0.82))
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? FlowTheme.selected : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .plainButton()
    }
}
