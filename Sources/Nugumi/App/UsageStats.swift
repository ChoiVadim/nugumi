import AppKit
import Combine
import Foundation
import SwiftUI

enum UsageStatsEventKind: String, Codable, CaseIterable, Equatable, Identifiable {
    case selection
    case screenArea
    case draftMessage
    case smartReply
    case replacement

    var id: String { rawValue }

    var title: String {
        switch self {
        case .selection: return "Selected text"
        case .screenArea: return "Screen text"
        case .draftMessage: return "My writing"
        case .smartReply: return "Replies"
        case .replacement: return "Replacements"
        }
    }

    var symbolName: String {
        switch self {
        case .selection: return "text.viewfinder"
        case .screenArea: return "viewfinder"
        case .draftMessage: return "text.insert"
        case .smartReply: return "bubble.left.and.bubble.right"
        case .replacement: return "arrow.triangle.2.circlepath"
        }
    }

    var color: Color {
        switch self {
        case .selection: return Color(red: 0.76, green: 0.76, blue: 0.76)
        case .screenArea: return Color(red: 0.64, green: 0.64, blue: 0.64)
        case .draftMessage: return Color(red: 0.52, green: 0.52, blue: 0.52)
        case .smartReply: return Color(red: 0.88, green: 0.88, blue: 0.88)
        case .replacement: return Color(red: 0.70, green: 0.70, blue: 0.70)
        }
    }

    static var useKinds: [UsageStatsEventKind] {
        [.selection, .screenArea, .draftMessage, .smartReply]
    }
}

struct UsageStatsEvent: Codable, Identifiable {
    let id: UUID
    let date: Date
    let kind: UsageStatsEventKind
    let sourceWordCount: Int
    let resultWordCount: Int
    let characterCount: Int
    let targetLanguageID: String?
}

struct UsageStatsModeBreakdown: Identifiable {
    let kind: UsageStatsEventKind
    let count: Int
    let wordCount: Int
    let fraction: Double

    var id: UsageStatsEventKind { kind }
}

struct UsageStatsLanguageBreakdown: Identifiable {
    let languageID: String
    let displayName: String
    let count: Int
    let wordCount: Int
    let fraction: Double

    var id: String { languageID }
}

struct UsageStatsDayBucket: Identifiable {
    let date: Date
    let eventCount: Int
    let wordCount: Int
    let isToday: Bool

    var id: Date { date }
}

struct UsageStatsSnapshot {
    let events: [UsageStatsEvent]
    let totalUses: Int
    let totalSourceWords: Int
    let totalResultWords: Int
    let totalReplacements: Int
    let currentStreak: Int
    let longestStreak: Int
    let currentMonthWords: Int
    let previousMonthWords: Int
    let monthChangePercent: Int?
    let activeDays: Int
    let averageWordsPerActiveDay: Int
    let busiestDay: UsageStatsDayBucket?
    let modeBreakdown: [UsageStatsModeBreakdown]
    let languageBreakdown: [UsageStatsLanguageBreakdown]
    let heatmapWeeks: [[UsageStatsDayBucket]]

    static var empty: UsageStatsSnapshot {
        make(events: [])
    }

