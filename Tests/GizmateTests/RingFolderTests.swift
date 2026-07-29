import XCTest
@testable import Gizmate

/// Folders are the only ring content that nests, so the things worth pinning
/// down are the recursion, the orbit ceiling, and what deleting one takes with
/// it — the parts where a bug silently loses the user's arrangement.
final class RingFolderTests: XCTestCase {

    // MARK: - Helpers

    @MainActor
    private func store() -> (RingLayoutStore, () -> Void) {
        let suiteName = "RingFolderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (RingLayoutStore(defaults: defaults), {
            defaults.removePersistentDomain(forName: suiteName)
        })
    }

    /// Every built-in available, so a slot is only ever dropped for a reason
    /// the test is actually about.
    private var allHandlers: RingActionHandlers {
        RingActionHandlers(
            explain: {}, rewrite: {}, reply: {}, ask: {},
            capture: {}, dictate: {}, live: {}
        )
    }

    private func configuration(root: RingLayout, folders: [RingFolder]) -> RingConfiguration {
        RingConfiguration(layout: root, tools: [], folders: folders, context: .empty)
    }

    /// Sub-item labels with the gaps left in, which is the whole point of the
    /// `.slots` layout.
    private func labels(_ items: [RingItem?]?) -> [String?] {
        (items ?? []).map { $0?.label }
    }

    // MARK: - Building

    @MainActor
    func testFolderBecomesExpandableButtonCarryingItsRing() {
        let child = RingFolder(
            name: "Writing",
            symbolName: "pencil",
            layout: RingLayout(slots: [.builtIn(.rewrite), .builtIn(.reply)])
        )
        let items = RingBuilder.slots(
            configuration: configuration(root: RingLayout(slots: [.folder(child.id)]), folders: [child]),
            handlers: allHandlers,
            dismiss: {}
        )

        let folderItem = try? XCTUnwrap(items.first ?? nil)
        XCTAssertEqual(folderItem?.label, "Writing")
        XCTAssertEqual(folderItem?.subLayout, .slots)
        // The orbit outside the ring holds more than the ring does.
        XCTAssertEqual(folderItem?.subItems.count, RingLayout.capacity(atDepth: 1))
        XCTAssertEqual(labels(folderItem?.subItems).prefix(2).map { $0 }, ["Rewrite", "Reply"])
    }

    /// A folder's orbit is a ring drawn on the same eight directions, so an
    /// empty slot has to stay a gap — otherwise every button shifts the moment
    /// a neighbour is cleared, which is exactly what the root ring refuses to do.
    @MainActor
    func testFolderKeepsEmptySlotsSoButtonsStayWhereTheyWerePut() {
        let child = RingFolder(
            name: "Mixed",
            symbolName: "folder",
            layout: RingLayout(slots: [.empty, .builtIn(.ask), .empty, .builtIn(.capture)])
        )
        let items = RingBuilder.slots(
            configuration: configuration(root: RingLayout(slots: [.folder(child.id)]), folders: [child]),
            handlers: allHandlers,
            dismiss: {}
        )

        var expected = [String?](repeating: nil, count: RingLayout.capacity(atDepth: 1))
        expected[1] = "Ask"
        expected[3] = "Capture"
        XCTAssertEqual(labels(items.first??.subItems), expected)
    }

    /// The point of the bigger slot counts: an orbit is further out, so it fits
    /// more buttons at the *same* gap between neighbours as the main ring. If
    /// this drifts, the outer rings start looking sparse or crowded.
    func testOrbitsHoldTheirButtonsTheSameDistanceApartAsTheRing() {
        let ringChord = neighbourDistance(
            RadialMenuLayoutPolicy.buttonCenters(count: RingLayout.slotCount)
                .sorted { atan2($0.y, $0.x) < atan2($1.y, $1.x) }
        )
        let orbits: [(radius: CGFloat, depth: Int)] = [
            (RadialMenuLayoutPolicy.outerRingRadius, 1),
            (RadialMenuLayoutPolicy.thirdRingRadius, 2),
        ]

        for orbit in orbits {
            let count = RingLayout.capacity(atDepth: orbit.depth)
            let centers = RadialMenuLayoutPolicy.orbitSlotCenters(radius: orbit.radius, count: count)
            XCTAssertEqual(centers.count, count)
            for center in centers {
                XCTAssertEqual(hypot(center.x, center.y), orbit.radius, accuracy: 0.001)
            }
            XCTAssertEqual(neighbourDistance(centers), ringChord, accuracy: 1.5)
        }
    }

    /// Slot 0 of every ring points right, so the orbits share the ring's axes
    /// instead of arriving at some arbitrary rotation.
    func testEveryOrbitStartsOnTheRingsFirstDirection() {
        let first = RadialMenuLayoutPolicy.orbitSlotCenters(
            radius: RadialMenuLayoutPolicy.outerRingRadius,
            count: RingLayout.capacity(atDepth: 1)
        ).first
        XCTAssertEqual(first?.y ?? .nan, 0, accuracy: 0.001)
        XCTAssertGreaterThan(first?.x ?? 0, 0)
    }

    /// Centre-to-centre distance between two adjacent positions.
    private func neighbourDistance(_ centers: [CGPoint]) -> CGFloat {
        guard centers.count > 1 else { return 0 }
        return hypot(centers[1].x - centers[0].x, centers[1].y - centers[0].y)
    }

    /// A folder you have only just made has nothing in it yet. Dropping its
    /// button would read as the folder having been lost.
    @MainActor
    func testEmptyFolderStillGetsAButtonThatCloses() {
        var dismissed = false
        let child = RingFolder(name: "Empty", symbolName: "folder", layout: RingLayout(slots: []))
        let items = RingBuilder.slots(
            configuration: configuration(root: RingLayout(slots: [.folder(child.id)]), folders: [child]),
            handlers: allHandlers,
            dismiss: { dismissed = true }
        )

        let item = items.first ?? nil
        XCTAssertEqual(item?.label, "Empty")
        // Eight slots, all of them gaps — so there is nothing to expand into.
        XCTAssertEqual(item?.expandsOnHover, false)
        // The menu then treats it as an ordinary button, so its handler must
        // not be the no-op that would eat the click.
        item?.handler()
        XCTAssertTrue(dismissed)
    }

    @MainActor
    func testDanglingFolderReferenceLeavesItsSlotEmpty() {
        let items = RingBuilder.slots(
            configuration: configuration(root: RingLayout(slots: [.folder(UUID())]), folders: []),
            handlers: allHandlers,
            dismiss: {}
        )

        XCTAssertNil(items.first ?? nil)
    }

    // MARK: - The orbit ceiling

    /// The menu draws three orbits. A folder one level in still has an orbit to
    /// fan into; a folder two levels in does not, and must not render a button
    /// that would open nothing.
    @MainActor
    func testNestingStopsWhereTheThirdOrbitEnds() {
        let deepest = RingFolder(
            name: "Deepest",
            symbolName: "folder",
            layout: RingLayout(slots: [.builtIn(.explain)])
        )
        let middle = RingFolder(
            name: "Middle",
            symbolName: "folder",
            layout: RingLayout(slots: [.builtIn(.ask), .folder(deepest.id)])
        )
        let top = RingFolder(
            name: "Top",
            symbolName: "folder",
            layout: RingLayout(slots: [.folder(middle.id)])
        )
        let items = RingBuilder.slots(
            configuration: configuration(
                root: RingLayout(slots: [.folder(top.id)]),
                folders: [top, middle, deepest]
            ),
            handlers: allHandlers,
            dismiss: {}
        )

        // Orbit 1: Top. Orbit 2: Middle. Orbit 3: Middle's contents — where
        // `deepest` would need a fourth orbit, so only Ask survives.
        let orbit2 = items.first??.subItems
        XCTAssertEqual(labels(orbit2).compactMap { $0 }, ["Middle"])

        let orbit3 = (orbit2?.first ?? nil)?.subItems
        XCTAssertEqual(labels(orbit3).compactMap { $0 }, ["Ask"])
        // Slot 1 of `middle` holds `deepest`; it has nowhere left to fan into,
        // so it stays a gap rather than becoming a button that opens nothing.
        XCTAssertNil(orbit3?[safe: 1] ?? nil)
    }

    func testFolderIsOfferedOnlyWhileAnOrbitRemains() {
        XCTAssertTrue(RingFolderDepth.allowsFolder(at: []))
        XCTAssertTrue(RingFolderDepth.allowsFolder(at: [UUID()]))
        XCTAssertFalse(RingFolderDepth.allowsFolder(at: [UUID(), UUID()]))
    }

    // MARK: - Store

    @MainActor
    func testAssignAndClearApplyToTheRingAtThePath() {
        let (store, cleanup) = self.store()
        defer { cleanup() }

        let folder = store.addFolder(name: "Work", symbolName: "briefcase", to: 0, in: [])
        let rootBefore = store.layout.slots
        store.assign(.builtIn(.ask), to: 3, in: [folder.id])

        XCTAssertEqual(store.ring(at: [folder.id])?.slots[3], .builtIn(.ask))
        // The write landed one level down: the root ring is untouched, including
        // its own default Ask — which a per-slot check would have missed.
        XCTAssertEqual(store.layout.slots, rootBefore)

        store.clear(3, in: [folder.id])
        XCTAssertEqual(store.ring(at: [folder.id])?.slots[3], .empty)
    }

    @MainActor
    func testDeletingAFolderTakesItsNestedFoldersAndEverySlotReferenceWithIt() {
        let (store, cleanup) = self.store()
        defer { cleanup() }

        let outer = store.addFolder(name: "Outer", symbolName: "folder", to: 0, in: [])
        let inner = store.addFolder(name: "Inner", symbolName: "folder", to: 1, in: [outer.id])
        // A second root folder also pointing at `inner` proves the sweep covers
        // every ring, not just the one being deleted.
        let sibling = store.addFolder(name: "Sibling", symbolName: "folder", to: 2, in: [])
        store.assign(.folder(inner.id), to: 0, in: [sibling.id])

        store.removeFolder(outer.id)

        XCTAssertNil(store.folder(outer.id))
        XCTAssertNil(store.folder(inner.id), "a nested folder must not outlive its parent")
        XCTAssertEqual(store.layout.slots[0], .empty)
        XCTAssertEqual(store.ring(at: [sibling.id])?.slots[0], .empty)
        XCTAssertNotNil(store.folder(sibling.id), "an unrelated folder must survive")
    }

    @MainActor
    func testDeletingAToolVacatesItInsideFoldersToo() {
        let (store, cleanup) = self.store()
        defer { cleanup() }

        let toolID = UUID()
        let folder = store.addFolder(name: "Scripts", symbolName: "folder", to: 0, in: [])
        store.assign(.tool(toolID), to: 1, in: [folder.id])
        store.assign(.tool(toolID), to: 4, in: [])

        store.removeTool(toolID)

        XCTAssertEqual(store.ring(at: [folder.id])?.slots[1], .empty)
        XCTAssertEqual(store.layout.slots[4], .empty)
    }

    @MainActor
    func testPathTruncatesAtTheFirstFolderThatIsGone() {
        let (store, cleanup) = self.store()
        defer { cleanup() }

        let outer = store.addFolder(name: "Outer", symbolName: "folder", to: 0, in: [])
        let inner = store.addFolder(name: "Inner", symbolName: "folder", to: 0, in: [outer.id])
        XCTAssertEqual(store.sanitized([outer.id, inner.id]), [outer.id, inner.id])

        store.removeFolder(outer.id)
        XCTAssertEqual(store.sanitized([outer.id, inner.id]), [])
    }

    // MARK: - Persistence

    /// Folders live in their own defaults key precisely so a ring saved before
    /// they existed still decodes. Guard that shape.
    func testLayoutSavedBeforeFoldersExistedStillDecodes() throws {
        let json = #"{"slots":[{"builtIn":{"_0":"explain"}},{"empty":{}},{"tool":{"_0":"\#(UUID().uuidString)"}}]}"#
        let layout = try JSONDecoder().decode(RingLayout.self, from: Data(json.utf8))

        XCTAssertEqual(layout.slots.count, RingLayout.slotCount)
        XCTAssertEqual(layout.slots[0], .builtIn(.explain))
        XCTAssertEqual(layout.slots[1], .empty)
    }

    func testFolderRoundTripsThroughCoding() throws {
        let folder = RingFolder(
            name: "Work",
            symbolName: "briefcase",
            layout: RingLayout(slots: [.builtIn(.ask), .folder(UUID())])
        )
        let decoded = try JSONDecoder().decode(
            RingFolder.self,
            from: JSONEncoder().encode(folder)
        )

        XCTAssertEqual(decoded, folder)
    }

    @MainActor
    func testFoldersSurviveARestart() {
        let suiteName = "RingFolderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let folderID: UUID
        do {
            let store = RingLayoutStore(defaults: defaults)
            let folder = store.addFolder(name: "Work", symbolName: "briefcase", to: 0, in: [])
            store.assign(.builtIn(.ask), to: 0, in: [folder.id])
            folderID = folder.id
        }

        let reopened = RingLayoutStore(defaults: defaults)
        XCTAssertEqual(reopened.layout.slots[0], .folder(folderID))
        XCTAssertEqual(reopened.folder(folderID)?.name, "Work")
        XCTAssertEqual(reopened.ring(at: [folderID])?.slots[0], .builtIn(.ask))
    }
}
