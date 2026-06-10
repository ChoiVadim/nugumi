import AppKit
import SwiftUI

// MARK: - Router

struct DetailRouter: View {
    let section: MainWindowSection

    var body: some View {
        switch section {
        case .home: HomeSection()
        case .insights: InsightsSection()
        case .dictionary: DictionarySection()
        case .snippets: SnippetsSection()
        case .style: StyleSection()
        case .languages: LanguagesSection()
        case .aiEngine: AIEngineSection()
        case .shortcuts: ShortcutsSection()
        case .settings: BehaviorSection()
        case .help: HelpSection()
        }
    }
}

// MARK: - Shared small pieces

private struct MenuFieldLabel: View {
    let text: String
    var body: some View {
        // No chevron here — the Menu's own native disclosure indicator sits to
        // the right. Drawing our own too produced a duplicate arrow.
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(FlowTheme.ink)
            .lineLimit(1)
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
    }
}

private struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text.isEmpty ? "—" : text)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(FlowTheme.ink)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .frame(minWidth: 56)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
    }
}

private struct SecondaryButton: View {
    let title: String
    var destructive: Bool = false
    /// Set to align a column of buttons (e.g. Help rows) to one width.
    var minWidth: CGFloat?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(destructive ? Color(red: 1.0, green: 0.62, blue: 0.62) : Color.white)
                .padding(.vertical, 7)
                .padding(.horizontal, 14)
                .frame(minWidth: minWidth)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(destructive ? Color.red.opacity(0.18) : Color.white.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Home

struct HomeSection: View {
    @EnvironmentObject var bridge: NugumiSettingsBridge
    var body: some View {
        HomeContent(history: bridge.history, usageStats: bridge.usageStats)
    }
}

private struct HomeContent: View {
    @ObservedObject var history: TranslationHistoryStore
    @ObservedObject var usageStats: UsageStatsStore
    @State private var confirmClear = false

    private var snapshot: UsageStatsSnapshot { usageStats.snapshot }

    var body: some View {
        DetailCard {
            VStack(alignment: .leading, spacing: 0) {
                // Pinned header — only the list below scrolls.
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Welcome back")
                            .font(FlowTheme.serif(30))
                            .foregroundStyle(FlowTheme.ink)
                        Text("Your recent translations and chats with Nugumi.")
                            .font(.system(size: 14))
                            .foregroundStyle(FlowTheme.inkSecondary)
                    }
                    HStack(spacing: 12) {
                        StatTile(value: "\(snapshot.totalUses)", label: "uses", accent: true)
                        StatTile(value: "\(snapshot.totalSourceWords)", label: "words")
                        StatTile(value: "\(snapshot.currentStreak)", label: "day streak")
                    }
                    if !history.entries.isEmpty {
                        HStack {
                            Text("History")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(FlowTheme.ink)
                            Spacer()
                            Button { confirmClear = true } label: {
                                Text("Clear")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(FlowTheme.inkSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 38)
                .padding(.top, 38)
                .padding(.bottom, 14)

                if history.entries.isEmpty {
                    SubCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No history yet")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(FlowTheme.ink)
                            Text("Select text anywhere and translate, rewrite, reply, or ask Nugumi — it shows up here.")
                                .font(.system(size: 13))
                                .foregroundStyle(FlowTheme.inkSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 38)
                    Spacer(minLength: 0)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(groupedDays, id: \.day) { group in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(group.title)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(FlowTheme.inkTertiary)
                                        .textCase(.uppercase)
                                        .padding(.top, 4)
                                    ForEach(group.entries) { entry in
                                        HistoryRow(entry: entry) { history.delete(entry.id) }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 38)
                        .padding(.bottom, 32)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ScrollerConfigurator())
                    }
                }
            }
        }
        .confirmationDialog("Clear all history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var groupedDays: [(day: Date, title: String, entries: [TranslationHistoryEntry])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: history.entries) { calendar.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { day in
            (day, Self.dayTitle(day, calendar: calendar), (groups[day] ?? []).sorted { $0.date > $1.date })
        }
    }

    private static func dayTitle(_ day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.month(.wide).day().year())
    }
}

private struct HistoryRow: View {
    let entry: TranslationHistoryEntry
    let onDelete: () -> Void

    @State private var didCopy = false

    private var copyText: String {
        entry.resultText.isEmpty ? entry.sourceText : entry.resultText
    }

    var body: some View {
        SubCard {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(entry.kind.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FlowTheme.inkSecondary)
                    if let lang = entry.targetLanguageID {
                        Text(TranslationLanguage.language(id: lang).displayName)
                            .font(.system(size: 11))
                            .foregroundStyle(FlowTheme.inkTertiary)
                    }
                    Spacer()
                    Text(entry.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11))
                        .foregroundStyle(FlowTheme.inkTertiary)
                    Button {
                        copy(copyText)
                    } label: {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(didCopy ? FlowTheme.inkSecondary : FlowTheme.inkTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy to clipboard")
                    .disabled(copyText.isEmpty)
                }
                if !entry.sourceText.isEmpty {
                    Text(entry.sourceText)
                        .font(.system(size: 13))
                        .foregroundStyle(FlowTheme.inkSecondary)
                        .lineLimit(2)
                }
                if !entry.resultText.isEmpty {
                    Text(entry.resultText)
                        .font(.system(size: 14))
                        .foregroundStyle(FlowTheme.ink)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contextMenu {
            Button("Copy result") { copy(entry.resultText) }
            if !entry.sourceText.isEmpty {
                Button("Copy original") { copy(entry.sourceText) }
            }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) { didCopy = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeInOut(duration: 0.2)) { didCopy = false }
        }
    }
}

// MARK: - Insights

struct InsightsSection: View {
    @EnvironmentObject var bridge: NugumiSettingsBridge
    var body: some View { InsightsContent(usageStats: bridge.usageStats) }
}

private struct InsightsContent: View {
    @ObservedObject var usageStats: UsageStatsStore
    private var snapshot: UsageStatsSnapshot { usageStats.snapshot }

    var body: some View {
        DetailCard {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Insights")
                        .font(FlowTheme.serif(30))
                        .foregroundStyle(FlowTheme.ink)
                    Text("Your translating, by the numbers.")
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
                            breakdownColumn(
                                title: "Workflow mix",
                                rows: snapshot.modeBreakdown
                                    .filter { $0.count > 0 }
                                    .map { ($0.kind.title, "\($0.count)", $0.fraction) }
                            )
                            Divider().background(FlowTheme.hairline)
                            breakdownColumn(
                                title: "Languages",
                                rows: snapshot.languageBreakdown
                                    .filter { $0.count > 0 }
                                    .prefix(5)
                                    .map { ($0.displayName.isEmpty ? "Unknown" : $0.displayName, "\($0.count)", $0.fraction) }
                            )
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    SubCard(padding: 18, fillHeight: true) {
                        VStack(alignment: .leading, spacing: 14) {
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
                                Text("Busiest day · \(busiest.date.formatted(.dateTime.month().day())) — \(busiest.wordCount) words")
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
        }
    }

    @ViewBuilder
    private func breakdownColumn(title: String, rows: [(String, String, Double)]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FlowTheme.ink)
            if rows.isEmpty {
                Text("Nothing yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.inkSecondary)
            } else {
                DistributionBar(fractions: rows.map(\.2))
                VStack(spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 9) {
                            Circle()
                                .fill(BreakdownPalette.shade(index))
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Quiet monochrome shades for distribution segments — the accent green stays
/// reserved for the activity heatmap next door.
private enum BreakdownPalette {
    static func shade(_ index: Int) -> Color {
        let opacities: [Double] = [0.85, 0.55, 0.34, 0.20, 0.12]
        return Color.white.opacity(opacities[min(index, opacities.count - 1)])
    }
}

/// One horizontal bar split proportionally into shaded segments.
private struct DistributionBar: View {
    let fractions: [Double]

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 2
            let available = geo.size.width - CGFloat(max(0, fractions.count - 1)) * gap
            HStack(spacing: gap) {
                ForEach(fractions.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(BreakdownPalette.shade(index))
                        .frame(width: max(3, available * fractions[index]))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 10)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .clipShape(Capsule())
    }
}

// MARK: - Style

struct StyleSection: View {
    @EnvironmentObject var bridge: NugumiSettingsBridge

    var body: some View {
        DetailContainer("Style", subtitle: "How Nugumi writes when it rewrites your messages and replies.") {
            PageBanner(
                title: "Your voice, per place",
                message: "Nugumi picks a category automatically from the app you're in. Set the register for each below.",
                symbol: "textformat.alt"
            )

            ForEach(AppCategory.allCases, id: \.self) { category in
                StyleCard(category: category, selection: bridge.writingStyleBinding(category))
            }

            SubCard {
                VStack(alignment: .leading, spacing: 14) {
                    SettingRow("Auto Cleanup",
                               subtitle: "How much Nugumi tidies the text it writes.") {
                        PillPicker(
                            options: CleanupLevel.allCases,
                            selection: bridge.binding(\.cleanupLevel) { .setCleanupLevel($0) },
                            label: { $0.displayName }
                        )
                    }
                    Divider().background(FlowTheme.hairline)
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 12))
                            .foregroundStyle(FlowTheme.inkTertiary)
                        Text(bridge.settings.cleanupLevel.settingsDescription)
                            .font(.system(size: 12.5))
                            .foregroundStyle(FlowTheme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .animation(.easeInOut(duration: 0.15), value: bridge.settings.cleanupLevel)
                }
            }
        }
    }
}

/// Friendly settings copy for cleanup levels — `promptDescription` is raw
/// prompt text and reads poorly in the UI.
private extension CleanupLevel {
    var settingsDescription: String {
        switch self {
        case .none: return "Keeps your phrasing exactly as written."
        case .light: return "Fixes typos and obvious grammar slips, nothing more."
        case .medium: return "Smooths awkward phrasing for clarity and flow."
        case .high: return "Polishes thoroughly — tight, clear sentences with no filler."
        }
    }
}

private struct StyleCard: View {
    @EnvironmentObject var bridge: NugumiSettingsBridge
    let category: AppCategory
    @Binding var selection: WritingStyle

    var body: some View {
        SubCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(category.displayName)
                        .font(FlowTheme.serif(19))
                        .foregroundStyle(FlowTheme.ink)
                    Spacer()
                    PillPicker(options: WritingStyle.allCases, selection: $selection, label: { $0.displayName })
                }

                Divider().background(FlowTheme.hairline)

                // Left: how messages read in this style. Right: where it applies.
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        fieldLabel("Preview")
                        VStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("English")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(FlowTheme.inkTertiary)
                                    .padding(.leading, 6)
                                ChatBubble(text: sample(for: selection))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            VStack(alignment: .leading, spacing: 5) {
                                Text("Korean")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(FlowTheme.inkTertiary)
                                    .padding(.leading, 6)
                                ChatBubble(text: koreanSample(for: selection))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Rectangle()
                        .fill(FlowTheme.hairline)
                        .frame(width: 1)

                    if category == .other {
                        // "Other" is the catch-all every unmatched app/site falls
                        // into, so there's nothing to assign — explain instead.
                        VStack(alignment: .leading, spacing: 10) {
                            fieldLabel("Scope")
                            Text("Apps and sites that don't match the categories above land here automatically — nothing to assign.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(FlowTheme.inkTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            VStack(alignment: .leading, spacing: 10) {
                                fieldLabel("Apps")
                                AppIconStrip(category: category, apps: bridge.settings.apps(for: category))
                            }
                            URLRuleEditor(category: category, patterns: bridge.settings.urlRules(for: category))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(FlowTheme.inkSecondary)
    }

    private func sample(for style: WritingStyle) -> String {
        switch style {
        case .formal: return "Hello, are you available for lunch tomorrow? Twelve o'clock would suit me well."
        case .polite: return "Hi! Are you free for lunch tomorrow? Let's do 12 if that works for you."
        case .casual: return "hey are you free for lunch tmrw? let's do 12 if that works"
        }
    }

    private func koreanSample(for style: WritingStyle) -> String {
        switch style {
        case .formal: return "안녕하세요, 혹시 내일 점심 식사 가능하신가요? 12시 정도면 괜찮을 것 같습니다."
        case .polite: return "안녕하세요! 내일 점심 같이 하실래요? 괜찮으시면 12시에 봐요."
        case .casual: return "야 내일 점심 시간 돼? 괜찮으면 12시에 보자"
        }
    }
}

private struct ChatBubble: View {
    let text: String
    /// Accent-tinted bubble for the "Nugumi's rewrite" side of the preview.
    var accent: Bool = false
    /// Right-aligned (outgoing) bubble — the "tail" corner flattens bottom-right.
    var trailing: Bool = false

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 15,
            bottomLeadingRadius: trailing ? 15 : 4,
            bottomTrailingRadius: trailing ? 4 : 15,
            topTrailingRadius: 15,
            style: .continuous
        )
    }

    var body: some View {
        Text(text)
            .font(.system(size: 13.5))
            .foregroundStyle(FlowTheme.ink)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .frame(maxWidth: 320, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(shape.fill(accent ? FlowTheme.accent.opacity(0.30) : Color.white.opacity(0.09)))
            .overlay(shape.strokeBorder(accent ? FlowTheme.accent.opacity(0.35) : FlowTheme.hairline, lineWidth: 1))
    }
}

// MARK: - Per-category app icon strip

/// Horizontal strip of circular app icons for a Style category, with a trailing
/// "+" to assign any installed app. Every icon can be removed (built-ins are
/// suppressed, user-added ones deleted) via its ✕ overlay.
private struct AppIconStrip: View {
    @EnvironmentObject var bridge: NugumiSettingsBridge
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

/// "Websites" sub-section: lets the user route a browser tab to this category by
/// URL substring (e.g. `web.whatsapp.com`). Matching happens at rewrite time when
/// a scriptable browser is frontmost.
private struct URLRuleEditor: View {
    @EnvironmentObject var bridge: NugumiSettingsBridge
    let category: AppCategory
    let patterns: [String]
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Websites")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FlowTheme.inkSecondary)

            if !patterns.isEmpty {
                FlowWrap(spacing: 6) {
                    ForEach(patterns, id: \.self) { pattern in
                        HStack(spacing: 5) {
                            Text(pattern)
                                .font(.system(size: 12))
                                .foregroundStyle(FlowTheme.ink)
                            Button {
                                bridge.perform(.removeURLRule(pattern, category))
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(FlowTheme.inkSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 9)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                        .overlay(Capsule().strokeBorder(FlowTheme.hairline, lineWidth: 1))
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("e.g. web.whatsapp.com", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(FlowTheme.ink)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 11)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
                    .frame(maxWidth: 260)
                    .onSubmit(add)
                SecondaryButton(title: "Add") { add() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func add() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        bridge.perform(.addURLRule(trimmed, category))
        draft = ""
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

// MARK: - Languages

struct LanguagesSection: View {
    @EnvironmentObject var bridge: NugumiSettingsBridge

    var body: some View {
        DetailContainer("Languages", subtitle: "What Nugumi translates into.") {
            SubCard {
                VStack(spacing: 18) {
                    SettingRow("Reading language",
                               subtitle: "Translating selected text or a screen area renders into this language.") {
                        LanguageMenu(current: bridge.settings.targetLanguage) {
                            bridge.perform(.setTargetLanguage($0))
                        }
                    }
                    Divider().background(FlowTheme.hairline)
                    SettingRow("Writing language",
                               subtitle: "Rewriting your own draft produces this language.") {
                        LanguageMenu(current: bridge.settings.draftTargetLanguage) {
                            bridge.perform(.setDraftTargetLanguage($0))
                        }
                    }
                }
            }

            SubCard {
                SettingRow("Quick switch",
                           subtitle: "Press \(bridge.settings.shortcut(for: .toggleWritingLanguage).displayString) anywhere to flip the writing language between these two.") {
                    HStack(spacing: 10) {
                        LanguageMenu(current: bridge.settings.writingToggleLanguageA) {
                            bridge.perform(.setWritingToggleLanguageA($0))
                        }
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(FlowTheme.inkTertiary)
                        LanguageMenu(current: bridge.settings.writingToggleLanguageB) {
                            bridge.perform(.setWritingToggleLanguageB($0))
                        }
                    }
                }
            }
        }
    }
}

private struct LanguageMenu: View {
    let current: TranslationLanguage
    let onSelect: (TranslationLanguage) -> Void

    var body: some View {
        Menu {
            ForEach(TranslationLanguage.all, id: \.id) { language in
                Button {
                    onSelect(language)
                } label: {
                    if language.id == current.id {
                        Label(language.displayName, systemImage: "checkmark")
                    } else {
                        Text(language.displayName)
                    }
                }
            }
        } label: {
            MenuFieldLabel(text: current.displayName)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - AI Engine

struct AIEngineSection: View {
    @EnvironmentObject var bridge: NugumiSettingsBridge

    var body: some View {
        DetailContainer("AI Engine", subtitle: "Which model does the thinking — and how hard.") {
            FlowTabBar(tabs: ["Models", "Providers"], selection: $bridge.aiEngineTab)

            if bridge.aiEngineTab == 0 {
                ModelScopeCard(scope: .textActions,
                               title: "Everyday text",
                               subtitle: "Translate, rewrite, and smart replies.")
                ModelScopeCard(scope: .askNugumi,
                               title: "Ask Nugumi",
                               subtitle: "Screenshot questions. Vision-capable models only.")
            } else {
                OllamaSetupCard()

                ProviderGroupCard(
                    title: "Subscriptions",
                    subtitle: "Use a plan you already pay for — sign in with your account.",
                    providers: CloudProvider.allCases.filter { $0.usesOAuth }
                )

                ProviderGroupCard(
                    title: "API keys",
                    subtitle: "Pay-as-you-go with your own keys. Stored locally on this Mac.",
                    providers: CloudProvider.allCases.filter { !$0.usesOAuth }
                )
            }
        }
    }
}

/// Flow-style underlined text tabs: quiet labels on a hairline baseline, the
/// active one bright with a 2pt indicator.
private struct FlowTabBar: View {
    let tabs: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 24) {
            ForEach(tabs.indices, id: \.self) { index in
                Button {
                    selection = index
                } label: {
                    VStack(spacing: 8) {
                        Text(tabs[index])
                            .font(.system(size: 13.5, weight: selection == index ? .semibold : .regular))
                            .foregroundStyle(selection == index ? FlowTheme.ink : FlowTheme.inkSecondary)
                        Rectangle()
                            .fill(selection == index ? Color.white : Color.clear)
                            .frame(height: 2)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FlowTheme.hairline)
                .frame(height: 1)
        }
    }
}

private struct ProviderGroupCard: View {
    let title: String
    let subtitle: String
    let providers: [CloudProvider]

    var body: some View {
        SubCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FlowTheme.ink)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.inkSecondary)
                ForEach(providers, id: \.self) { provider in
                    ProviderRow(provider: provider)
                    if provider != providers.last {
                        Divider().background(FlowTheme.hairline)
                    }
                }
            }
        }
    }
}

private struct ModelScopeCard: View {
    @EnvironmentObject var bridge: NugumiSettingsBridge
    let scope: ModelUseScope
    let title: String
    let subtitle: String

    private var currentID: String { bridge.settings.modelID(for: scope) }

    private var modelSelection: Binding<String> {
        Binding(
            get: { currentID },
            set: { bridge.perform(.chooseModel($0, scope)) }
        )
    }

    var body: some View {
        SubCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(FlowTheme.ink)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(FlowTheme.inkSecondary)
                }
                SettingRow("Model") {
                    Menu {
                        modelSection("Ollama (local)", LLMModel.ollamaModels.filter { !$0.isCloud })
                        modelSection("Ollama (cloud)", LLMModel.ollamaModels.filter(\.isCloud))
                        modelSection(CloudProvider.openAI.displayName, LLMModel.cloudModels(for: .openAI))
                        modelSection(CloudProvider.anthropic.displayName, LLMModel.cloudModels(for: .anthropic))
                        modelSection(CloudProvider.gemini.displayName, LLMModel.cloudModels(for: .gemini))
                        modelSection(CloudProvider.openAICodex.displayName, LLMModel.codexModels)
                    } label: {
                        MenuFieldLabel(text: LLMModel.option(id: currentID).shortName)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                SettingRow("Thinking") {
                    PillPicker(options: ThinkingLevel.allCases,
                               selection: bridge.thinkingBinding(scope),
                               label: { $0.menuTitle })
                }
            }
        }
    }

    /// One labeled group of model choices. An inline Picker (not hand-rolled
    /// Buttons) so every section reserves the same checkmark gutter — otherwise
    /// only the section containing the selected model indents, which reads as a
    /// stray leading space. Filtered through the scope (Ask Nugumi shows
    /// vision-capable only) and hidden entirely when empty.
    @ViewBuilder
    private func modelSection(_ title: String, _ source: [LLMModel]) -> some View {
        let models = scope.availableModels(from: source)
        if !models.isEmpty {
            Picker(title, selection: modelSelection) {
                ForEach(models, id: \.id) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
            .pickerStyle(.inline)
        }
    }
}

private struct ProviderRow: View {
    @EnvironmentObject var bridge: NugumiSettingsBridge
    let provider: CloudProvider
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        let signedIn = bridge.hasCredentials(provider)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                // Same status glyphs as the Ollama setup steps below, so both
                // cards read in one visual language.
                Group {
                    if signedIn {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(FlowTheme.accent)
                    } else {
                        Circle()
                            .strokeBorder(FlowTheme.inkTertiary, lineWidth: 1.5)
                            .frame(width: 13, height: 13)
                    }
                }
                .frame(width: 16)
                Text(provider.displayName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(FlowTheme.ink)
                Spacer()
                Text(signedIn ? "Connected" : "Not connected")
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.inkSecondary)
                if signedIn {
                    SecondaryButton(title: testing ? "Testing…" : "Test", minWidth: 76) { runTest() }
                }
                SecondaryButton(title: buttonTitle(signedIn: signedIn), minWidth: 96) {
                    bridge.perform(.signInCloud(provider))
                }
            }
            if let testResult {
                Text(testResult)
                    .font(.system(size: 11))
                    .foregroundStyle(FlowTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func runTest() {
        guard !testing else { return }
        testing = true
        testResult = nil
        Task { @MainActor in
            let result = await bridge.testCloud(provider)
            testing = false
            switch result {
            case .success(let preview):
                testResult = "✓ Working — “\(preview)”"
            case .failure(let message):
                testResult = "✕ \(message)"
            }
        }
    }

    private func buttonTitle(signedIn: Bool) -> String {
        if provider.usesOAuth { return signedIn ? "Re-sign in" : "Sign in" }
        return signedIn ? "Update key" : "Add key"
    }
}

// MARK: - Ollama local setup (ported from the old "Nugumi Setup" window)

private struct OllamaSetupCard: View {
    @EnvironmentObject var bridge: NugumiSettingsBridge

    private var state: BootstrapState { bridge.bootstrap }

    var body: some View {
        SubCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Local models (Ollama)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(FlowTheme.ink)
                    Text("Runs entirely on your Mac — private and free, but downloads about 12 GB. Do these steps in order.")
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SetupStepRow(
                    title: "1.  Install Ollama",
                    status: state.ollamaInstalled,
                    primary: StepButton(title: "Open download page") { bridge.perform(.openOllamaInstall) },
                    secondary: StepButton(title: "Re-check") { bridge.perform(.refreshBootstrap) }
                )
                Divider().background(FlowTheme.hairline)
                SetupStepRow(
                    title: "2.  Start Ollama",
                    status: state.serverRunning,
                    primary: StepButton(title: "Open Ollama") { bridge.perform(.launchOllama) }
                )
                Divider().background(FlowTheme.hairline)
                SetupStepRow(
                    title: "3.  Sign in to Ollama (free)",
                    status: state.ollamaSignedIn,
                    okMessage: bridge.requiresOllamaAccount
                        ? "Signed in to your free Ollama account."
                        : "Not needed if you only use Offline.",
                    primary: StepButton(title: "Open Ollama") { bridge.perform(.openOllamaSignIn) },
                    secondary: StepButton(title: "Re-check") { bridge.perform(.refreshBootstrap) }
                )
            }
        }
    }
}

private struct StepButton {
    let title: String
    let action: () -> Void
}

/// Status dot/spinner/checkmark mirroring the AppKit StepRow visuals, driven by
/// `BootstrapStepStatus`.
private struct SetupStatusGlyph: View {
    let status: BootstrapStepStatus
    var body: some View {
        switch status {
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(FlowTheme.accent)
        case .working, .checking:
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
        case .needsAction, .unknown:
            Circle()
                .strokeBorder(FlowTheme.inkTertiary, lineWidth: 1.5)
                .frame(width: 13, height: 13)
        }
    }
}

private func setupStatusMessage(_ status: BootstrapStepStatus, okMessage: String?) -> String? {
    switch status {
    case .ok: return okMessage
    case .needsAction(let m), .failed(let m), .working(let m): return m
    case .checking: return "Checking…"
    case .unknown: return nil
    }
}

private struct SetupStepRow: View {
    let title: String
    let status: BootstrapStepStatus
    var okMessage: String?
    let primary: StepButton
    var secondary: StepButton?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SetupStatusGlyph(status: status)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(FlowTheme.ink)
                if let message = setupStatusMessage(status, okMessage: okMessage) {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if !status.isTerminalOK {
                if let secondary {
                    SecondaryButton(title: secondary.title, action: secondary.action)
                }
                SecondaryButton(title: primary.title, action: primary.action)
            }
        }
    }
}

// MARK: - Shortcuts

struct ShortcutsSection: View {
    @EnvironmentObject var bridge: NugumiSettingsBridge

    var body: some View {
        DetailContainer(
            "Shortcuts",
            subtitle: "Global hotkeys that work from any app.",
            accessory: SecondaryButton(title: "Reset to defaults") {
                bridge.perform(.resetShortcuts)
            }
        ) {
            SubCard {
                VStack(spacing: 0) {
                    ForEach(Array(GlobalShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                        if index > 0 { Divider().background(FlowTheme.hairline) }
                        SettingRow(action.menuTitle) {
                            HStack(spacing: 12) {
                                KeyCap(text: bridge.settings.shortcut(for: action).displayString)
                                SecondaryButton(title: "Change") {
                                    bridge.perform(.recordShortcut(action))
                                }
                            }
                        }
                        .padding(.vertical, 10)
                    }
                }
            }
        }
    }
}

// MARK: - Behavior (Settings)

struct BehaviorSection: View {
    @EnvironmentObject var bridge: NugumiSettingsBridge

    var body: some View {
        DetailContainer("Settings", subtitle: "How Nugumi shows up while you work.") {
            SubCard {
                VStack(spacing: 18) {
                    SettingRow("Main mode",
                               subtitle: "What the floating button and pet do on a single click.") {
                        PillPicker(options: [.translate, .smartReply],
                                   selection: bridge.binding(\.floatingDefaultMode) { .setFloatingDefaultMode($0) },
                                   label: { $0 == .translate ? "Translate" : "Reply" })
                    }
                    Divider().background(FlowTheme.hairline)
                    SettingRow("On selection",
                               subtitle: "What appears when you select text.") {
                        PillPicker(options: SelectionDisplayMode.allCases,
                                   selection: bridge.binding(\.selectionDisplayMode) { .setSelectionDisplayMode($0) },
                                   label: { $0.menuTitle })
                    }
                    Divider().background(FlowTheme.hairline)
                    SettingRow("Replace action",
                               subtitle: "How a rewrite lands back in your text field.") {
                        PillPicker(options: ReplacementMode.allCases,
                                   selection: bridge.binding(\.replacementMode) { .setReplacementMode($0) },
                                   label: { $0 == .instantInsert ? "Instant" : "Preview" })
                    }
                }
            }

            SubCard {
                SettingRow("Invisibility mode",
                           subtitle: "Hide Nugumi's windows from screen recording and screenshots.") {
                    Toggle("", isOn: Binding(
                        get: { bridge.settings.invisibilityEnabled },
                        set: { _ in bridge.perform(.toggleInvisibility) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(FlowTheme.accent)
                }
            }
        }
    }
}

// MARK: - Snippets & Dictionary

struct SnippetsSection: View {
    @EnvironmentObject var bridge: NugumiSettingsBridge
    var body: some View { SnippetsListContent(store: bridge.snippets, kind: .snippet) }
}

struct DictionarySection: View {
    @EnvironmentObject var bridge: NugumiSettingsBridge
    var body: some View { SnippetsListContent(store: bridge.snippets, kind: .dictionaryTerm) }
}

private struct SnippetsListContent: View {
    @ObservedObject var store: SnippetsStore
    let kind: SnippetKind

    @State private var isAddingNew = false
    @State private var editingID: UUID?

    /// Newest first, so a just-saved entry lands where the add editor was.
    private var items: [Snippet] {
        store.snippets
            .filter { $0.kind == kind }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var title: String { kind == .snippet ? "Snippets" : "Dictionary" }
    private var subtitle: String {
        kind == .snippet
            ? "Short phrases Nugumi expands before rewriting."
            : "Words and names Nugumi keeps exactly as written."
    }

    var body: some View {
        DetailContainer(
            title,
            subtitle: subtitle,
            accessory: SecondaryButton(title: kind == .snippet ? "Add snippet" : "Add word") {
                editingID = nil
                isAddingNew = true
            }
        ) {
            if items.isEmpty && !isAddingNew {
                SubCard {
                    Text(kind == .snippet
                         ? "No snippets yet. Add one like “omw” → “on my way”."
                         : "No saved words yet. Add names or terms Nugumi should never translate.")
                        .font(.system(size: 13))
                        .foregroundStyle(FlowTheme.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 0) {
                    if isAddingNew {
                        SnippetEditorRow(
                            kind: kind,
                            initialTrigger: "",
                            initialValue: "",
                            onSave: { trigger, value in
                                let created = store.add(kind: kind)
                                store.update(created.id, trigger: trigger, value: value)
                                isAddingNew = false
                            },
                            onCancel: { isAddingNew = false }
                        )
                        .id("snippet-editor-new")
                        if !items.isEmpty { Divider().background(FlowTheme.hairline) }
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().background(FlowTheme.hairline) }
                        if editingID == item.id {
                            SnippetEditorRow(
                                kind: kind,
                                initialTrigger: item.trigger,
                                initialValue: item.value,
                                onSave: { trigger, value in
                                    store.update(item.id, trigger: trigger, value: value)
                                    editingID = nil
                                },
                                onCancel: { editingID = nil }
                            )
                            .id("snippet-editor-\(item.id)")
                        } else {
                            SnippetDisplayRow(
                                snippet: item,
                                onEdit: {
                                    isAddingNew = false
                                    editingID = item.id
                                },
                                onDelete: { store.delete(item.id) }
                            )
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(FlowTheme.subtleFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(FlowTheme.hairline, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
}

/// Flow-style display row: plain text, hover highlights the row and reveals
/// edit/delete actions. Double-click also opens the editor.
private struct SnippetDisplayRow: View {
    let snippet: Snippet
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text(snippet.trigger.isEmpty ? "—" : snippet.trigger)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FlowTheme.ink)
                .lineLimit(1)
            if snippet.kind == .snippet {
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FlowTheme.inkTertiary)
                Text(snippet.value)
                    .font(.system(size: 13))
                    .foregroundStyle(FlowTheme.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                RowIconButton(symbol: "pencil", action: onEdit)
                RowIconButton(symbol: "trash", action: onDelete)
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
        .background(hovering ? Color.white.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { onEdit() }
    }
}

private struct RowIconButton: View {
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? FlowTheme.ink : FlowTheme.inkSecondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering ? Color.white.opacity(0.10) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Draft-based inline editor: nothing touches the store until Save / Return.
/// Esc cancels.
private struct SnippetEditorRow: View {
    let kind: SnippetKind
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    @State private var trigger: String
    @State private var value: String
    @FocusState private var focusedField: Field?

    private enum Field { case trigger, value }

    init(
        kind: SnippetKind,
        initialTrigger: String,
        initialValue: String,
        onSave: @escaping (String, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.kind = kind
        self.onSave = onSave
        self.onCancel = onCancel
        _trigger = State(initialValue: initialTrigger)
        _value = State(initialValue: initialValue)
    }

    private var canSave: Bool {
        !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 10) {
            editorField(
                kind == .snippet ? "Shortcut" : "Word or name",
                text: $trigger,
                weight: .medium
            )
            .frame(maxWidth: kind == .snippet ? 170 : .infinity)
            .focused($focusedField, equals: .trigger)
            .onSubmit {
                if kind == .snippet {
                    focusedField = .value
                } else {
                    commit()
                }
            }

            if kind == .snippet {
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FlowTheme.inkTertiary)
                editorField("Expands to…", text: $value, weight: .regular)
                    .frame(maxWidth: .infinity)
                    .focused($focusedField, equals: .value)
                    .onSubmit { commit() }
            }

            SecondaryButton(title: "Save", action: commit)
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.45)

            RowIconButton(symbol: "xmark", action: onCancel)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
        .background(Color.white.opacity(0.05))
        .onAppear { focusedField = .trigger }
        .onExitCommand { onCancel() }
    }

    private func commit() {
        guard canSave else { return }
        onSave(
            trigger.trimmingCharacters(in: .whitespacesAndNewlines),
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func editorField(_ placeholder: String, text: Binding<String>, weight: Font.Weight) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: weight))
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
    }
}

// MARK: - Help

struct HelpSection: View {
    @EnvironmentObject var bridge: NugumiSettingsBridge

    var body: some View {
        DetailContainer("Help", subtitle: "Setup, support, and housekeeping.") {
            SubCard {
                VStack(spacing: 16) {
                    HelpRow(title: "How to use Nugumi",
                            subtitle: "Permission setup and a quick feature tour.",
                            button: "Open") {
                        bridge.perform(.openPermissionsHelp)
                    }
                    Divider().background(FlowTheme.hairline)
                    HelpRow(title: "Contact support",
                            subtitle: "Found a bug or have a request? Email Vadim.",
                            button: "Email") {
                        bridge.perform(.contactSupport)
                    }
                    if bridge.isAppBundle {
                        Divider().background(FlowTheme.hairline)
                        HelpRow(title: "Check for updates",
                                subtitle: "Currently on v\(bridge.appVersion).",
                                button: "Check") {
                            bridge.perform(.checkForUpdates)
                        }
                    }
                }
            }
            SubCard {
                VStack(spacing: 16) {
                    HelpRow(title: "Reset all settings",
                            subtitle: "Restore defaults. Snippets, dictionary, and stats are kept.",
                            button: "Reset",
                            destructive: true) {
                        bridge.perform(.resetSettings)
                    }
                    Divider().background(FlowTheme.hairline)
                    HelpRow(title: "Quit Nugumi",
                            subtitle: "Close Nugumi completely.",
                            button: "Quit",
                            destructive: true) {
                        bridge.perform(.quit)
                    }
                }
            }
        }
    }
}

private struct HelpRow: View {
    let title: String
    let subtitle: String
    let button: String
    var destructive: Bool = false
    let action: () -> Void

    var body: some View {
        SettingRow(title, subtitle: subtitle) {
            SecondaryButton(title: button, destructive: destructive, minWidth: 76, action: action)
        }
    }
}
