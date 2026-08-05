import XCTest
@testable import Gizmate

/// `EdgesSectionContent.edgeCard` only draws a row for ids that resolve to a
/// resident `DockItem` — a built-in like Explain can be docked (`BuiltInEditor`
/// offers a control for it) with nothing to show while idle, so it sits in
/// `DockStore`'s raw list for an edge without ever getting a row. That makes
/// the rendered list shorter than the raw one `DockStore.move` actually edits
/// whenever the two disagree, and an index computed against the rendered list
/// names the wrong slot in the raw one. Nothing before this file distinguished
/// the two coordinate spaces — `DockStoreTests` only ever drives `move`
/// directly with indices that already mean what they say.
@MainActor
final class EdgesSectionTests: XCTestCase {
    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "EdgesSectionTests.\(UUID().uuidString)")!
    }

    /// The reviewer's traced case: dropping a resident onto another resident's
    /// row while a docked-but-not-resident id (Explain) sits between them and
    /// the front of the raw list. `target`'s position has to be resolved in
    /// the raw list, not counted among the two rows a card would actually
    /// draw — indexing by rendered position lands on 1, which the post-
    /// removal clamp turns into a no-op: the drag would visibly do nothing.
    func testDroppingOntoAResidentRowIgnoresAnInterveningNonResident() {
        let store = DockStore(defaults: scratchDefaults())
        store.dock("builtin.explain", to: .right)
        store.dock("builtin.saveNote", to: .right)
        store.dock("gizmo.foo", to: .right)

        EdgesSection.moveOntoResident("builtin.saveNote", target: "gizmo.foo", edge: .right, dock: store)

        XCTAssertEqual(store.items(on: .right), ["builtin.explain", "gizmo.foo", "builtin.saveNote"])
    }

    /// Same failure mode at the append zone: a card with two rendered rows
    /// but three raw entries has to append past all three, not past the two
    /// it draws — undercounting by the hidden entry lands the drop one short
    /// of the true end.
    func testAppendingPastTheLastRowCountsTheRawListNotTheRenderedOne() {
        let store = DockStore(defaults: scratchDefaults())
        store.dock("builtin.explain", to: .left)
        store.dock("builtin.saveNote", to: .left)
        store.dock("gizmo.foo", to: .left)

        EdgesSection.moveToEnd("gizmo.bar", edge: .left, dock: store)

        XCTAssertEqual(
            store.items(on: .left),
            ["builtin.explain", "builtin.saveNote", "gizmo.foo", "gizmo.bar"]
        )
    }

    /// The plain case both functions have to keep working: no non-resident in
    /// the way, drag and drop behave exactly like `DockStoreTests`' own
    /// forward-move case.
    func testMovingAResidentWithNoInterveningNonResidentStillLandsWhereAsked() {
        let store = DockStore(defaults: scratchDefaults())
        ["a", "b", "c"].forEach { store.dock($0, to: .top) }

        EdgesSection.moveOntoResident("a", target: "c", edge: .top, dock: store)

        XCTAssertEqual(store.items(on: .top), ["b", "c", "a"])
    }
}
