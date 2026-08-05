import XCTest
@testable import Gizmate

/// `EdgesDiagram` only draws a tile for ids that resolve to a resident
/// `DockItem` — a built-in like Explain can be docked (`BuiltInEditor` offers a
/// picker for it) with nothing to show while idle, so it sits in `DockStore`'s
/// raw list for an edge without ever getting a tile. That makes the drawn list
/// shorter than the raw one `DockStore.move` actually edits whenever the two
/// disagree, and an index computed against the drawn list names the wrong slot
/// in the raw one. Nothing before this file distinguished the two coordinate
/// spaces — `DockStoreTests` only ever drives `move` directly with indices that
/// already mean what they say.
///
/// `placeOnTop`'s tests below are the same distinction one step further: the
/// top rail's one-tile cap has to count residents, not raw entries, or it
/// evicts a `.panel` placement it was never about.
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
        ["a", "b", "c"].forEach { store.dock($0, to: .left) }

        EdgesSection.moveOntoResident("a", target: "c", edge: .left, dock: store)

        XCTAssertEqual(store.items(on: .left), ["b", "c", "a"])
    }

    // MARK: - The top rail's one-tile cap

    /// The rework's headline rule. `EdgeDockController` expands straight to
    /// `items[0]` on hover — the top dock has no tab strip — so a second
    /// resident up there was saved and then never shown again, which is most of
    /// why this screen read as broken. Dropping evicts rather than refusing:
    /// a rail that quietly declines a drop is indistinguishable from one that
    /// doesn't work.
    func testDroppingOnTopEvictsWhoeverWasAlreadyThere() {
        let store = DockStore(defaults: scratchDefaults())
        EdgesSection.placeOnTop("gizmo.clock", dock: store, residentIDs: ["gizmo.clock", "gizmo.feed"])

        EdgesSection.placeOnTop("gizmo.feed", dock: store, residentIDs: ["gizmo.clock", "gizmo.feed"])

        XCTAssertEqual(store.items(on: .top), ["gizmo.feed"])
        XCTAssertNil(store.edge(of: "gizmo.clock"), "the evicted resident goes back to the middle")
    }

    /// The reason the cap is `EdgesSection`'s and not `DockStore`'s.
    /// `placement[.top]` mixes two meanings: residents waiting on the edge, and
    /// ids whose *result panel* merely opens there. A cap enforced in the store
    /// has no way to tell them apart and would silently undo a `.panel`
    /// placement every time someone parked a surface up top.
    func testDroppingOnTopLeavesAPanelPlacementOnTheSameEdgeAlone() {
        let store = DockStore(defaults: scratchDefaults())
        store.dock("builtin.explain", to: .top)

        EdgesSection.placeOnTop("gizmo.feed", dock: store, residentIDs: ["gizmo.feed"])

        XCTAssertEqual(store.edge(of: "builtin.explain"), .top)
        XCTAssertEqual(store.items(on: .top), ["gizmo.feed", "builtin.explain"])
    }

    /// Dropping the current occupant back onto the rail it is already on must
    /// not evict it into the middle — the guard that skips `droppedID` itself.
    func testDroppingTheTopOccupantBackOnTopIsANoOp() {
        let store = DockStore(defaults: scratchDefaults())
        EdgesSection.placeOnTop("gizmo.feed", dock: store, residentIDs: ["gizmo.feed"])

        EdgesSection.placeOnTop("gizmo.feed", dock: store, residentIDs: ["gizmo.feed"])

        XCTAssertEqual(store.items(on: .top), ["gizmo.feed"])
    }
}
