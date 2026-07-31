import Foundation

/// Maps Gizmate's target-language setting to the ISO code the Realtime
/// translation API expects in `session.audio.output.language`.
enum LiveTranslationLanguage {
    static func apiCode(for language: TranslationLanguage) -> String {
        switch language.id {
        case "zh-Hans": return "zh"
        default: return language.id
        }
    }

}

/// Source STT and its streaming translation, shown as TWO DECOUPLED streams.
///
/// The two realtime streams (`input_transcript.delta` = source, `output_transcript.delta`
/// = translation) lag each other by a variable amount that even flips sign (the
/// translation sometimes leads, sometimes trails the source). Forcing them into
/// paired rows therefore always drifts or merges on some audio. Instead each stream
/// is segmented into its own sentence-sized entries and they're rendered in the
/// order their first tokens arrived — interleaved by time, never paired. No lag to
/// estimate, nothing to mis-anchor: each sentence is its own row.
struct LiveDialogue: Equatable {
    /// A display row carries EITHER source OR translation (the other side empty) —
    /// the struct keeps both fields so the renderer/tests stay unchanged.
    struct Row: Equatable {
        var source: String
        var translation: String
    }

    private struct Entry: Equatable {
        var text: String = ""
        let isSource: Bool
    }

    /// A source pause this long starts a new source entry — long enough to be a
    /// sentence break, not a mid-sentence phrase pause.
    /// ponytail: speaker-dependent heuristic; raise if sentences split, lower if they merge.
    static let sourceGapMs = 1100

    private var entries: [Entry] = []        // both streams, in first-token-arrival order
    private var lastSourceMs: Int?
    private var lastSourceEndedSentence = false
    private var translationSentenceOpen = false
    private var sourceIndex = -1             // index of the open source entry in `entries`
    private var translationIndex = -1        // index of the open translation entry

    mutating func appendOriginal(_ token: String, ms: Int?) {
        // New source entry on first token, an audio pause, or a sentence end.
        if sourceIndex < 0 || isGap(ms, since: lastSourceMs) || lastSourceEndedSentence {
            entries.append(Entry(isSource: true))
            sourceIndex = entries.count - 1
        }
        entries[sourceIndex].text += token
        lastSourceEndedSentence = Self.endsSentence(token)
        if let ms { lastSourceMs = ms }
    }

    mutating func appendTranslation(_ token: String, ms: Int?) {
        // New translation entry at the start of each sentence — keeps it whole and
        // splits long output into readable per-sentence rows (no giant blocks).
        if translationIndex < 0 || !translationSentenceOpen {
            entries.append(Entry(isSource: false))
            translationIndex = entries.count - 1
            translationSentenceOpen = true
        }
        entries[translationIndex].text += token
        if Self.endsSentence(token) { translationSentenceOpen = false }
    }

    private func isGap(_ ms: Int?, since last: Int?) -> Bool {
        guard let ms, let last else { return false }
        return ms - last > Self.sourceGapMs
    }

    private static func endsSentence(_ token: String) -> Bool {
        guard let last = token.reversed().first(where: { !$0.isWhitespace }) else { return false }
        return ".!?。！？…".contains(last)
    }

    /// One row per entry, in arrival order — source rows and translation rows
    /// interleaved by time, each carrying only its own side.
    var rows: [Row] {
        entries.compactMap { e in
            let t = Self.collapseLoops(e.text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !t.isEmpty else { return nil }
            return e.isSource ? Row(source: t, translation: "") : Row(source: "", translation: t)
        }
    }

    /// All translation text joined (for Summarize).
    var translationText: String {
        entries.filter { !$0.isSource }
            .map { Self.collapseLoops($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Cosmetic only: collapse a word-group (1–6 words) the realtime model looped
    /// 3+ times in a row down to one occurrence ("ты ты ты ты"; "нам стоит уйти, нам
    /// стоит уйти, …"). Loops are model garbage on hard audio — this just stops them
    /// filling the panel. 3+ reps, so genuine emphasis ("very very") survives.
    // ponytail: O(words²·6) per entry per render; entries are sentence-sized so it's cheap.
    static func collapseLoops(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard words.count >= 3 else { return text }
        var out: [String] = []
        var i = 0
        while i < words.count {
            var collapsed = false
            var n = min(6, (words.count - i) / 2)
            while n >= 1 {
                let gram = Array(words[i ..< i + n])
                var reps = 1
                var j = i + n
                while j + n <= words.count && Array(words[j ..< j + n]) == gram { reps += 1; j += n }
                if reps >= 3 {
                    out.append(contentsOf: gram)
                    i = j
                    collapsed = true
                    break
                }
                n -= 1
            }
            if !collapsed { out.append(words[i]); i += 1 }
        }
        return out.joined(separator: " ")
    }
}

/// Which audio Live Translation listens to. One at a time — never both, to
/// avoid the same speech being transcribed twice.
enum LiveAudioSource: String, CaseIterable {
    case systemAudio
    case microphone

    var title: String {
        switch self {
        case .systemAudio: return "System audio"
        case .microphone: return "Microphone"
        }
    }

    static let defaultsKey = "liveTranslationSource"

    static var current: LiveAudioSource {
        get { LiveAudioSource(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .microphone }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}
