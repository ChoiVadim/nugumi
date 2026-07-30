import AppKit
import SwiftUI

struct HomeSection: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge
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
                        Text("Your recent results and chats with Gizmate.")
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
                            Text("Select text anywhere and translate, rewrite, reply, or ask Gizmate - it shows up here.")
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
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !entry.resultText.isEmpty {
                    Text(entry.resultText)
                        .font(.system(size: 14))
                        .foregroundStyle(FlowTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
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
