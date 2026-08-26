import XCTest

@testable import Gizmate

/// `NotesContext` is the one place a note turns into prompt text, and it is
/// read off `UserDefaults` rather than through the store — so these drive it the
/// same way, by writing the encoded array the store would have written.
final class NotesContextTests: XCTestCase {
    // These run against the developer's real UserDefaults.standard, so every
    // key touched is saved here and put back in tearDown — deleting someone's
    // actual notes to test prompt text would be quite the trade.
    private var savedValues: [String: Any?] = [:]
    private let touchedKeys = [
        NotesStore.defaultsKey, NotesStore.tagsKey, NotesAccess.defaultsKey,
    ]

    override func setUp() {
        super.setUp()
        for key in touchedKeys {
            savedValues[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        // Absent tags mean the default folder set; tests that want "no folder
        // names at all" write their own empty array.
        storeTags([])
    }

    override func tearDown() {
        for key in touchedKeys {
            if let value = savedValues[key] ?? nil {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    private func store(_ notes: [Note]) {
        let data = try! JSONEncoder().encode(notes)
        UserDefaults.standard.set(data, forKey: NotesStore.defaultsKey)
    }

    private func storeTags(_ tags: [NoteTag]) {
        let data = try! JSONEncoder().encode(tags)
        UserDefaults.standard.set(data, forKey: NotesStore.tagsKey)
    }

    func testNoNotesLeavesThePromptUntouched() {
        XCTAssertEqual(NotesContext.appending(to: "BASE"), "BASE")
    }

    func testEveryUsableNoteReachesThePrompt() {
        store([
            Note(title: "Shipping", text: "We ship on Tuesdays."),
            Note(title: "Groceries", text: "milk, eggs"),
        ])

        let prompt = NotesContext.appending(to: "BASE")
        XCTAssertTrue(prompt.contains("We ship on Tuesdays."))
        XCTAssertTrue(prompt.contains("milk, eggs"))
    }

    func testEmptyNotesAreSkipped() {
        store([Note(title: "Half-written", text: "   ")])
        XCTAssertEqual(NotesContext.appending(to: "BASE"), "BASE")
    }

    func testTitlelessNoteIsLabelledWithItsFirstLine() {
        store([Note(text: "Deploy checklist\nrun migrations first")])
        XCTAssertTrue(NotesContext.text.hasPrefix("- Deploy checklist: "))
    }

    func testMostRecentlyEditedComesFirst() {
        let old = Date(timeIntervalSince1970: 1_000)
        let recent = Date(timeIntervalSince1970: 2_000)
        store([
            Note(text: "older", createdAt: old, updatedAt: old),
            Note(text: "newer", createdAt: recent, updatedAt: recent),
        ])

        let lines = NotesContext.text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("newer"))
        XCTAssertTrue(lines[1].contains("older"))
    }

    func testTotalIsCappedAndTheNewestNoteStillGetsIn() {
        // Three notes that individually fit but together blow the budget.
        let size = NotesContext.maxLength / 2
        let notes = (0..<3).map { index in
            Note(
                title: "note\(index)",
                text: String(repeating: "x", count: size),
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        store(notes)

        let text = NotesContext.text
        XCTAssertLessThanOrEqual(text.count, NotesContext.maxLength + 8)
        // Newest first, so note2 is the one that survives the cap in full.
        XCTAssertTrue(text.hasPrefix("- note2: "))
        XCTAssertFalse(text.contains("- note0: "))
    }

    func testASingleOversizeNoteIsClippedRatherThanDropped() {
        store([Note(
            title: "War and peace",
            text: String(repeating: "y", count: NotesContext.maxLength * 3)
        )])

        let text = NotesContext.text
        XCTAssertFalse(text.isEmpty, "the only note must not be dropped for being long")
        XCTAssertTrue(text.hasPrefix("- War and peace: "))
        XCTAssertTrue(text.hasSuffix("…"))
        XCTAssertLessThanOrEqual(text.count, NotesContext.maxLength + 1)
    }

    // MARK: - Folders

    func testFolderNameLeadsTheLineInBrackets() {
        let tag = NoteTag(name: "Clients")
        storeTags([tag])
        store([Note(title: "Acme", text: "Ships on Fridays.", tagID: tag.id)])
        XCTAssertTrue(NotesContext.text.hasPrefix("- [Clients] Acme: "))
    }

    func testUntaggedNoteKeepsThePlainLine() {
        storeTags([NoteTag(name: "Clients")])
        store([Note(title: "Loose", text: "no folder")])
        XCTAssertTrue(NotesContext.text.hasPrefix("- Loose: "))
    }

    func testDeletedTagRendersAsUntagged() {
        storeTags([])
        store([Note(title: "Orphan", text: "tag is gone", tagID: UUID())])
        XCTAssertTrue(NotesContext.text.hasPrefix("- Orphan: "))
    }

    func testAbsentTagsKeyResolvesTheDefaultFolderNames() {
        // A first run never wrote the tags key, but the store shows Work — so
        // the context must name it too.
        UserDefaults.standard.removeObject(forKey: NotesStore.tagsKey)
        store([Note(title: "Standup", text: "daily at ten", tagID: NoteTag.workID)])
        XCTAssertTrue(NotesContext.text.hasPrefix("- [Work] Standup: "))
    }

    // MARK: - The master switch

    func testMasterSwitchOffSilencesEveryConsumer() {
        storeTags([NoteTag(name: "Clients")])
        store([Note(title: "Secret", text: "nothing gets out")])
        UserDefaults.standard.set(false, forKey: NotesAccess.defaultsKey)

        XCTAssertTrue(NotesContext.records().isEmpty)
        XCTAssertEqual(NotesContext.text, "")
        XCTAssertEqual(NotesContext.appending(to: "BASE"), "BASE")
        XCTAssertNil(NotesContext.fileData())
    }

    func testMasterSwitchDefaultsOn() {
        XCTAssertTrue(NotesAccess.isEnabled)
    }

    // MARK: - Records and the python file

    func testRecordsCarryFolderAndComeNewestFirst() {
        let tag = NoteTag(name: "Work")
        storeTags([tag])
        let old = Date(timeIntervalSince1970: 1_000)
        let recent = Date(timeIntervalSince1970: 2_000)
        store([
            Note(title: "Older", text: "first", createdAt: old, updatedAt: old),
            Note(title: "Newer", text: "second", tagID: tag.id, createdAt: recent, updatedAt: recent),
        ])

        let records = NotesContext.records()
        XCTAssertEqual(records.map(\.title), ["Newer", "Older"])
        XCTAssertEqual(records[0].folder, "Work")
        XCTAssertNil(records[1].folder)
        XCTAssertEqual(records[0].updatedAt, recent)
    }

    func testFileDataIsNilWhenNothingIsShared() {
        XCTAssertNil(NotesContext.fileData())
    }

    func testFileDataOmitsTheFolderKeyForUntaggedNotes() throws {
        let tag = NoteTag(name: "Work")
        storeTags([tag])
        store([
            Note(title: "Filed", text: "in a folder", tagID: tag.id,
                 updatedAt: Date(timeIntervalSince1970: 2_000)),
            Note(title: "Loose", text: "no folder",
                 updatedAt: Date(timeIntervalSince1970: 1_000)),
        ])

        let data = try XCTUnwrap(NotesContext.fileData())
        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0]["folder"] as? String, "Work")
        XCTAssertNil(decoded[1]["folder"])
        // ISO 8601, so a script can parse it with no format guessing.
        XCTAssertEqual(decoded[0]["updatedAt"] as? String, "1970-01-01T00:33:20Z")
    }
}
