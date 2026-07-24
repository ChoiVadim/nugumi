import Combine
import Foundation

/// What produced a history entry. Mirrors the translation modes plus Ask Nugumi.
enum HistoryKind: String, Codable, Equatable {
    case selection
    case screenArea
    case draftMessage
    case smartReply
    case askNugumi

    var title: String {
        switch self {
        case .selection: return "Translation"
        case .screenArea: return "Screen translation"
        case .draftMessage: return "Rewrite"
        case .smartReply: return "Reply"
        case .askNugumi: return "Ask Nugumi"
        }
    }

    var symbolName: String {
        switch self {
        case .selection: return "text.viewfinder"
        case .screenArea: return "viewfinder"
        case .draftMessage: return "text.insert"
        case .smartReply: return "bubble.left.and.bubble.right"
        case .askNugumi: return "sparkles"
        }
    }

    /// `nil` for `.replacement`, which is bookkeeping rather than a translation.
    init?(usageKind: UsageStatsEventKind) {
        switch usageKind {
        case .selection: self = .selection
        case .screenArea: self = .screenArea
        case .draftMessage: self = .draftMessage
        case .smartReply: self = .smartReply
        case .replacement: return nil
        }
    }
}

struct TranslationHistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let kind: HistoryKind
    let sourceText: String
    let resultText: String
    let targetLanguageID: String?
}

/// Persisted feed of recent translations and Ask Nugumi turns, shown on Home.
/// Kept separate from `UsageStatsStore` (which stores only counts) so the stats
/// stay lightweight while history keeps the actual text.
@MainActor
final class TranslationHistoryStore: ObservableObject {
    @Published private(set) var entries: [TranslationHistoryEntry] = []

    private static let defaultsKey = "com.nugumi.app.translationHistory.v1"
    private static let maxEntries = 200
    private static let maxTextLength = 2000

    init() {
        load()
    }

    func record(
        sourceText: String,
        resultText: String,
        kind: UsageStatsEventKind,
        targetLanguage: TranslationLanguage
    ) {
        guard let historyKind = HistoryKind(usageKind: kind) else { return }
        append(
            kind: historyKind,
            source: sourceText,
            result: resultText,
            targetLanguageID: targetLanguage.id
        )
    }

    func recordAsk(question: String, answer: String) {
        append(kind: .askNugumi, source: question, result: answer, targetLanguageID: nil)
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func append(kind: HistoryKind, source: String, result: String, targetLanguageID: String?) {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty || !trimmedResult.isEmpty else { return }

        let entry = TranslationHistoryEntry(
            id: UUID(),
            date: Date(),
            kind: kind,
            sourceText: String(trimmedSource.prefix(Self.maxTextLength)),
            resultText: String(trimmedResult.prefix(Self.maxTextLength)),
            targetLanguageID: targetLanguageID
        )
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([TranslationHistoryEntry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