    static func make(events: [UsageStatsEvent], calendar inputCalendar: Calendar = .current) -> UsageStatsSnapshot {
        var calendar = inputCalendar
        calendar.timeZone = .current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let useEvents = events.filter { UsageStatsEventKind.useKinds.contains($0.kind) }
        let totalSourceWords = countedWords(in: useEvents)
        let totalResultWords = useEvents.reduce(0) { $0 + $1.resultWordCount }
        let totalReplacements = events.filter { $0.kind == .replacement }.count

        let dayWords = Dictionary(grouping: useEvents) { event in
            calendar.startOfDay(for: event.date)
        }.mapValues { dayEvents in
            countedWords(in: dayEvents)
        }
        let activeDaySet = Set(dayWords.keys)
        let streaks = streakValues(activeDays: activeDaySet, today: today, calendar: calendar)

        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? today
        let previousMonthStart = calendar.date(byAdding: .month, value: -1, to: monthStart) ?? monthStart
        let currentMonthWords = useEvents
            .filter { $0.date >= monthStart }
            .reduce(0) { $0 + max($1.sourceWordCount, $1.resultWordCount) }
        let previousMonthWords = useEvents
            .filter { $0.date >= previousMonthStart && $0.date < monthStart }
            .reduce(0) { $0 + max($1.sourceWordCount, $1.resultWordCount) }
        let monthChangePercent: Int? = previousMonthWords > 0
            ? Int(round((Double(currentMonthWords - previousMonthWords) / Double(previousMonthWords)) * 100))
            : nil

        let modeBreakdown = UsageStatsEventKind.useKinds.map { kind in
            let modeEvents = useEvents.filter { $0.kind == kind }
            let words = modeEvents.reduce(0) { $0 + $1.sourceWordCount }
            let fraction = useEvents.isEmpty ? 0 : Double(modeEvents.count) / Double(useEvents.count)
            return UsageStatsModeBreakdown(kind: kind, count: modeEvents.count, wordCount: words, fraction: fraction)
        }

        let languageEvents = Dictionary(grouping: useEvents) { $0.targetLanguageID ?? "" }
        let languageBreakdown = languageEvents.map { languageID, languageEvents in
            let language = TranslationLanguage.language(id: languageID)
            let words = languageEvents.reduce(0) { $0 + $1.sourceWordCount }
            let fraction = useEvents.isEmpty ? 0 : Double(languageEvents.count) / Double(useEvents.count)
            return UsageStatsLanguageBreakdown(
                languageID: languageID,
                displayName: language.displayName,
                count: languageEvents.count,
                wordCount: words,
                fraction: fraction
            )
        }
        .sorted { lhs, rhs in
            if lhs.count == rhs.count {
                return lhs.displayName < rhs.displayName
            }
            return lhs.count > rhs.count
        }

        let heatmapWeeks = makeHeatmapWeeks(events: useEvents, today: today, calendar: calendar)
        let flatBuckets = heatmapWeeks.flatMap { $0 }
        let busiestDay = flatBuckets.max { lhs, rhs in
            if lhs.wordCount == rhs.wordCount {
                return lhs.eventCount < rhs.eventCount
            }
            return lhs.wordCount < rhs.wordCount
        }
        let activeDays = activeDaySet.count
        let averageWordsPerActiveDay = activeDays == 0 ? 0 : Int(round(Double(totalSourceWords) / Double(activeDays)))

        return UsageStatsSnapshot(
            events: events,
            totalUses: useEvents.count,
            totalSourceWords: totalSourceWords,
            totalResultWords: totalResultWords,
            totalReplacements: totalReplacements,
            currentStreak: streaks.current,
            longestStreak: streaks.longest,
            currentMonthWords: currentMonthWords,
            previousMonthWords: previousMonthWords,
            monthChangePercent: monthChangePercent,
            activeDays: activeDays,
            averageWordsPerActiveDay: averageWordsPerActiveDay,
            busiestDay: busiestDay,
            modeBreakdown: modeBreakdown,
            languageBreakdown: languageBreakdown,
            heatmapWeeks: heatmapWeeks
        )
    }

    private static func countedWords(in events: [UsageStatsEvent]) -> Int {
        events.reduce(0) { $0 + max($1.sourceWordCount, $1.resultWordCount) }
    }

    private static func makeHeatmapWeeks(
        events: [UsageStatsEvent],
        today: Date,
        calendar: Calendar
    ) -> [[UsageStatsDayBucket]] {
        let startOfThisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let startDate = calendar.date(byAdding: .weekOfYear, value: -7, to: startOfThisWeek) ?? today
        let groupedEvents = Dictionary(grouping: events) { event in
            calendar.startOfDay(for: event.date)
        }

        return (0..<8).map { weekOffset in
            (0..<7).compactMap { dayOffset in
                let offset = weekOffset * 7 + dayOffset
                guard let date = calendar.date(byAdding: .day, value: offset, to: startDate) else {
                    return nil
                }
                let day = calendar.startOfDay(for: date)
                let dayEvents = groupedEvents[day] ?? []
                let words = dayEvents.reduce(0) { $0 + max($1.sourceWordCount, $1.resultWordCount) }
                return UsageStatsDayBucket(
                    date: day,
                    eventCount: dayEvents.count,
                    wordCount: words,
                    isToday: calendar.isDate(day, inSameDayAs: today)
                )
            }
        }
    }

    private static func streakValues(
        activeDays: Set<Date>,
        today: Date,
        calendar: Calendar
    ) -> (current: Int, longest: Int) {
        var current = 0
        var cursor = today
        while activeDays.contains(cursor) {
            current += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                break
            }
            cursor = previous
        }

