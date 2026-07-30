import AppKit
import Combine
import GizmateToolAgentCore
import SwiftUI

// MARK: - Reusable building blocks

/// The floating rounded card (dark menu material) that every section sits in.
/// No scroll of its own — sections decide what scrolls.
struct DetailCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                VisualEffectBackground(material: .menu)
                    .overlay(Color.black.opacity(0.26))
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(FlowTheme.hairline, lineWidth: 1)
            )
            .padding(EdgeInsets(top: 28, leading: 10, bottom: 16, trailing: 16))
    }
}

/// A scrolling "page": serif title + content, all scrolling together. Sections
/// that need a pinned header use `DetailCard` directly instead.
struct DetailContainer<Content: View>: View {
    let title: String
    var subtitle: String?
    /// Optional control pinned to the header's top-right (e.g. an Add button).
    var accessory: AnyView?
    /// Optional control pinned below the header, above the scroll area (e.g. a
    /// tab bar) — stays put while the content scrolls.
    var pinned: AnyView? = nil
    @ViewBuilder var content: () -> Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = nil
        self.content = content
    }

    init<Accessory: View>(
        _ title: String,
        subtitle: String? = nil,
        accessory: Accessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = AnyView(accessory)
        self.content = content
    }

    init<Pinned: View>(
        _ title: String,
        subtitle: String? = nil,
        pinned: Pinned,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = nil
        self.pinned = AnyView(pinned)
        self.content = content
    }

    /// Tabbed section whose header button belongs to the selected tab — pass
    /// `nil` for tabs that have no button of their own.
    init<Pinned: View>(
        _ title: String,
        subtitle: String? = nil,
        pinned: Pinned,
        accessory: AnyView?,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
        self.pinned = AnyView(pinned)
        self.content = content
    }

    var body: some View {
        DetailCard {
            VStack(alignment: .leading, spacing: 0) {
                // Pinned header — only the content below scrolls.
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(FlowTheme.serif(30))
                            .foregroundStyle(FlowTheme.ink)
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 14))
                                .foregroundStyle(FlowTheme.inkSecondary)
                        }
                    }
                    if let accessory {
                        Spacer(minLength: 12)
                        accessory.padding(.top, 6)
                    }
                }
                .padding(.horizontal, 38)
                .padding(.top, 38)
                .padding(.bottom, 20)

                if let pinned {
                    pinned
                        .padding(.horizontal, 38)
                        .padding(.bottom, 16)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        content()
                    }
                    .padding(.horizontal, 38)
                    .padding(.bottom, 38)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ScrollerConfigurator())
                }
            }
        }
    }
}

/// A bordered sub-panel inside a page.
struct SubCard<Content: View>: View {
    var padding: CGFloat = 20
    var fillHeight: Bool = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(FlowTheme.subtleFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(FlowTheme.hairline, lineWidth: 1)
            )
    }
}

/// The dark promo strip Flow shows at the top of each page.
struct PageBanner: View {
    let title: String
    let message: String
    var symbol: String = "sparkles"

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(FlowTheme.serif(22))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [FlowTheme.accent.opacity(0.32), FlowTheme.accent.opacity(0.12)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
        )
    }
}

/// Custom Flow-style segmented control (capsule pills).
struct PillPicker<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .white : FlowTheme.inkSecondary)
                        // Pills never wrap — "Floating bar" stays on one line
                        // even at the window's minimum width.
                        .fixedSize()
                        .padding(.vertical, 6)
                        .padding(.horizontal, 13)
                        .frame(minWidth: 78)
                        .background(
                            // The selected pill is a sheet lifted off the track,
                            // not a painted slab: a thin veil, a lit top edge and
                            // a short shadow. That reads as depth while leaving
                            // the label at full white-on-dark contrast.
                            Capsule()
                                .fill(isSelected ? FlowTheme.raised : Color.clear)
                                .overlay(
                                    Capsule().strokeBorder(
                                        isSelected ? FlowTheme.edge : Color.clear,
                                        lineWidth: 1
                                    )
                                )
                                .shadow(
                                    color: .black.opacity(isSelected ? 0.28 : 0),
                                    radius: 3,
                                    y: 1
                                )
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(FlowTheme.recess))
    }
}

struct StatTile: View {
    let value: String
    let label: String
    var accent: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(FlowTheme.serif(28, weight: .medium))
                .foregroundStyle(accent ? FlowTheme.accent : FlowTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(FlowTheme.inkSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(FlowTheme.subtleFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FlowTheme.hairline, lineWidth: 1)
        )
    }
}

/// A label + trailing control row.
struct SettingRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(FlowTheme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A GitHub-style activity calendar that fills the available width: weekday
/// labels down the left, square cells sized to the card, and a Less–More legend.
struct ActivityHeatmap: View {
    let weeks: [[UsageStatsDayBucket]]

    private let spacing: CGFloat = 5
    private let labelWidth: CGFloat = 22
    @State private var availableWidth: CGFloat = 0

    private var maxWords: Int { max(1, weeks.flatMap { $0 }.map(\.wordCount).max() ?? 1) }
    private var columns: Int { max(weeks.count, 1) }
    private var cell: CGFloat {
        guard availableWidth > 0 else { return 18 }
        let usable = availableWidth - labelWidth - spacing * CGFloat(columns)
        return max(14, min(36, usable / CGFloat(columns)))
    }
    private var gridHeight: CGFloat { cell * 7 + spacing * 6 }
    private var weekdayLabels: [String] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return ["S", "M", "T", "W", "T", "F", "S"] }
        let first = calendar.firstWeekday - 1
        return (0..<7).map { symbols[(first + $0) % 7] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                HStack(alignment: .top, spacing: spacing) {
                    VStack(spacing: spacing) {
                        ForEach(0..<7, id: \.self) { row in
                            Text(weekdayLabels[row])
                                .font(.system(size: 9))
                                .foregroundStyle(FlowTheme.inkTertiary)
                                .frame(width: labelWidth, height: cell, alignment: .leading)
                        }
                    }
                    HStack(spacing: spacing) {
                        ForEach(weeks.indices, id: \.self) { column in
                            VStack(spacing: spacing) {
                                ForEach(weeks[column]) { bucket in
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(fill(for: bucket))
                                        .frame(width: cell, height: cell)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                .stroke(bucket.isToday ? FlowTheme.accent : .clear, lineWidth: 1.5)
                                        )
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .onAppear { availableWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, newValue in availableWidth = newValue }
            }
            .frame(height: gridHeight)

            HStack(spacing: 5) {
                Text("Less").font(.system(size: 10)).foregroundStyle(FlowTheme.inkTertiary)
                ForEach(Array([0.12, 0.35, 0.58, 0.8, 1.0].enumerated()), id: \.offset) { _, value in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(FlowTheme.accent.opacity(value))
                        .frame(width: 11, height: 11)
                }
                Text("More").font(.system(size: 10)).foregroundStyle(FlowTheme.inkTertiary)
            }
        }
    }

    private func fill(for bucket: UsageStatsDayBucket) -> Color {
        guard bucket.wordCount > 0 else { return Color.white.opacity(0.06) }
        let intensity = min(1.0, 0.2 + 0.8 * Double(bucket.wordCount) / Double(maxWords))
        return FlowTheme.accent.opacity(intensity)
    }
}
