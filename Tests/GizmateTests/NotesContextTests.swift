import XCTest

@testable import Gizmate

/// `NotesContext` is the one place a note turns into prompt text, and it is
/// read off `UserDefaults` rather than through the store — so these drive it the
/// same way, by writing the encoded array the store would have written.
final class NotesContextTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: NotesStore.defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: NotesStore.defaultsKey)
        super.tearDown()
    }

    private func store(_ notes: [Note]) {
        let data = try! JSONEncoder().encode(notes)
        UserDefaults.standard.set(data, forKey: NotesStore.defaultsKey)
    }

    func testNoNotesLeavesThePromptUntouched() {
        XCTAssertEqual(NotesContext.appending(to: "BASE"), "BASE")
    }

    func testUntickedNotesNeverReachThePrompt() {
        store([
            Note(title: "Shipping", text: "We ship on Tuesdays.", usedAsContext: true),
            Note(title: "Groceries", text: "milk, eggs", usedAsContext: false),
        ])

        let prompt = NotesContext.appending(to: "BASE")
        XCTAssertTrue(prompt.contains("We ship on Tuesdays."))
        XCTAssertFalse(prompt.contains("milk, eggs"))
    }

    func testEveryNoteUntickedIsTheSameAsNoNotes() {
        store([Note(text: "kept out", usedAsContext: false)])
        XCTAssertEqual(NotesContext.appending(to: "BASE"), "BASE")
    }

    func testEmptyNotesAreSkipped() {
        store([Note(title: "Half-written", text: "   ", usedAsContext: true)])
        XCTAssertEqual(NotesContext.appending(to: "BASE"), "BASE")
    }

    func testTitlelessNoteIsLabelledWithItsFirstLine() {
        store([Note(text: "Deploy checklist\nrun migrations first", usedAsContext: true)])
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
                usedAsContext: true,
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
            text: String(repeating: "y", count: NotesContext.maxLength * 3),
            usedAsContext: true
        )])

        let text = NotesContext.text
        XCTAssertFalse(text.isEmpty, "the only note must not be dropped for being long")
        XCTAssertTrue(text.hasPrefix("- War and peace: "))
        XCTAssertTrue(text.hasSuffix("…"))
        XCTAssertLessThanOrEqual(text.count, NotesContext.maxLength + 1)
    }
}
