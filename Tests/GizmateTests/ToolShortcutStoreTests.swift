import XCTest

@testable import Gizmate

/// The gizmo shortcut store keys UserDefaults through
/// `ToolRef.generated(id).storageID`, beside the built-in actions' keys. What
/// these pin: the namespaces stay disjoint, a deleted tool's binding is
/// pruned rather than inherited, and an invalid stored blob reads as "no
/// binding" instead of a key that registers and never fires.
final class ToolShortcutStoreTests: XCTestCase {
    private func scratchDefaults() -> (UserDefaults, () -> Void) {
        let suiteName = "ToolShortcutStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private let combo = GlobalShortcut(
        keyCode: 11, modifiers: [.control, .option], keyEquivalent: "b", keyDisplay: "B"
    )

    func testSetReadClearRoundTrip() {
        let (defaults, cleanup) = scratchDefaults()
        defer { cleanup() }
        let id = UUID()

        XCTAssertNil(ToolShortcutStore.shortcut(for: id, defaults: defaults))
        ToolShortcutStore.set(combo, for: id, defaults: defaults)
        XCTAssertEqual(ToolShortcutStore.shortcut(for: id, defaults: defaults), combo)
        ToolShortcutStore.clear(for: id, defaults: defaults)
        XCTAssertNil(ToolShortcutStore.shortcut(for: id, defaults: defaults))
    }

    func testAssignmentsReturnOnlyBoundIDs() {
        let (defaults, cleanup) = scratchDefaults()
        defer { cleanup() }
        let bound = UUID()
        let unbound = UUID()
        ToolShortcutStore.set(combo, for: bound, defaults: defaults)

        let assignments = ToolShortcutStore.assignments(
            ids: [bound, unbound],
            defaults: defaults
        )
        XCTAssertEqual(assignments, [bound: combo])
    }

    func testPruneDropsADeletedToolAndKeepsALiveOne() {
        let (defaults, cleanup) = scratchDefaults()
        defer { cleanup() }
        let kept = UUID()
        let deleted = UUID()
        ToolShortcutStore.set(combo, for: kept, defaults: defaults)
        ToolShortcutStore.set(combo, for: deleted, defaults: defaults)

        ToolShortcutStore.prune(keeping: [kept], defaults: defaults)

        XCTAssertEqual(ToolShortcutStore.shortcut(for: kept, defaults: defaults), combo)
        XCTAssertNil(ToolShortcutStore.shortcut(for: deleted, defaults: defaults))
    }

    func testPruneLeavesTheBuiltInActionsAlone() {
        let (defaults, cleanup) = scratchDefaults()
        defer { cleanup() }
        GlobalShortcutStore.set(combo, for: .dictate, defaults: defaults)

        ToolShortcutStore.prune(keeping: [], defaults: defaults)

        XCTAssertEqual(GlobalShortcutStore.shortcut(for: .dictate, defaults: defaults), combo)
    }

    /// A gizmo whose UUID somehow spelled an action's raw value must still land
    /// in its own namespace — the disjointness `ToolRef.storageID`'s prefix
    /// exists to guarantee. The fixture discriminates: were the prefix ever
    /// dropped, `dictate`'s key and a hypothetical bare-string tool key could
    /// collide, and this asserts the prefix is really in every tool key.
    func testToolKeysCannotCollideWithActionKeys() {
        let id = UUID()
        let toolKey = ToolShortcutStore.defaultsKey(for: id)
        XCTAssertTrue(toolKey.hasPrefix("globalShortcut.tool."))
        for action in GlobalShortcutAction.allCases {
            XCTAssertFalse(
                action.rawValue.hasPrefix("tool."),
                "\(action) would shadow the gizmo key namespace"
            )
            XCTAssertNotEqual(action.defaultsKey, toolKey)
        }
    }

    func testAnInvalidStoredBlobReadsAsNoBinding() {
        let (defaults, cleanup) = scratchDefaults()
        defer { cleanup() }
        let id = UUID()
        defaults.set(Data("junk".utf8), forKey: ToolShortcutStore.defaultsKey(for: id))
        XCTAssertNil(ToolShortcutStore.shortcut(for: id, defaults: defaults))
    }
}
