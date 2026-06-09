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
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FlowTheme.ink)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(FlowTheme.inkSecondary)
        }
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
                        StatTile(value: "\(snapshot.totalUses)", label: "translations", accent: true)
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Insights")
                        .font(FlowTheme.serif(26))
                        .foregroundStyle(FlowTheme.ink)
                    Text("Your translating, by the numbers.")
                        .font(.system(size: 13))
                        .foregroundStyle(FlowTheme.inkSecondary)
                }

                HStack(spacing: 10) {
                    StatTile(value: "\(snapshot.currentMonthWords)", label: "words this month", accent: true, compact: true)
                    StatTile(value: "\(snapshot.longestStreak)", label: "longest streak", compact: true)
                    StatTile(value: "\(snapshot.activeDays)", label: "active days", compact: true)
                    StatTile(value: "\(snapshot.averageWordsPerActiveDay)", label: "avg / day", compact: true)
                }

                SubCard(padding: 16) {
                    HStack(alignment: .top, spacing: 18) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Activity")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(FlowTheme.ink)
                            ActivityHeatmap(weeks: snapshot.heatmapWeeks, cell: 13, spacing: 3)
                        }
                        Spacer(minLength: 12)
                        VStack(alignment: .leading, spacing: 13) {
                            miniStat("\(snapshot.currentStreak)d", "Current streak")
                            if let busiest = snapshot.busiestDay, busiest.wordCount > 0 {
                                miniStat("\(busiest.wordCount)", "Busiest · \(busiest.date.formatted(.dateTime.month().day()))")
                            }
                            miniStat("\(snapshot.totalSourceWords)", "Total words")
                        }
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    SubCard(padding: 16) {
                        breakdownColumn(
                            title: "Workflow mix",
                            rows: snapshot.modeBreakdown
                                .filter { $0.count > 0 }
                                .map { ($0.kind.title, "\($0.count)", $0.fraction) }
                        )
                    }
                    SubCard(padding: 16) {
                        breakdownColumn(
                            title: "Languages",
                            rows: snapshot.languageBreakdown
                                .filter { $0.count > 0 }
                                .prefix(4)
                                .map { ($0.displayName.isEmpty ? "Unknown" : $0.displayName, "\($0.count)", $0.fraction) }
                        )
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(28)
        }
    }

    private func miniStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(FlowTheme.ink)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(FlowTheme.inkTertiary)
        }
    }

    @ViewBuilder
    private func breakdownColumn(title: String, rows: [(String, String, Double)]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
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
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.system(size: 12)).foregroundStyle(FlowTheme.ink).lineLimit(1)
                Spacer()
                Text(value).font(.system(size: 12, weight: .medium)).foregroundStyle(FlowTheme.inkSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(FlowTheme.accent)
                        .frame(width: max(5, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
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
    let category: AppCategory
    @Binding var selection: WritingStyle

    var body: some View {
        SubCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(category.displayName)
                        .font(FlowTheme.serif(19))
                        .foregroundStyle(FlowTheme.ink)
                    Spacer()
                    PillPicker(options: WritingStyle.allCases, selection: $selection, label: { $0.displayName })
                }
                ChatBubble(text: sample(for: selection))
            }
        }
    }

    private func sample(for style: WritingStyle) -> String {
        switch style {
        case .formal: return "Hello, are you available for lunch tomorrow? Twelve o'clock would suit me well."
        case .polite: return "Hi! Are you free for lunch tomorrow? Let's do 12 if that works for you."
        case .casual: return "hey are you free for lunch tmrw? let's do 12 if that works"
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
                    .fill(FlowTheme.accentSoft)
            )
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
        }
    }
}

private struct ModelScopeCard: View {
    @EnvironmentObject var bridge: NugumiSettingsBridge
    let scope: ModelUseScope
    let title: String
    let subtitle: String

    private var models: [LLMModel] {
        scope.availableModels() + scope.availableModels(from: LLMModel.codexModels)
    }
    private var currentID: String { bridge.settings.modelID(for: scope) }

    var body: some View {
        SubCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(FlowTheme.ink)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(FlowTheme.inkSecondary)
                }
                SettingRow("Model") {
                    Menu {
                        ForEach(models, id: \.id) { model in
                            Button {
                                bridge.perform(.chooseModel(model.id, scope))
                            } label: {
                                if model.id == currentID {
                                    Label(model.displayName, systemImage: "checkmark")
                                } else {
                                    Text(model.displayName)
                                }
                            }
                        }
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
}

private struct ProviderRow: View {
    @EnvironmentObject var bridge: NugumiSettingsBridge
    let provider: CloudProvider

    var body: some View {
        let signedIn = bridge.hasCredentials(provider)
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
            SecondaryButton(title: buttonTitle(signedIn: signedIn)) {
                bridge.perform(.signInCloud(provider))
            }
        }
    }

    private func buttonTitle(signedIn: Bool) -> String {
        if provider.usesOAuth { return signedIn ? "Re-sign in" : "Sign in" }
        return signedIn ? "Update key" : "Add key"
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
