import UniformTypeIdentifiers
import XCTest

@testable import Gizmate

/// Dragging a card onto another one moves it there. The direction of the drag
/// decides whether "there" means before or after the target, and that falls out
/// of removing before inserting — which is exactly the kind of index arithmetic
/// that is right in one direction and off by one in the other.
final class NoteReorderTests: XCTestCase {

    @MainActor
    private func store() -> (NotesStore, () -> Void) {
        let suiteName = "NoteReorderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (NotesStore(defaults: defaults), {
            defaults.removePersistentDomain(forName: suiteName)
        })
    }

    /// Ids in list order, top to bottom. A new note lands on top, so the seed
    /// is added last-to-first for the list to read a, b, c, d.
    @MainActor
    private func seeded(_ store: NotesStore) -> [UUID] {
        for title in ["d", "c", "b", "a"] { store.add(title: title) }
        return store.notes.map(\.id)
    }

    @MainActor
    private func titles(_ store: NotesStore) -> [String] {
        store.notes.map(\.title)
    }

    @MainActor
    func testANewNoteGoesOnTop() {
        let (store, cleanup) = store()
        defer { cleanup() }
        _ = seeded(store)

        store.add(title: "new")
        XCTAssertEqual(titles(store), ["new", "a", "b", "c", "d"])
    }

    @MainActor
    func testEditingANoteDoesNotMoveIt() {
        let (store, cleanup) = store()
        defer { cleanup() }
        _ = seeded(store)

        // Editing the bottom note must not float it anywhere.
        store.update(store.notes[3].id, text: "edited")
        XCTAssertEqual(titles(store), ["a", "b", "c", "d"])
    }

    @MainActor
    func testDraggingDownLandsAfterTheTarget() {
        let (store, cleanup) = store()
        defer { cleanup() }
        let ids = seeded(store)

        store.move(ids[0], toPositionOf: ids[2])
        XCTAssertEqual(titles(store), ["b", "c", "a", "d"])
    }

    @MainActor
    func testDraggingUpLandsBeforeTheTarget() {
        let (store, cleanup) = store()
        defer { cleanup() }
        let ids = seeded(store)

        store.move(ids[3], toPositionOf: ids[1])
        XCTAssertEqual(titles(store), ["a", "d", "b", "c"])
    }

    /// A card dragged over itself, and one dragged over a note that has since
    /// been deleted: both have to leave the list exactly as it was.
    @MainActor
    func testMovesThatNameNothingAreNoOps() {
        let (store, cleanup) = store()
        defer { cleanup() }
        let ids = seeded(store)

        store.move(ids[1], toPositionOf: ids[1])
        store.move(ids[1], toPositionOf: UUID())
        store.move(UUID(), toPositionOf: ids[1])
        XCTAssertEqual(titles(store), ["a", "b", "c", "d"])
    }

    /// The payload decides which view the drop lands on. Anything textual is
    /// taken by the title field or the body text view sitting in front of the
    /// card, which is how a reorder ended up typing UUIDs into a note.
    func testTheDragCarriesNothingATextViewWouldTake() {
        let provider = NoteReorderPayload.provider(for: UUID())

        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.data.identifier))
        for textual in [UTType.plainText, .utf8PlainText, .text, .rtf, .url, .fileURL] {
            XCTAssertFalse(
                provider.hasItemConformingToTypeIdentifier(textual.identifier),
                "\(textual.identifier) is a type an editor accepts"
            )
        }
    }

    @MainActor
    func testTheNewOrderSurvivesAReload() {
        let suiteName = "NoteReorderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = NotesStore(defaults: defaults)
        let ids = seeded(store)
        store.move(ids[3], toPositionOf: ids[0])

        XCTAssertEqual(NotesStore(defaults: defaults).notes.map(\.title), ["d", "a", "b", "c"])
    }
}
