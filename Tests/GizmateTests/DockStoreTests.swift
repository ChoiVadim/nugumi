import XCTest
@testable import Gizmate

/// The store's whole job is "one item, at most one edge, remembered across
/// launches", so what is worth pinning is that docking somewhere new really
/// vacates the old edge and that an id nothing resolves any more disappears
/// rather than sitting there as a tab that opens nothing.
final class DockStoreTests: XCTestCase {

    @MainActor
    private func store() -> (DockStore, UserDefaults, () -> Void) {
        let suiteName = "DockStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (DockStore(defaults: defaults), defaults, {
            defaults.removePersistentDomain(forName: suiteName)
        })
    }

    @MainActor
    func testFreshStoreIsEmpty() {
        let (store, _, cleanup) = store()
        defer { cleanup() }

        XCTAssertTrue(store.items(on: .top).isEmpty)
        XCTAssertNil(store.edge(of: "notes"))
    }

    @MainActor
    func testDockingPlacesItemOnEdge() {
        let (store, _, cleanup) = store()
        defer { cleanup() }

        store.dock("notes", to: .right)

        XCTAssertEqual(store.items(on: .right), ["notes"])
        XCTAssertEqual(store.edge(of: "notes"), .right)
    }

    @MainActor
    func testMovingItemVacatesTheOldEdge() {
        let (store, _, cleanup) = store()
        defer { cleanup() }

        store.dock("notes", to: .right)
        store.dock("notes", to: .top)

        XCTAssertTrue(store.items(on: .right).isEmpty)
        XCTAssertEqual(store.items(on: .top), ["notes"])
        XCTAssertEqual(store.edge(of: "notes"), .top)
    }

    @MainActor
    func testDockingNilUndocks() {
        let (store, _, cleanup) = store()
        defer { cleanup() }

        store.dock("notes", to: .left)
        store.dock("notes", to: nil)

        XCTAssertNil(store.edge(of: "notes"))
        XCTAssertTrue(store.items(on: .left).isEmpty)
    }

    @MainActor
    func testOrderIsDockOrder() {
        let (store, _, cleanup) = store()
        defer { cleanup() }

        store.dock("notes", to: .right)
        store.dock("weather", to: .right)

        XCTAssertEqual(store.items(on: .right), ["notes", "weather"])
    }

    @MainActor
    func testPlacementSurvivesReload() {
        let (store, defaults, cleanup) = store()
        defer { cleanup() }

        let id = ToolRef.builtIn(.saveNote).storageID
        store.dock(id, to: .top)
        let reloaded = DockStore(defaults: defaults)

        XCTAssertEqual(reloaded.items(on: .top), [id])
    }

    @MainActor
    func testPruneDropsUnknownIDs() {
        let (store, _, cleanup) = store()
        defer { cleanup() }

        store.dock("notes", to: .right)
        store.dock("deleted-gizmo", to: .right)
        store.prune(keeping: ["notes"])

        XCTAssertEqual(store.items(on: .right), ["notes"])
    }

    @MainActor
    func testPruneNotifiesOnlyWhenSomethingWentAway() {
        let (store, _, cleanup) = store()
        defer { cleanup() }

        store.dock("notes", to: .right)
        var changes = 0
        store.onChange = { changes += 1 }

        store.prune(keeping: ["notes"])
        XCTAssertEqual(changes, 0, "nothing was dropped, so nobody should be told to rebuild")

        store.prune(keeping: [])
        XCTAssertEqual(changes, 1)
    }

    // MARK: - Key migration

    @MainActor
    func testLegacyNotesKeyMigratesToTheBuiltInNoteAction() {
        let (_, defaults, cleanup) = store()
        defer { cleanup() }

        defaults.set(["right": ["notes"]], forKey: DockStore.defaultsKey)
        let loaded = DockStore(defaults: defaults)

        XCTAssertEqual(loaded.items(on: .right), [ToolRef.builtIn(.saveNote).storageID])
    }

    @MainActor
    func testLegacyBareUUIDMigratesToAGeneratedRef() {
        let (_, defaults, cleanup) = store()
        defer { cleanup() }

        let id = UUID()
        defaults.set(["left": [id.uuidString]], forKey: DockStore.defaultsKey)
        let loaded = DockStore(defaults: defaults)

        XCTAssertEqual(loaded.items(on: .left), [ToolRef.generated(id).storageID])
    }

    @MainActor
    func testMigrationIsWrittenBackSoItRunsOnce() {
        let (_, defaults, cleanup) = store()
        defer { cleanup() }

        defaults.set(["right": ["notes"]], forKey: DockStore.defaultsKey)
        _ = DockStore(defaults: defaults)
        let raw = defaults.dictionary(forKey: DockStore.defaultsKey) as? [String: [String]]

        XCTAssertEqual(raw?["right"], [ToolRef.builtIn(.saveNote).storageID])
    }

    @MainActor
    func testAlreadyMigratedKeysAreLeftAlone() {
        let (_, defaults, cleanup) = store()
        defer { cleanup() }

        let already = ToolRef.builtIn(.ask).storageID
        defaults.set(["top": [already]], forKey: DockStore.defaultsKey)
        let loaded = DockStore(defaults: defaults)

        XCTAssertEqual(loaded.items(on: .top), [already])
    }

    @MainActor
    func testStorageIDRoundTrips() {
        let id = UUID()
        XCTAssertEqual(ToolRef(storageID: ToolRef.generated(id).storageID), .generated(id))
        XCTAssertEqual(ToolRef(storageID: ToolRef.builtIn(.live).storageID), .builtIn(.live))
        XCTAssertEqual(ToolRef(storageID: ToolRef.folderHub.storageID), .folderHub)
        XCTAssertNil(ToolRef(storageID: "notes"))
    }

    @MainActor
    func testUnknownEdgeInDefaultsIsIgnoredRatherThanFatal() {
        let (_, defaults, cleanup) = store()
        defer { cleanup() }

        defaults.set(["bottom": ["notes"], "right": ["weather"]], forKey: DockStore.defaultsKey)
        let loaded = DockStore(defaults: defaults)

        XCTAssertEqual(loaded.items(on: .right), ["weather"])
        XCTAssertNil(loaded.edge(of: "notes"))
    }

    // MARK: - Reordering

    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "DockStoreTests.\(UUID().uuidString)")!
    }

    @MainActor
    func testMoveInsertsAtTheRequestedIndex() {
        let store = DockStore(defaults: scratchDefaults())
        store.dock("a", to: .right)
        store.dock("b", to: .right)
        store.move("c", to: .right, at: 1)
        XCTAssertEqual(store.items(on: .right), ["a", "c", "b"])
    }

    /// The case remove-then-insert gets wrong: every index after the removed one
    /// shifts down, so a naive implementation lands one short.
    @MainActor
    func testMovingAnItemForwardWithinItsOwnEdgeLandsWhereAsked() {
        let store = DockStore(defaults: scratchDefaults())
        ["a", "b", "c"].forEach { store.dock($0, to: .right) }
        store.move("a", to: .right, at: 2)
        XCTAssertEqual(store.items(on: .right), ["b", "c", "a"])
    }

    @MainActor
    func testMovingAnItemBackwardWithinItsOwnEdgeLandsWhereAsked() {
        let store = DockStore(defaults: scratchDefaults())
        ["a", "b", "c"].forEach { store.dock($0, to: .right) }
        store.move("c", to: .right, at: 0)
        XCTAssertEqual(store.items(on: .right), ["c", "a", "b"])
    }

    @MainActor
    func testMovingBetweenEdgesLeavesTheOldOne() {
        let store = DockStore(defaults: scratchDefaults())
        store.dock("a", to: .left)
        store.dock("b", to: .right)
        store.move("a", to: .right, at: 0)
        XCTAssertEqual(store.items(on: .left), [])
        XCTAssertEqual(store.items(on: .right), ["a", "b"])
    }

    /// An index past the end is a drop below the last row, which is a normal
    /// gesture, not a programming error.
    @MainActor
    func testAnIndexPastTheEndAppends() {
        let store = DockStore(defaults: scratchDefaults())
        store.dock("a", to: .right)
        store.move("b", to: .right, at: 99)
        XCTAssertEqual(store.items(on: .right), ["a", "b"])
    }

    @MainActor
    func testMoveSurvivesAReload() {
        let defaults = scratchDefaults()
        let store = DockStore(defaults: defaults)
        ["a", "b"].forEach { store.dock($0, to: .top) }
        store.move("b", to: .top, at: 0)
        XCTAssertEqual(DockStore(defaults: defaults).items(on: .top), ["b", "a"])
    }
    // MARK: - How a tool's dock closes

    /// Defaults come from the edge, because that is a fact about the shape of
    /// the thing: the notch is a glance, the sides are somewhere you work. Only
    /// an explicit choice overrides it, so nobody's dock changes under them.
    @MainActor
    func testAToolInheritsItsEdgesHabitUntilToldOtherwise() {
        let store = DockStore(defaults: scratchDefaults())
        store.dock("gizmo.feed", to: .top)
        store.dock("gizmo.notes", to: .left)

        XCTAssertEqual(store.dismissal(of: "gizmo.feed"), .autoHide)
        XCTAssertEqual(store.dismissal(of: "gizmo.notes"), .pinned)
    }

    /// The whole reason this moved off the edge: an edge holds several tools
    /// and they do not all want the same thing.
    @MainActor
    func testTwoToolsOnOneEdgeCanDisagree() {
        let store = DockStore(defaults: scratchDefaults())
        store.dock("builtin.ask", to: .left)
        store.dock("builtin.saveNote", to: .left)

        store.setDismissal(.autoHide, of: "builtin.saveNote")

        XCTAssertEqual(store.dismissal(of: "builtin.ask"), .pinned)
        XCTAssertEqual(store.dismissal(of: "builtin.saveNote"), .autoHide)
    }

    @MainActor
    func testAnExplicitChoiceSurvivesARelaunch() {
        let suite = "DockStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = DockStore(defaults: defaults)
        store.dock("builtin.ask", to: .top)
        store.setDismissal(.pinned, of: "builtin.ask")

        XCTAssertEqual(DockStore(defaults: defaults).dismissal(of: "builtin.ask"), .pinned)
    }

    /// Absent means "whatever this edge does", so choosing that explicitly has
    /// to clear the entry rather than freeze today's default in place — and a
    /// tool dragged to another edge then picks up that edge's habit instead of
    /// carrying a choice it never made.
    @MainActor
    func testChoosingTheEdgesOwnHabitStoresNothing() {
        let suite = "DockStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DockStore(defaults: defaults)
        store.dock("builtin.ask", to: .left)

        store.setDismissal(.autoHide, of: "builtin.ask")
        store.setDismissal(.pinned, of: "builtin.ask")

        let raw = defaults.dictionary(forKey: DockStore.dismissalsDefaultsKey) as? [String: String]
        XCTAssertEqual(raw ?? [:], [:])
        XCTAssertEqual(store.dismissal(of: "builtin.ask"), .pinned)
    }

    /// A tool that sits nowhere still has to answer, because `staysOpen` asks
    /// before checking anything else. Pinned is the safe half: a panel that
    /// waits can always be closed, one that vanishes cannot be brought back.
    @MainActor
    func testAToolOnNoEdgeAnswersPinned() {
        XCTAssertEqual(
            DockStore(defaults: scratchDefaults()).dismissal(of: "gizmo.nowhere"), .pinned
        )
    }

    @MainActor
    func testAnUnreadableModeFallsBackRatherThanThrowingTheRestAway() {
        let suite = "DockStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            ["builtin.ask": "sideways", "builtin.saveNote": "autoHide"],
            forKey: DockStore.dismissalsDefaultsKey
        )
        let store = DockStore(defaults: defaults)
        store.dock("builtin.ask", to: .left)

        XCTAssertEqual(store.dismissal(of: "builtin.ask"), .pinned, "unreadable falls back")
        XCTAssertEqual(store.dismissal(of: "builtin.saveNote"), .autoHide)
    }

    @MainActor
    func testAWriteThatChangesNothingDoesNotRebuildEveryDock() {
        let store = DockStore(defaults: scratchDefaults())
        store.dock("builtin.ask", to: .left)
        var calls = 0
        store.onChange = { calls += 1 }

        store.setDismissal(.autoHide, of: "builtin.ask")
        store.setDismissal(.autoHide, of: "builtin.ask")

        XCTAssertEqual(calls, 1)
    }

}
