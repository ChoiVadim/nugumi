import SwiftUI

struct InsightsSection: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge
    var body: some View { InsightsContent(usageStats: bridge.usageStats) }
}

private struct InsightsContent: View {
    @ObservedObject var usageStats: UsageStatsStore
    private var snapshot: UsageStatsSnapshot { usageStats.snapshot }

    var body: some View {
        DetailCard {
            // Center/fill the cards when they fit; scroll when the window is too
            // short (e.g. at 600pt) instead of clipping or shoving the window off-screen.
            GeometryReader { geo in
                // Donuts scale with the window so the cards stay filled on large screens.
                let donutSize = min(160, max(104, geo.size.width * 0.10))
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Insights")
                                .font(FlowTheme.serif(30))
                                .foregroundStyle(FlowTheme.ink)
                            Text("Your work, by the numbers.")
                                .font(.system(size: 14))
                                .foregroundStyle(FlowTheme.inkSecondary)
                        }

                        HStack(spacing: 12) {
                            StatTile(value: "\(snapshot.currentMonthWords)", label: "words this month", accent: true)
                            StatTile(value: "\(snapshot.longestStreak)", label: "longest streak")
                            StatTile(value: "\(snapshot.activeDays)", label: "active days")
                            StatTile(value: "\(snapshot.averageWordsPerActiveDay)", label: "avg / day")
                        }

                        // Two equal-height cards: breakdowns (left) and the activity calendar (right).
                        HStack(alignment: .top, spacing: 12) {
                            SubCard(padding: 18, fillHeight: true) {
                                VStack(alignment: .leading, spacing: 18) {
                                    Spacer(minLength: 0)
                                    breakdownColumn(
                                        title: "Workflow mix",
                                        rows: snapshot.modeBreakdown
                                            .filter { $0.count > 0 }
                                            .map { ($0.kind.title, "\($0.count)", $0.fraction) },
                                        donutSize: donutSize
                                    )
                                    breakdownColumn(
                                        title: "Languages",
                                        rows: snapshot.languageBreakdown
                                            .filter { $0.count > 0 }
                                            .prefix(5)
                                            .map { ($0.displayName.isEmpty ? "Unknown" : $0.displayName, "\($0.count)", $0.fraction) },
                                        donutSize: donutSize
                                    )
                                    Spacer(minLength: 0)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                            SubCard(padding: 18, fillHeight: true) {
                                VStack(alignment: .leading, spacing: 14) {
                                    Spacer(minLength: 0)
                                    HStack(alignment: .firstTextBaseline) {
                                        Text("Activity")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(FlowTheme.ink)
                                        Spacer()
                                        Text("\(snapshot.currentStreak)-day streak")
                                            .font(.system(size: 11))
                                            .foregroundStyle(FlowTheme.inkTertiary)
                                    }
                                    ActivityHeatmap(weeks: snapshot.heatmapWeeks)
                                    if let busiest = snapshot.busiestDay, busiest.wordCount > 0 {
                                        Text("Busiest day · \(busiest.date.formatted(.dateTime.month().day())) - \(busiest.wordCount) words")
                                            .font(.system(size: 11))
                                            .foregroundStyle(FlowTheme.inkTertiary)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .padding(38)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                    .background(ScrollerConfigurator())
                }
            }
        }
    }

    @ViewBuilder
    private func breakdownColumn(title: String, rows: [(String, String, Double)], donutSize: CGFloat) -> some View {
        let rows = rows.sorted { $0.2 > $1.2 }
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FlowTheme.ink)
            if rows.isEmpty {
                Text("Nothing yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.inkSecondary)
            } else {
                HStack(alignment: .center, spacing: 18) {
                    DonutChart(
                        fractions: rows.map(\.2),
                        centerText: "\(Int((rows[0].2 * 100).rounded()))%",
                        size: donutSize
                    )
                    VStack(spacing: 10) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            HStack(spacing: 9) {
                                Circle()
                                    .fill(BreakdownPalette.color(index))
                                    .frame(width: 7, height: 7)
                                Text(row.0)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(FlowTheme.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text("\(Int((row.2 * 100).rounded()))%")
                                    .font(.system(size: 11))
                                    .foregroundStyle(FlowTheme.inkTertiary)
                                Text(row.1)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(FlowTheme.inkSecondary)
                                    .frame(minWidth: 34, alignment: .trailing)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Slice colors for the breakdown donuts. With a monochrome palette the only
/// thing separating slices is lightness, so the ramp has to descend strictly:
/// the leading share takes full white and every slice behind it steps down.
/// Using `FlowTheme.accent` for the leader would put it *below* the first
/// shade and quietly invert the ranking the chart is meant to show.
private enum BreakdownPalette {
    static func color(_ index: Int) -> Color {
        index == 0 ? Color.white : shade(index - 1)
    }

    static func shade(_ index: Int) -> Color {
        let opacities: [Double] = [0.62, 0.42, 0.28, 0.18, 0.10]
        return Color.white.opacity(opacities[min(index, opacities.count - 1)])
    }
}

/// A hand-rolled donut chart for the breakdown columns. Each slice is a trimmed
/// circle stroked thickly into a ring segment; the leading slice is the
/// brightest (via `BreakdownPalette`). The center holds the dominant share. Tiny angular gaps
/// separate slices without an overlay.
private struct DonutChart: View {
    let fractions: [Double]
    let centerText: String
    var size: CGFloat = 104

    private var thickness: CGFloat { size * 0.19 }
    private var ringSide: CGFloat { size - thickness }

    /// Cumulative (start, end) in turns per slice, with a small leading gap so
    /// adjacent slices don't touch. The gap is clamped so it never inverts a
    /// thin slice.
    private var slices: [(start: CGFloat, end: CGFloat, index: Int)] {
        let gap: CGFloat = fractions.count > 1 ? 0.006 : 0
        var result: [(CGFloat, CGFloat, Int)] = []
        var cursor: CGFloat = 0
        for (index, fraction) in fractions.enumerated() {
            let end = cursor + CGFloat(fraction)
            result.append((min(cursor + gap, end), end, index))
            cursor = end
        }
        return result
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.06), lineWidth: thickness)
                .frame(width: ringSide, height: ringSide)

            ForEach(slices.indices, id: \.self) { i in
                Circle()
                    .trim(from: slices[i].start, to: slices[i].end)
                    .stroke(
                        BreakdownPalette.color(slices[i].index),
                        style: StrokeStyle(lineWidth: thickness, lineCap: .butt)
                    )
                    .frame(width: ringSide, height: ringSide)
                    .rotationEffect(.degrees(-90))
            }

            Text(centerText)
                .font(.system(size: size * 0.23, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(FlowTheme.ink)
        }
        .frame(width: size, height: size)
    }
}