        let sortedDays = activeDays.sorted()
        var longest = 0
        var running = 0
        var previousDay: Date?
        for day in sortedDays {
            if let previousDay,
               let expected = calendar.date(byAdding: .day, value: 1, to: previousDay),
               calendar.isDate(day, inSameDayAs: expected) {
                running += 1
            } else {
                running = 1
            }
            longest = max(longest, running)
            previousDay = day
        }

        return (current, longest)
    }
}

@MainActor
final class UsageStatsStore: ObservableObject {
    private static let storageKey = "com.nugumi.app.usageStats.events.v1"
    private static let maxStoredEvents = 2_500

    private let defaults: UserDefaults
    @Published private(set) var snapshot: UsageStatsSnapshot

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let events = Self.loadEvents(from: defaults)
        snapshot = UsageStatsSnapshot.make(events: events)
    }

    func recordUse(
        sourceText: String,
        resultText: String,
        kind: UsageStatsEventKind,
        targetLanguage: TranslationLanguage
    ) {
        guard UsageStatsEventKind.useKinds.contains(kind) else {
            return
        }
        let event = UsageStatsEvent(
            id: UUID(),
            date: Date(),
            kind: kind,
            sourceWordCount: Self.wordCount(in: sourceText),
            resultWordCount: Self.wordCount(in: resultText),
            characterCount: sourceText.count,
            targetLanguageID: targetLanguage.id
        )
        append(event)
    }

    func recordReplacement(text: String) {
        let wordCount = Self.wordCount(in: text)
        guard wordCount > 0 else { return }
        let event = UsageStatsEvent(
            id: UUID(),
            date: Date(),
            kind: .replacement,
            sourceWordCount: 0,
            resultWordCount: wordCount,
            characterCount: text.count,
            targetLanguageID: nil
        )
        append(event)
    }

    func refresh() {
        snapshot = UsageStatsSnapshot.make(events: snapshot.events)
    }

    private func append(_ event: UsageStatsEvent) {
        var events = snapshot.events
        events.append(event)
        if events.count > Self.maxStoredEvents {
            events = Array(events.suffix(Self.maxStoredEvents))
        }
        save(events)
        snapshot = UsageStatsSnapshot.make(events: events)
    }

    private func save(_ events: [UsageStatsEvent]) {
        guard let data = try? JSONEncoder().encode(events) else {
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func loadEvents(from defaults: UserDefaults) -> [UsageStatsEvent] {
        guard let data = defaults.data(forKey: storageKey),
              let events = try? JSONDecoder().decode([UsageStatsEvent].self, from: data)
        else {
            return []
        }
        return Array(events.sorted { $0.date < $1.date }.suffix(maxStoredEvents))
    }

    private static func wordCount(in text: String) -> Int {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return 0 }

        let tokens = cleaned.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let cjkScalars = cleaned.unicodeScalars.filter { scalar in
            (0x3040...0x30FF).contains(Int(scalar.value))
                || (0x3400...0x9FFF).contains(Int(scalar.value))
                || (0xAC00...0xD7AF).contains(Int(scalar.value))
        }.count

        return max(tokens.count, cjkScalars)
    }
}

let usageStatsExpandedKey = "usageStatsExpanded"

@MainActor
final class UsageStatsMenuItem: NSMenuItem {
    private let store: UsageStatsStore
    private let onRequestReopen: () -> Void
    private var hostingView: NSHostingView<UsageStatsMenuSummaryView>!

    init(store: UsageStatsStore, onRequestReopen: @escaping () -> Void) {
        self.store = store
        self.onRequestReopen = onRequestReopen
        super.init(title: "", action: nil, keyEquivalent: "")

        let host = NSHostingView(rootView: makeRootView(isExpanded: Self.persistedExpanded))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        hostingView = host
        view = host
    }

    func refitFrame() {
        hostingView.rootView = makeRootView(isExpanded: Self.persistedExpanded)
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
    }

    private static var persistedExpanded: Bool {
        UserDefaults.standard.bool(forKey: usageStatsExpandedKey)
    }

    private func makeRootView(isExpanded: Bool) -> UsageStatsMenuSummaryView {
        UsageStatsMenuSummaryView(
            store: store,
            isExpanded: isExpanded,
            onToggle: { [weak self] in
                self?.handleToggle()
            }
        )
    }

    private func handleToggle() {
        let defaults = UserDefaults.standard
        let newValue = !defaults.bool(forKey: usageStatsExpandedKey)
        defaults.set(newValue, forKey: usageStatsExpandedKey)

        // Synchronously rebuild the SwiftUI rootView and resize the host so the
        // next menu open reads the correct frame. Reading fittingSize after
        // setting a fresh value-typed rootView forces SwiftUI to lay out now.
        hostingView.rootView = makeRootView(isExpanded: newValue)
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)

