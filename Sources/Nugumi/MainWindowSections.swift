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
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
    }
}

private struct SecondaryButton: View {
    let title: String
    var destructive: Bool = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(destructive ? Color(red: 1.0, green: 0.62, blue: 0.62) : Color.white)
                .padding(.vertical, 7)
                .padding(.horizontal, 14)
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
        VStack(alignment: .leading, spacing: 11) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FlowTheme.ink)
            if rows.isEmpty {
                Text("Nothing yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.inkSecondary)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    BreakdownBar(label: row.0, value: row.1, fraction: row.2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BreakdownBar: View {
    let label: String
    let value: String
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.system(size: 13)).foregroundStyle(FlowTheme.ink).lineLimit(1)
                Spacer()
                Text(value).font(.system(size: 13, weight: .medium)).foregroundStyle(FlowTheme.inkSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(FlowTheme.accent)
                        .frame(width: max(6, geo.size.width * fraction))
                }
            }
            .frame(height: 8)
        }
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
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Auto Cleanup")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(FlowTheme.ink)
                        Spacer()
                        PillPicker(
                            options: CleanupLevel.allCases,
                            selection: bridge.binding(\.cleanupLevel) { .setCleanupLevel($0) },
                            label: { $0.displayName }
                        )
                    }
                    Text(bridge.settings.cleanupLevel.promptDescription)
                        .font(.system(size: 12.5))
                        .foregroundStyle(FlowTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct StyleCard: View {
    @EnvironmentObject var bridge: NugumiSettingsBridge
    let category: AppCategory
    @Binding var selection: WritingStyle

    var body: some View {
        SubCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text(category.displayName)
                        .font(FlowTheme.serif(19))
                        .foregroundStyle(FlowTheme.ink)
                    Spacer()
                    PillPicker(options: WritingStyle.allCases, selection: $selection, label: { $0.displayName })
                }

                // Left: how messages read in this style. Right: where it applies.
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 10) {
                        fieldLabel("Preview")
                        ChatBubble(text: sample(for: selection))
                        ChatBubble(text: koreanSample(for: selection))
                    }

                    if category == .other {
                        // "Other" is the catch-all every unmatched app/site falls
                        // into, so there's nothing to assign — explain instead.
                        VStack(alignment: .leading, spacing: 6) {
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
    var body: some View {
        Text(text)
            .font(.system(size: 13.5))
            .foregroundStyle(FlowTheme.ink)
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .frame(maxWidth: 360, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(FlowTheme.subtleFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(FlowTheme.hairline, lineWidth: 1)
            )
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
            ModelScopeCard(scope: .textActions,
                           title: "Everyday text",
                           subtitle: "Translate, rewrite, and smart replies.")
            ModelScopeCard(scope: .askNugumi,
                           title: "Ask Nugumi",
                           subtitle: "Screenshot questions. Vision-capable models only.")

            SubCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Cloud access")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(FlowTheme.ink)
                    Text("Sign in once to use hosted models. Keys are stored locally on this Mac.")
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.inkSecondary)
                    ForEach(CloudProvider.allCases, id: \.self) { provider in
                        ProviderRow(provider: provider)
                        if provider != CloudProvider.allCases.last {
                            Divider().background(FlowTheme.hairline)
                        }
                    }
                }
            }

            OllamaSetupCard()
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
                        modelSection(CloudProvider.openAI.displayName, LLMModel.models(for: .openAI))
                        modelSection(CloudProvider.anthropic.displayName, LLMModel.models(for: .anthropic))
                        modelSection(CloudProvider.gemini.displayName, LLMModel.models(for: .gemini))
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
                Circle()
                    .fill(signedIn ? FlowTheme.accent : Color.white.opacity(0.25))
                    .frame(width: 8, height: 8)
                Text(provider.displayName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(FlowTheme.ink)
                Spacer()
                Text(signedIn ? "Connected" : "Not connected")
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.inkSecondary)
                if signedIn {
                    SecondaryButton(title: testing ? "Testing…" : "Test") { runTest() }
                }
                SecondaryButton(title: buttonTitle(signedIn: signedIn)) {
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
        DetailContainer("Shortcuts", subtitle: "Global hotkeys that work from any app.") {
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
            HStack {
                Spacer()
                SecondaryButton(title: "Reset to defaults") {
                    bridge.perform(.resetShortcuts)
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

    private var items: [Snippet] { store.snippets.filter { $0.kind == kind } }

    private var title: String { kind == .snippet ? "Snippets" : "Dictionary" }
    private var subtitle: String {
        kind == .snippet
            ? "Short phrases Nugumi expands before rewriting."
            : "Words and names Nugumi keeps exactly as written."
    }

    var body: some View {
        DetailContainer(title, subtitle: subtitle) {
            HStack {
                Spacer()
                SecondaryButton(title: kind == .snippet ? "+ Add snippet" : "+ Add word") {
                    store.add(kind: kind)
                }
            }
            if items.isEmpty {
                SubCard {
                    Text(kind == .snippet
                         ? "No snippets yet. Add one like “omw” → “on my way”."
                         : "No saved words yet. Add names or terms Nugumi should never translate.")
                        .font(.system(size: 13))
                        .foregroundStyle(FlowTheme.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(items) { snippet in
                        SnippetEditorRow(store: store, snippet: snippet)
                    }
                }
            }
        }
    }
}

private struct SnippetEditorRow: View {
    @ObservedObject var store: SnippetsStore
    let snippet: Snippet

    private var live: Snippet { store.snippets.first { $0.id == snippet.id } ?? snippet }

    var body: some View {
        HStack(spacing: 10) {
            TextField("Trigger", text: Binding(
                get: { live.trigger },
                set: { store.update(snippet.id, trigger: $0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .padding(.vertical, 8).padding(.horizontal, 11)
            .frame(width: snippet.kind == .snippet ? 150 : nil)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(FlowTheme.hairline, lineWidth: 1))

            if snippet.kind == .snippet {
                Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(FlowTheme.inkTertiary)
                TextField("Expands to…", text: Binding(
                    get: { live.value },
                    set: { store.update(snippet.id, value: $0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.vertical, 8).padding(.horizontal, 11)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(FlowTheme.hairline, lineWidth: 1))
            } else {
                Spacer()
            }

            Button {
                store.delete(snippet.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundStyle(FlowTheme.inkSecondary)
                    .padding(7)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(FlowTheme.subtleFill))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
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
                            subtitle: "Permissions and a quick feature tour.",
                            button: "Open") {
                        bridge.perform(.openPermissionsHelp)
                    }
                    Divider().background(FlowTheme.hairline)
                    HelpRow(title: "Set up local models",
                            subtitle: "Install or download Ollama models for offline use.",
                            button: "Open") {
                        bridge.perform(.openSetup)
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
            SecondaryButton(title: button, destructive: destructive, action: action)
        }
    }
}
