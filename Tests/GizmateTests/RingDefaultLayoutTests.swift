import XCTest
@testable import Gizmate

/// The default ring's left slot points at the "More" folder by id, and the two
/// are persisted under different UserDefaults keys. That split is the whole risk
/// here: get it wrong and the slot silently draws nothing, which looks like the
/// ring lost a button rather than like a bug.
final class RingDefaultLayoutTests: XCTestCase {

    @MainActor
    private func store() -> (RingLayoutStore, () -> Void) {
        let suiteName = "RingDefaultLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (RingLayoutStore(defaults: defaults), {
            defaults.removePersistentDomain(forName: suiteName)
        })
    }

    /// `RingFolder.moreID` force-unwraps a string literal. This is what fails
    /// when someone mistypes it, instead of the app trapping at launch.
    func testMoreFolderIDIsAWellFormedFixedUUID() {
        XCTAssertEqual(
            RingFolder.moreID.uuidString.lowercased(),
            "6d6f7265-0000-4000-8000-000000000001"
        )
    }

    func testDefaultLayoutPutsTheMoreFolderInTheLeftSlot() {
        // Slot 5 is the left position — see `RingLayout`'s slot-order note.
        XCTAssertEqual(RingLayout.default.content(at: 5), .folder(RingFolder.moreID))
    }

    /// The indices are angles, not order: this orbit has sixteen positions at
    /// 22.5° each, counter-clockwise from "right". The folder sits in the ring's
    /// LEFT slot, so its contents belong at 180° — slot 8 — and anything at slot
    /// 0 would fan out on the far side of the ring.
    func testMoreFolderOpensOnTheSameSideAsItsButton() {
        XCTAssertEqual(RingFolder.more.layout.content(at: 8), .builtIn(.saveNote))
        XCTAssertEqual(RingFolder.more.layout.content(at: 9), .builtIn(.summarize))
        XCTAssertEqual(
            RingFolder.more.layout.content(at: 0), .empty,
            "slot 0 is dead right — the opposite side from the folder's button"
        )
    }

    /// Guards the geometry claim the slot numbers above rest on, so a change to
    /// the orbit's capacity or winding shows up here rather than as a folder
    /// that quietly opens across the ring.
    func testSlotEightIsTheLeftOfADepthOneOrbit() {
        let centers = RadialMenuLayoutPolicy.orbitSlotCenters(
            radius: 100,
            count: RingLayout.capacity(atDepth: 1)
        )
        XCTAssertEqual(centers[8].x, -100, accuracy: 0.001)
        XCTAssertEqual(centers[8].y, 0, accuracy: 0.001)
    }

    @MainActor
    func testFirstLaunchSeedsTheFolderTheDefaultLayoutReferences() {
        let (store, cleanup) = store()
        defer { cleanup() }

        XCTAssertEqual(store.layout, .default)
        XCTAssertNotNil(
            store.folder(RingFolder.moreID),
            "the default layout references this folder; nothing else supplies it"
        )
    }

    /// The end-to-end version: build the ring the way a presenter does and check
    /// the left slot actually produced a button.
    @MainActor
    func testDefaultRingBuildsAButtonInTheFolderSlot() {
        let (store, cleanup) = store()
        defer { cleanup() }

        let slots = RingBuilder.slots(
            configuration: RingConfiguration(
                layout: store.layout,
                tools: [],
                folders: store.folders
            ),
            handlers: RingActionHandlers(
                explain: {}, rewrite: {}, reply: {}, ask: {},
                capture: {}, dictate: {}, live: {},
                saveNote: RingSaveNoteOption(tags: []) { _ in }
            ),
            dismiss: {}
        )

        let folderSlot = slots[5]
        XCTAssertNotNil(folderSlot, "the More folder slot must not come back empty")
        XCTAssertEqual(folderSlot?.label, "More")
        // Summarize is in the folder too, but it is the contextual action: with
        // no `summarize` option supplied (no chat or browser in front), its slot
        // drops exactly as it does in the main ring.
        XCTAssertEqual(
            folderSlot?.subItems.compactMap { $0?.label },
            ["Note"],
            "the folder fans out to Note; Summarize needs a supported app"
        )
    }

    @MainActor
    func testResetKeepsTheFolderTheDefaultLayoutNeeds() {
        let (store, cleanup) = store()
        defer { cleanup() }

        // Arrange the ring away from the default: the folder record itself
        // survives an overwritten slot, so what reset has to restore is the
        // slot pointing back at it.
        store.assign(.builtIn(.explain), to: 5)
        XCTAssertEqual(store.layout.content(at: 5), .builtIn(.explain))

        store.resetToDefault()
        XCTAssertEqual(store.layout, .default)
        XCTAssertNotNil(store.folder(RingFolder.moreID))
    }

    @MainActor
    func testALayoutWithoutTheFolderIsNotGivenOne() {
        let suiteName = "RingDefaultLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // A ring the user already arranged, with no folder in it.
        let saved = RingLayout(slots: [
            .builtIn(.explain), .builtIn(.rewrite), .builtIn(.reply), .builtIn(.ask),
            .builtIn(.capture), .builtIn(.summarize), .builtIn(.dictate), .builtIn(.live),
        ])
        defaults.set(try! JSONEncoder().encode(saved), forKey: "ringLayout")

        let store = RingLayoutStore(defaults: defaults)
        XCTAssertEqual(store.layout, saved)
        XCTAssertTrue(store.folders.isEmpty, "seeding is for layouts that ask for the folder")
    }
}
