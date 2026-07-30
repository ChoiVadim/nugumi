import AppKit
import SwiftUI

/// Horizontal strip of circular app icons for a Style category, with a trailing
/// "+" to assign any installed app. Every icon can be removed (built-ins are
/// suppressed, user-added ones deleted) via its ✕ overlay.
struct AppIconStrip: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge
    let category: AppCategory
    let apps: [AppRef]

    private let diameter: CGFloat = 52   // container circle
    private let iconSize: CGFloat = 34   // app logo centered inside it
    private let overlap: CGFloat = 15    // how far each circle laps the next

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: -overlap) {
                ForEach(Array(apps.enumerated()), id: \.element.bundleID) { index, app in
                    AppIconBubble(app: app, diameter: diameter, iconSize: iconSize) {
                        bridge.perform(.removeApp(app.bundleID))
                    }
                    // Leading icons sit on top so each laps over the one to its
                    // right — and every ✕ stays clickable above its neighbour.
                    .zIndex(Double(apps.count - index))
                }
                Button {
                    bridge.perform(.addAppToCategory(category))
                } label: {
                    ZStack {
                        CircleDisc()
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(FlowTheme.inkSecondary)
                    }
                    .frame(width: diameter, height: diameter)
                }
                .buttonStyle(.plain)
                .help("Add an app to \(category.displayName)")
            }
            .padding(.vertical, 4)
            .padding(.trailing, 2)
        }
    }
}

private struct AppIconBubble: View {
    let app: AppRef
    let diameter: CGFloat
    let iconSize: CGFloat
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                CircleDisc()
                appIcon
                    .frame(width: iconSize, height: iconSize)
            }
            .frame(width: diameter, height: diameter)

            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white, Color.black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
        }
        .frame(width: diameter, height: diameter)
        .onHover { hovering = $0 }
        .help(app.name)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = AppIconProvider.icon(for: app.bundleID) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: iconSize * 0.23, style: .continuous)
                    .fill(FlowTheme.accentSoft)
                Text(String(app.name.prefix(1)).uppercased())
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FlowTheme.ink)
            }
        }
    }
}

/// The round container behind each app icon. It carries its own `.menu`
/// vibrancy (the raw material, without the card's black-0.26 darkening), so it
/// renders a touch lighter than the card — reading as a raised disc — and, being
/// opaque to in-window content, fully occludes the ring of any circle it laps
/// over instead of letting it bleed through. Tracks the wallpaper like the card.
private struct CircleDisc: View {
    var body: some View {
        VisualEffectBackground(material: .menu)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(FlowTheme.hairline, lineWidth: 1))
    }
}

/// Resolves and caches app icons by bundle identifier via NSWorkspace.
enum AppIconProvider {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}

/// Multi-line editor for the email voice sample (email category only). Edits a
/// local draft and persists every change through the settings intent, mirroring
/// how the rest of the Style section saves immediately. The `TextEditor` binds
/// to local `@State` rather than the republished snapshot, so the cursor stays
/// put while the bridge refreshes after each write.
struct EmailVoiceSampleEditor: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge
    @State private var draft: String

    init(sample: String) {
        _draft = State(initialValue: sample)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Voice sample")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FlowTheme.inkSecondary)
            Text("Paste an email you typically send. Gizmate mirrors its greeting, rhythm, and sign-off when it writes email replies.")
                .font(.system(size: 12))
                .foregroundStyle(FlowTheme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)

            PlainTextEditor(text: $draft)
                .frame(minHeight: 104)
                .padding(.vertical, 7)
                .padding(.horizontal, 11)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Hello,\n\n…\n\nBest regards,\nYour name")
                            .font(.system(size: 13))
                            .foregroundStyle(FlowTheme.inkTertiary.opacity(0.55))
                            .padding(.vertical, 7)
                            .padding(.horizontal, 11)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: draft) { _, newValue in
                    bridge.perform(.setEmailVoiceSample(newValue))
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Minimal flow layout that wraps its children onto new rows as needed.
private struct FlowWrap: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0, rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0, totalWidth: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth - spacing)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth - spacing)
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
