import Combine
import Foundation

/// A folder notes are filed under. Referenced by id rather than by name, so
/// renaming one keeps every note that was in it.
struct NoteTag: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    /// SF Symbol the ring's Note orbit wears for this tag. The ring draws the
    /// glyph alone — the name is already in the hover callout, and a word
    /// squeezed into a 44pt disc reads worse than an icon at any length.
    /// `nil` is a tag the user never picked one for.
    var symbol: String?

    init(id: UUID = UUID(), name: String, symbol: String? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
    }

    /// What the ring draws for a tag with no icon of its own.
    static let fallbackSymbol = "tag"

    var ringSymbol: String { symbol ?? Self.fallbackSymbol }

    /// The tag gizmos file into when nothing chose one for them.
    ///
    /// Fixed rather than looked up by name, for the same reason
    /// `RingFolder.moreID` is: the user can rename this tag, and a lookup by
    /// name would quietly stop finding it the moment they did. Deleting it is
    /// still allowed — gizmo notes then arrive untagged, which is the honest
    /// outcome and needs no special case.
    static let otherID = UUID(uuidString: "6F746865-0000-4000-8000-000000000001")!
    static let personalID = UUID(uuidString: "70657273-0000-4000-8000-000000000001")!
    static let workID = UUID(uuidString: "776F726B-0000-4000-8000-000000000001")!

    /// What a fresh install starts with. Editable afterwards — this is a
    /// starting point, not a fixed vocabulary.
    static let defaults: [NoteTag] = [
        NoteTag(id: personalID, name: "Personal", symbol: "person"),
        NoteTag(id: workID, name: "Work", symbol: "briefcase"),
        NoteTag(id: otherID, name: "Other", symbol: "tray"),
    ]
}

/// One thing the user kept: a free-text note, optionally handed to gizmos as
/// background.
///
/// `title` is optional because the "Save to notes" gizmo has no chance to ask
/// for one — it saves whatever was selected and lets the first line stand in.
struct Note: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var text: String
    /// Which tag this note is filed under. `nil` is untagged — where notes
    /// saved before tags existed live, and where a note lands when its tag is
    /// deleted. Untagged notes show under All and nowhere else.
    var tagID: UUID?
    /// Whether this note is handed to gizmos that opted into notes context.
    /// On by default: a note the user bothered to save is usually background
    /// they want the model to have. The tick exists to exclude the scratch ones,
    /// not to make every note opt in one by one.
    var usedAsContext: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "",
        text: String = "",
        tagID: UUID? = nil,
        usedAsContext: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.tagID = tagID
        self.usedAsContext = usedAsContext
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// What the list shows and what labels the note in a prompt: the title the
    /// user wrote, or the first line of the body standing in for one.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Note.leadingLine(of: text) : trimmed
    }

    /// A note with nothing in it is a row the user is still filling in — never
    /// worth saving into a prompt.
    var isUsable: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// First line, clipped to something that fits a row and a prompt label.
    static func leadingLine(of text: String) -> String {
        let line = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return line.count <= 60 ? line : String(line.prefix(60)) + "…"
    }

    // Lenient decoding, same reasoning as `Snippet` and `GizmateTool`: a field
    // added in a later version must not throw away every note already saved.
    private enum CodingKeys: String, CodingKey {
        case id, title, text, tagID, usedAsContext, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        // Absent in every note saved before tags existed — untagged is exactly
        // what those notes are.
        tagID = try c.decodeIfPresent(UUID.self, forKey: .tagID)
        usedAsContext = try c.decodeIfPresent(Bool.self, forKey: .usedAsContext) ?? true
        let created = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        createdAt = created
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? created
    }
}

/// The user's notes. Same `@Published` + `onChange` contract as `SnippetsStore`,
/// so the UI binds the same way.
///
// ponytail: UserDefaults, exactly like snippets. Fine into the hundreds of KB;
// a plist is rewritten whole on every save, so if notes ever grow to hold
// pasted articles this moves to a JSON file under `GizmatePaths` — a swap of
// `load`/`save` and nothing else.
@MainActor
final class NotesStore: ObservableObject {
    @Published private(set) var notes: [Note] = []
    /// The tabs notes are filed under, in display order. Kept in its own
    /// defaults key so the notes array keeps decoding exactly as it did before
    /// tags existed.
    @Published private(set) var tags: [NoteTag] = []
    var onChange: (() -> Void)?

