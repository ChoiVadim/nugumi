import XCTest

@testable import Gizmate

/// The shipped-gizmo seed: installs once with a stable id, approved and
/// docked, and never fights the user about it afterwards.
@MainActor
final class DefaultToolsTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("default-tools-tests-\(UUID().uuidString)")
        suiteName = "default-tools-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        // `ToolApprovals` writes to the runner's standard defaults; the seed
        // approves, so the test cleans that up rather than leaking it into
        // every later test in the process.
        ToolApprovals.revoke(DefaultTools.macUsageID)
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeStores() -> (ToolsStore, DockStore) {
        (
            ToolsStore(directoryURL: directory, migrateLegacy: false),
            DockStore(defaults: defaults)
        )
    }

    func testAFreshInstallGetsMacUsageApprovedAndDocked() {
        let (store, dock) = makeStores()
        DefaultTools.seed(into: store, dock: dock, defaults: defaults)

        guard let tool = store.tool(id: DefaultTools.macUsageID) else {
            return XCTFail("the default tool was not installed")
        }
        XCTAssertEqual(tool.output, .surface)
        XCTAssertEqual(tool.refreshSeconds, 1)
        XCTAssertNotNil(tool.layout)
        XCTAssertEqual(store.script(for: tool.id)?.isEmpty, false)
        XCTAssertTrue(
            ToolApprovals.isApproved(tool.id, hash: store.approvalHash(for: tool)),
            "a script that shipped inside the app carries the app's own consent"
        )
        XCTAssertEqual(
            dock.edge(of: ToolRef.generated(tool.id).storageID), .right,
            "a surface living nowhere never runs, which is no default at all"
        )
    }

    func testADeletedDefaultStaysDeleted() {
        let (store, dock) = makeStores()
        DefaultTools.seed(into: store, dock: dock, defaults: defaults)
        store.delete(DefaultTools.macUsageID)

        DefaultTools.seed(into: store, dock: dock, defaults: defaults)
        XCTAssertNil(
            store.tool(id: DefaultTools.macUsageID),
            "the user answered \"do I want this\"; a launch must not re-ask"
        )
    }

    /// The machine the tool was originally built on already holds it under
    /// the same id — seeding there must change nothing, not overwrite the
    /// user's own copy of the script.
    func testAnExistingToolWithTheStableIDIsLeftAlone() {
        let (store, dock) = makeStores()
        var existing = GizmateTool(id: DefaultTools.macUsageID, name: "Mac Usage")
        existing.kind = .python
        existing.output = .surface
        existing.layout = DefaultTools.macUsageLayout
        store.save(existing, script: "print('mine')")

        DefaultTools.seed(into: store, dock: dock, defaults: defaults)
        XCTAssertEqual(store.script(for: DefaultTools.macUsageID), "print('mine')")
        XCTAssertNil(dock.edge(of: ToolRef.generated(DefaultTools.macUsageID).storageID))
    }
}
