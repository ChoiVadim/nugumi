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
}
