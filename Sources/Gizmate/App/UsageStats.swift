import AppKit
import Combine
import Foundation
import SwiftUI

/// Raw values are persisted — **never rename one**. Adding a case is safe:
/// events written by an older build simply won't carry it.
enum UsageStatsEventKind: String, Codable, CaseIterable, Equatable, Identifiable {
    case selection
    case screenArea
    case draftMessage
    case smartReply
    case replacement
    /// One of the user's own gizmos, named by `UsageStatsEvent.gizmoName`.
    case gizmoRun

    var id: String { rawValue }

    /// What a run of this kind is called in the top-gizmos list. A `.gizmoRun`
    /// event carries the user's own name and never falls back to this.
    var title: String {
        switch self {
        case .selection: return "Selected text"
        case .screenArea: return "Screen text"
        case .draftMessage: return "My writing"
        case .smartReply: return "Replies"
        case .replacement: return "Replacements"
        case .gizmoRun: return "Gizmo"
        }
    }

    var symbolName: String {
        switch self {
        case .selection: return "text.viewfinder"
        case .screenArea: return "viewfinder"
        case .draftMessage: return "text.insert"
        case .smartReply: return "bubble.left.and.bubble.right"
        case .replacement: return "arrow.triangle.2.circlepath"
        case .gizmoRun: return "wand.and.stars"
        }
    }

    var color: Color {
        switch self {
        case .selection: return Color(red: 0.76, green: 0.76, blue: 0.76)
        case .screenArea: return Color(red: 0.64, green: 0.64, blue: 0.64)
        case .draftMessage: return Color(red: 0.52, green: 0.52, blue: 0.52)
        case .smartReply: return Color(red: 0.88, green: 0.88, blue: 0.88)
        case .replacement: return Color(red: 0.70, green: 0.70, blue: 0.70)
        case .gizmoRun: return Color(red: 0.82, green: 0.82, blue: 0.82)
        }
    }

    /// The ring's own actions. They live in the same slots as the user's gizmos
    /// and the user does not tell them apart, so they count as gizmos too — but
    /// only these arrive through `recordUse`.
    static var builtInKinds: [UsageStatsEventKind] {
        [.selection, .screenArea, .draftMessage, .smartReply]
    }

    /// Everything that counts as a run. `.replacement` is excluded: it is the
    /// follow-up to a run that already counted, not a run of its own.
    static var runKinds: [UsageStatsEventKind] {
        builtInKinds + [.gizmoRun]
    }
}

struct UsageStatsEvent: Codable, Identifiable {
    let id: UUID
    let date: Date
    let kind: UsageStatsEventKind
    // Word, character and language counts are no longer shown anywhere. They
    // stay on the event because they are already written into everyone's stored
    // history, and dropping them from the schema would throw that away for no
    // gain — the aggregation, not the recording, is what got deleted.
    let sourceWordCount: Int
    let resultWordCount: Int
    let characterCount: Int
    let targetLanguageID: String?
    /// The gizmo's own name, for `.gizmoRun`. `var` rather than `let` so the
    /// memberwise initializer defaults it to nil: every event written before
    /// gizmo runs were counted decodes without this key.
    var gizmoName: String?

    /// What this run is called in the top-gizmos list.
    var displayName: String {
        gizmoName ?? kind.title
    }
}

struct UsageStatsGizmoBreakdown: Identifiable {
    let name: String
    let count: Int
    let fraction: Double

    var id: String { name }
}

struct UsageStatsDayBucket: Identifiable {
    let date: Date
    let runCount: Int
    let isToday: Bool

    var id: Date { date }
}

struct UsageStatsSnapshot {
    let events: [UsageStatsEvent]
    /// Every run, built-in and user gizmo alike.
    let totalRuns: Int
    /// How many different gizmos have ever been run.
    let distinctGizmos: Int
    let runsToday: Int
    let currentStreak: Int
    let longestStreak: Int
    let busiestDay: UsageStatsDayBucket?
    let gizmoBreakdown: [UsageStatsGizmoBreakdown]
    let heatmapWeeks: [[UsageStatsDayBucket]]

    static var empty: UsageStatsSnapshot {
        make(events: [])
    }