        onRequestReopen()
        menu?.cancelTracking()
    }

    required init(coder: NSCoder) {
        fatalError("UsageStatsMenuItem is not loaded from a nib")
    }
}

private struct UsageStatsMenuSummaryView: View {
    @ObservedObject var store: UsageStatsStore
    let isExpanded: Bool
    let onToggle: () -> Void
    private let contentWidth: CGFloat = 310

    private var snapshot: UsageStatsSnapshot { store.snapshot }
    private var todayWords: Int {
        // Mirror the filter used for the lifetime total — exclude
        // `.replacement` events so the same translation isn't counted twice
        // (once as the originating use, once as the follow-up replacement).
        snapshot.events
            .filter { Calendar.current.isDateInToday($0.date) }
            .filter { UsageStatsEventKind.useKinds.contains($0.kind) }
            .reduce(0) { $0 + max($1.sourceWordCount, $1.resultWordCount) }
    }
    private var workflowItems: [UsageStatsModeBreakdown] {
        snapshot.modeBreakdown.filter { $0.count > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nugumi usage")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text("Local stats")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label("\(snapshot.totalUses.formatted()) uses", systemImage: "chart.bar.xaxis")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                expandToggle
            }

            HStack(spacing: 0) {
                MenuMetricValue(title: "Words", value: snapshot.totalSourceWords.formatted())
                MenuMetricDivider()
                MenuMetricValue(title: "Today words", value: todayWords.formatted())
                MenuMetricDivider()
                MenuMetricValue(title: "Streak", value: "\(snapshot.currentStreak)d")
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Activity map")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(snapshot.currentStreak)d current")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }

                    MenuActivityMap(snapshot: snapshot)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Workflow mix")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(snapshot.totalReplacements.formatted()) replaced")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }

                    GeometryReader { proxy in
                        if snapshot.totalUses == 0 {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        } else {
                            HStack(spacing: 0) {
                                ForEach(workflowItems) { item in
                                    Rectangle()
                                        .fill(item.kind.color.opacity(0.86))
                                        .frame(width: proxy.size.width * item.fraction)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        }
                    }
                    .frame(height: 10)

                    HStack(spacing: 7) {
                        ForEach(workflowItems) { item in
                            WorkflowLegendItem(kind: item.kind)
                        }
                        if snapshot.modeBreakdown.allSatisfy({ $0.count == 0 }) {
                            Text("Start using Nugumi to fill this chart")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .frame(width: contentWidth, alignment: .topLeading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.84))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.34), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .onAppear { store.refresh() }
    }

    private var expandToggle: some View {
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 18)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .onTapGesture {
                onToggle()
            }
            .help(isExpanded ? "Show less" : "Show more")
    }
}

private struct WorkflowLegendItem: View {
    let kind: UsageStatsEventKind

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3.5) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 11, alignment: .center)

            Text(kind.title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct MenuMetricValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MenuMetricDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.45))
            .frame(width: 1, height: 32)
            .padding(.horizontal, 10)
    }
}

private struct MenuActivityMap: View {
    let snapshot: UsageStatsSnapshot

    private var maxWords: Int {
        max(1, snapshot.heatmapWeeks.flatMap { $0 }.map(\.wordCount).max() ?? 1)
    }

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 6) {
                ForEach(snapshot.heatmapWeeks.indices, id: \.self) { weekIndex in
                    VStack(spacing: 5) {
                        ForEach(snapshot.heatmapWeeks[weekIndex]) { bucket in
                            MenuHeatmapCell(
                                bucket: bucket,
                                maxWords: maxWords
                            )
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 115, alignment: .center)
    }
}

private struct MenuHeatmapCell: View {
    let bucket: UsageStatsDayBucket
    let maxWords: Int

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(fill)
            .frame(width: 13, height: 13)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(bucket.isToday ? UsageStatsEventKind.draftMessage.color : Color.clear, lineWidth: 1.4)
            )
            .help("\(shortDate(bucket.date)): \(bucket.wordCount) words")
    }

    private var fill: Color {
        guard bucket.wordCount > 0 else {
            return Color.primary.opacity(0.06)
        }
        let intensity = max(0.22, min(1.0, Double(bucket.wordCount) / Double(maxWords)))
        return UsageStatsEventKind.selection.color.opacity(intensity)
    }
}

private func shortDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    return formatter.string(from: date)
}
