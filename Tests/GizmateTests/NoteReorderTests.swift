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

    @MainActor
    private func seeded(_ store: NotesStore) -> [UUID] {
        ["a", "b", "c", "d"].map { store.add(title: $0).id }
    }

    @MainActor
    private func titles(_ store: NotesStore) -> [String] {
        store.notes.map(\.title)
    }

    @MainActor
    func testNotesKeepTheOrderTheyWereMadeIn() {
        let (store, cleanup) = store()
        defer { cleanup() }
        _ = seeded(store)

        // Editing the oldest note must not float it anywhere.
        store.update(store.notes[0].id, text: "edited")
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