    static func make(events: [UsageStatsEvent], calendar inputCalendar: Calendar = .current) -> UsageStatsSnapshot {
        var calendar = inputCalendar
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        let runEvents = events.filter { UsageStatsEventKind.runKinds.contains($0.kind) }

        let runsByDay = Dictionary(grouping: runEvents) { calendar.startOfDay(for: $0.date) }
        let streaks = streakValues(activeDays: Set(runsByDay.keys), today: today, calendar: calendar)

        let totalRuns = runEvents.count
        let byName = Dictionary(grouping: runEvents, by: \.displayName)
        var gizmoBreakdown: [UsageStatsGizmoBreakdown] = byName.map { name, named in
            let count: Int = named.count
            let fraction: Double = totalRuns == 0 ? 0 : Double(count) / Double(totalRuns)
            return UsageStatsGizmoBreakdown(name: name, count: count, fraction: fraction)
        }
        gizmoBreakdown.sort { lhs, rhs in
            lhs.count == rhs.count ? lhs.name < rhs.name : lhs.count > rhs.count
        }

        let heatmapWeeks = makeHeatmapWeeks(events: runEvents, today: today, calendar: calendar)
        let busiestDay = heatmapWeeks.flatMap { $0 }.max { $0.runCount < $1.runCount }

        return UsageStatsSnapshot(
            events: events,
            totalRuns: totalRuns,
            distinctGizmos: byName.count,
            runsToday: runsByDay[today]?.count ?? 0,
            currentStreak: streaks.current,
            longestStreak: streaks.longest,
            busiestDay: busiestDay,
            gizmoBreakdown: gizmoBreakdown,
            heatmapWeeks: heatmapWeeks
        )
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
                return UsageStatsDayBucket(
                    date: day,
                    runCount: (groupedEvents[day] ?? []).count,
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
    // Pre-rename key on purpose — renaming it hides every existing user's stats.
    private static let storageKey = "com.gizmate.app.usageStats.events.v1"
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
        guard UsageStatsEventKind.builtInKinds.contains(kind) else {
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

    /// One run of one of the user's own gizmos. Recorded where every kind of
    /// gizmo is dispatched, so prompt, native, script and agent all land here.
    func recordGizmoRun(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        append(UsageStatsEvent(
            id: UUID(),
            date: Date(),
            kind: .gizmoRun,
            sourceWordCount: 0,
            resultWordCount: 0,
            characterCount: 0,
            targetLanguageID: nil,
            gizmoName: trimmed.isEmpty ? UsageStatsEventKind.gizmoRun.title : trimmed
        ))
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
    /// Top few only: the plate is 310pt wide and a legend that wraps pushes the
    /// menu taller than the thing it summarizes.
    private var gizmoItems: [UsageStatsGizmoBreakdown] {
        Array(snapshot.gizmoBreakdown.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gizmate usage")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text("Local stats")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label("\(snapshot.distinctGizmos.formatted()) gizmos", systemImage: "chart.bar.xaxis")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                expandToggle
            }

            HStack(spacing: 0) {
                MenuMetricValue(title: "Runs", value: snapshot.totalRuns.formatted())
                MenuMetricDivider()
                MenuMetricValue(title: "Today", value: snapshot.runsToday.formatted())
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
                        Text("Top gizmos")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(snapshot.longestStreak)d best")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }

                    GeometryReader { proxy in
                        if snapshot.totalRuns == 0 {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        } else {
                            HStack(spacing: 0) {
                                ForEach(Array(gizmoItems.enumerated()), id: \.element.id) { index, item in
                                    Rectangle()
                                        .fill(Self.shade(index))
                                        .frame(width: proxy.size.width * item.fraction)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        }
                    }
                    .frame(height: 10)

                    HStack(spacing: 7) {
                        ForEach(Array(gizmoItems.enumerated()), id: \.element.id) { index, item in
                            GizmoLegendItem(name: item.name, swatch: Self.shade(index))
                        }
                        if gizmoItems.isEmpty {
                            Text("Run a gizmo to fill this chart")
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

    /// The menu plate sits on system material, light or dark, so the ramp is
    /// built from `Color.primary` rather than the fixed greys the ring uses.
    private static func shade(_ index: Int) -> Color {
        let opacities: [Double] = [0.78, 0.55, 0.36, 0.22]
        return Color.primary.opacity(opacities[min(index, opacities.count - 1)])
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
            .cursor(.pointingHand)
            .help(isExpanded ? "Show less" : "Show more")
    }
}

private struct GizmoLegendItem: View {
    let name: String
    let swatch: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3.5) {
            Circle()
                .fill(swatch)
                .frame(width: 6, height: 6)

            Text(name)
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

    private var maxRuns: Int {
        max(1, snapshot.heatmapWeeks.flatMap { $0 }.map(\.runCount).max() ?? 1)
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
                                maxRuns: maxRuns
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
    let maxRuns: Int

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(fill)
            .frame(width: 13, height: 13)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(bucket.isToday ? UsageStatsEventKind.draftMessage.color : Color.clear, lineWidth: 1.4)
            )
            .help("\(shortDate(bucket.date)): \(bucket.runCount) runs")
    }

    private var fill: Color {
        guard bucket.runCount > 0 else {
            return Color.primary.opacity(0.06)
        }
        let intensity = max(0.22, min(1.0, Double(bucket.runCount) / Double(maxRuns)))
        return UsageStatsEventKind.selection.color.opacity(intensity)
    }
}

private func shortDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    return formatter.string(from: date)
}