    /// `nonisolated` because `NotesContext` reads the same keys off the main
    /// actor, while assembling a prompt.
    nonisolated static let defaultsKey = "notes"
    nonisolated static let tagsKey = "noteTags"

    private let defaults: UserDefaults

    /// Injectable so tests can exercise tag deletion — which orphans notes —
    /// against a scratch suite rather than the user's real notes.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Notes

    @discardableResult
    func add(title: String = "", text: String = "", tagID: UUID? = nil) -> Note {
        let note = Note(title: title, text: text, tagID: tagID)
        notes.append(note)
        save()
        onChange?()
        return note
    }

    /// `tagID` is double-wrapped so "leave it alone" and "clear it" stay
    /// distinguishable — a plain `UUID?` cannot say the second one.
    func update(
        _ id: UUID,
        title: String? = nil,
        text: String? = nil,
        tagID: UUID?? = nil,
        usedAsContext: Bool? = nil
    ) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        if let title { notes[idx].title = title }
        if let text { notes[idx].text = text }
        if let tagID { notes[idx].tagID = tagID }
        if let usedAsContext { notes[idx].usedAsContext = usedAsContext }
        notes[idx].updatedAt = Date()
        save()
        onChange?()
    }

    /// Puts `id` where `targetID` currently sits, the way dragging one card
    /// onto another reads.
    ///
    /// Both indices are looked up in the whole array rather than in whatever
    /// tag tab is on screen: a filtered list is a subsequence of this one, so
    /// moving inside the filter has to land in the same place here or the two
    /// orders drift apart the moment the tab changes.
    ///
    /// Removing before inserting is what makes a downward drag land *after* the
    /// target and an upward one *before* it — everything past the old position
    /// has shifted left by one, so the same index means two different things
    /// depending on the direction, which is exactly the two behaviours wanted.
    func move(_ id: UUID, toPositionOf targetID: UUID) {
        guard id != targetID,
              let from = notes.firstIndex(where: { $0.id == id }),
              let to = notes.firstIndex(where: { $0.id == targetID })
        else { return }
        let note = notes.remove(at: from)
        notes.insert(note, at: min(to, notes.count))
        save()
        onChange?()
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        save()
        onChange?()
    }

    func notes(taggedWith tagID: UUID?) -> [Note] {
        guard let tagID else { return notes }
        return notes.filter { $0.tagID == tagID }
    }

    // MARK: - Tags

    @discardableResult
    func addTag(named name: String, symbol: String? = nil) -> NoteTag {
        let tag = NoteTag(name: name, symbol: symbol)
        tags.append(tag)
        saveTags()
        onChange?()
        return tag
    }

    /// Renaming on its own keeps whatever icon the tag already had.
    func renameTag(_ id: UUID, to name: String) {
        updateTag(id, name: name, symbol: tag(id)?.symbol)
    }

    /// Name and icon travel together: the editor row commits both at once, and
    /// an empty symbol is "no icon of its own", not the string "".
    func updateTag(_ id: UUID, name: String, symbol: String?) {
        guard let idx = tags.firstIndex(where: { $0.id == id }) else { return }
        tags[idx].name = name
        tags[idx].symbol = (symbol?.isEmpty ?? true) ? nil : symbol
        saveTags()
        onChange?()
    }

    /// Deleting a tag keeps its notes and leaves them untagged, where they are
    /// still reachable under All. Throwing away the user's text because they
    /// reorganised their folders would be the wrong trade by a wide margin.
    func deleteTag(_ id: UUID) {
        tags.removeAll { $0.id == id }
        for idx in notes.indices where notes[idx].tagID == id {
            notes[idx].tagID = nil
        }
        saveTags()
        save()
        onChange?()
    }

    func tag(_ id: UUID?) -> NoteTag? {
        guard let id else { return nil }
        return tags.first { $0.id == id }
    }

    // MARK: - Persistence

    private func load() {
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([Note].self, from: data) {
            notes = decoded
        }
        if let data = defaults.data(forKey: Self.tagsKey),
           let decoded = try? JSONDecoder().decode([NoteTag].self, from: data) {
            tags = decoded
        } else {
            // No key at all means a first run rather than "the user deleted
            // every tag" — that case writes an empty array and is respected.
            tags = NoteTag.defaults
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private func saveTags() {
        guard let data = try? JSONEncoder().encode(tags) else { return }
        defaults.set(data, forKey: Self.tagsKey)
    }
}

/// The master switch for handing notes to models and scripts. Per-gizmo
/// `usesNotes` and the per-note tick decide *which* notes go where; this is the
/// user's one lever to stop all of it at once, from Settings.
enum NotesAccess {
    static let defaultsKey = "gizmosReadNotesEnabled"
    /// On by default: the per-note tick already defaults each note in, and
    /// shipping the toggle off would silently break every gizmo built before
    /// it existed.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }
}

/// The ticked notes as prompt text.
///
/// Reads `UserDefaults` directly rather than taking a `NotesStore`, exactly as
/// `UserAboutContext` does: prompts are assembled deep inside `TranslationMode`
/// and `AgentToolRunner`, and threading a main-actor store down to both would
/// cost more plumbing than the decode costs microseconds.
enum NotesContext {
    /// Total budget across all notes. The ticks already decide *which* notes go
    /// in; this is the backstop against one pasted article eating the context on
    /// its own.
    static let maxLength = 4_000
    /// Below this there is no room left for a note worth reading, so the loop
    /// stops rather than appending a two-word stub.
    private static let minimumEntryLength = 80

    /// One note as consumers see it: the folder resolved to a name, the text
    /// untouched. Encodable because the python file is these records verbatim;
    /// a `nil` folder encodes as no key at all.
    struct Record: Encodable {
        let title: String
        let text: String
        let folder: String?
        let updatedAt: Date
    }

    /// Every note allowed into context, newest first. Empty when the master
    /// switch is off — the one gate both the prompt text and the python file
    /// pass through.
    static func records() -> [Record] {
        guard NotesAccess.isEnabled else { return [] }
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: NotesStore.defaultsKey),
              let notes = try? JSONDecoder().decode([Note].self, from: data)
        else { return [] }

        // An absent tags key is a first run, not "no folders": the store
        // resolves it to the default set, so folder names must too.
        let tags: [NoteTag]
        if let tagData = defaults.data(forKey: NotesStore.tagsKey),
           let decoded = try? JSONDecoder().decode([NoteTag].self, from: tagData) {
            tags = decoded
        } else {
            tags = NoteTag.defaults
        }
        let folderNames = Dictionary(
            tags.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )

        return notes
            .filter { $0.usedAsContext && $0.isUsable }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { note in
                Record(
                    title: note.displayTitle,
                    text: note.text,
                    folder: note.tagID.flatMap { folderNames[$0] },
                    updatedAt: note.updatedAt
                )
            }
    }

    /// Ticked notes, most recently edited first, one per line, the folder named
    /// in brackets. Empty when nothing is ticked — which keeps "notes off"
    /// genuinely zero-cost.
    static var text: String {
        var lines: [String] = []
        var used = 0
        for record in records() {
            let remaining = maxLength - used
            guard remaining >= minimumEntryLength else { break }
            let body = record.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let folder = record.folder.map { "[\($0)] " } ?? ""
            let line = "- \(folder)\(record.title): \(body)"
            // Clipped rather than skipped, so the newest note always makes it in
            // even when it is longer than the whole budget.
            let entry = line.count <= remaining ? line : String(line.prefix(remaining)) + "…"
            lines.append(entry)
            used += entry.count
        }
        return lines.joined(separator: "\n")
    }

    /// The same records as JSON, for a python gizmo's `GIZMO_NOTES_FILE`.
    /// `nil` when there is nothing to hand over, so no file gets written at all
    /// and a script learns to treat the variable as optional.
    static func fileData() -> Data? {
        let records = records()
        guard !records.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(records)
    }

    /// Appends the notes section to a prompt. Returns the prompt unchanged when
    /// nothing is ticked, so an empty set stays byte-for-byte what it was.
    static func appending(to prompt: String) -> String {
        let notes = text
        guard !notes.isEmpty else { return prompt }
        return prompt + """


        Notes the user saved, most recent first. A leading [name] is the folder the note is filed in:
        \(notes)

        Treat these as background facts about the user and their work, and use them only where they are relevant to the request. Do not mention, list, or summarize these notes in the output unless the request explicitly asks about them.
        """
    }
}
