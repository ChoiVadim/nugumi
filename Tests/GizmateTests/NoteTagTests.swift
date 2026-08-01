import XCTest

@testable import Gizmate

/// Tags are referenced by id, seeded on first run, and deletable — the three
/// places a note can silently go missing.
final class NoteTagTests: XCTestCase {

    @MainActor
    private func store() -> (NotesStore, () -> Void) {
        let suiteName = "NoteTagTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (NotesStore(defaults: defaults), {
            defaults.removePersistentDomain(forName: suiteName)
        })
    }

    /// `NoteTag.otherID` force-unwraps a string literal, and gizmos file into
    /// it. This fails on a typo instead of the app trapping at launch.
    func testFixedTagIDsAreWellFormed() {
        XCTAssertEqual(NoteTag.otherID.uuidString.lowercased(), "6f746865-0000-4000-8000-000000000001")
        XCTAssertEqual(NoteTag.personalID.uuidString.lowercased(), "70657273-0000-4000-8000-000000000001")
        XCTAssertEqual(NoteTag.workID.uuidString.lowercased(), "776f726b-0000-4000-8000-000000000001")
    }

    @MainActor
    func testFirstRunSeedsTheThreeStartingTags() {
        let (store, cleanup) = store()
        defer { cleanup() }

        XCTAssertEqual(store.tags.map(\.name), ["Personal", "Work", "Other"])
        XCTAssertNotNil(store.tag(NoteTag.otherID), "gizmos file into this one by id")
    }

    /// A user who deletes every tag must not have them grow back on relaunch —
    /// which is what a plain `isEmpty` check for seeding would do.
    @MainActor
    func testDeletingEveryTagSticksAcrossAReload() {
        let suiteName = "NoteTagTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = NotesStore(defaults: defaults)
        for tag in store.tags { store.deleteTag(tag.id) }
        XCTAssertTrue(store.tags.isEmpty)

        let reloaded = NotesStore(defaults: defaults)
        XCTAssertTrue(reloaded.tags.isEmpty, "an empty tag list is a choice, not a missing key")
    }

    @MainActor
    func testRenamingATagKeepsItsNotes() {
        let (store, cleanup) = store()
        defer { cleanup() }

        store.add(text: "quarterly numbers", tagID: NoteTag.workID)
        store.renameTag(NoteTag.workID, to: "Job")

        XCTAssertEqual(store.tag(NoteTag.workID)?.name, "Job")
        XCTAssertEqual(store.notes(taggedWith: NoteTag.workID).map(\.text), ["quarterly numbers"])
    }

    /// The one that matters: reorganising folders must never destroy text.
    @MainActor
    func testDeletingATagKeepsItsNotesAndUntagsThem() {
        let (store, cleanup) = store()
        defer { cleanup() }

        store.add(text: "keep me", tagID: NoteTag.workID)
        store.deleteTag(NoteTag.workID)

        XCTAssertEqual(store.notes.map(\.text), ["keep me"])
        XCTAssertNil(store.notes[0].tagID, "an orphaned note falls back to untagged")
        XCTAssertEqual(
            store.notes(taggedWith: nil).count, 1,
            "and stays reachable under All"
        )
    }

    @MainActor
    func testAllTabReturnsEveryNoteWhateverItsTag() {
        let (store, cleanup) = store()
        defer { cleanup() }

        store.add(text: "a", tagID: NoteTag.personalID)
        store.add(text: "b", tagID: NoteTag.workID)
        store.add(text: "c")

        XCTAssertEqual(store.notes(taggedWith: nil).count, 3)
        XCTAssertEqual(store.notes(taggedWith: NoteTag.personalID).map(\.text), ["a"])
    }

    /// `update` takes a double-optional so "leave the tag alone" and "clear it"
    /// stay distinguishable. Both directions are easy to get backwards.
    @MainActor
    func testUpdateLeavesTheTagAloneUnlessAsked() {
        let (store, cleanup) = store()
        defer { cleanup() }

        let note = store.add(text: "x", tagID: NoteTag.workID)

        store.update(note.id, text: "y")
        XCTAssertEqual(store.notes[0].tagID, NoteTag.workID, "editing the body must not unfile it")

        store.update(note.id, tagID: .some(nil))
        XCTAssertNil(store.notes[0].tagID)
    }

    /// Notes saved before tags existed have no `tagID` key at all.
    func testNotesSavedBeforeTagsDecodeAsUntagged() throws {
        let legacy = """
        [{"id":"\(UUID().uuidString)","title":"t","text":"body",
          "usedAsContext":true,
          "createdAt":0,"updatedAt":0}]
        """
        let decoded = try JSONDecoder().decode([Note].self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].tagID)
    }
}
