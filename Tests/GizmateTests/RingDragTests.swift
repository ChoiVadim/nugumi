import XCTest
@testable import Gizmate

/// Dragging a button is the only edit that touches two rings at once, so what
/// is worth pinning down is where a carried disc may land — and, just as much,
/// where it may not: a sub-ring filed inside itself is unreachable forever, and
/// one carried too far out has nowhere left to draw its own orbit.
final class RingDragTests: XCTestCase {

    @MainActor
    private func store() -> (RingLayoutStore, () -> Void) {
        let suiteName = "RingDragTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (RingLayoutStore(defaults: defaults), {
            defaults.removePersistentDomain(forName: suiteName)
        })
    }

    // MARK: - Across rings

    @MainActor
    func testCarryingAButtonIntoASubRingVacatesTheSlotItCameFrom() {
        let (store, cleanup) = self.store()
        defer { cleanup() }

        let folder = store.addFolder(name: "Work", symbolName: "briefcase", to: 0, in: [])
        let carried = store.layout.slots[1]
        XCTAssertNotEqual(carried, .empty)

        store.move(from: RingSlotAddress(index: 1), to: RingSlotAddress(path: [folder.id], index: 3))

        XCTAssertEqual(store.ring(at: [folder.id])?.slots[3], carried)
        XCTAssertEqual(store.layout.slots[1], .empty, "a move must not leave a copy behind")
    }

    @MainActor
    func testDroppingOnATakenSlotOfAnotherRingTradesThePairOver() {
        let (store, cleanup) = self.store()
        defer { cleanup() }

        let folder = store.addFolder(name: "Work", symbolName: "briefcase", to: 0, in: [])
        store.assign(.builtIn(.live), to: 3, in: [folder.id])
        let carried = store.layout.slots[1]

        store.move(from: RingSlotAddress(index: 1), to: RingSlotAddress(path: [folder.id], index: 3))

        XCTAssertEqual(store.ring(at: [folder.id])?.slots[3], carried)
        XCTAssertEqual(store.layout.slots[1], .builtIn(.live), "the displaced button comes back the other way")
    }

    @MainActor
    func testCarryingAButtonBackOutOfASubRingLandsItInTheMainRing() {
        let (store, cleanup) = self.store()
        defer { cleanup() }

        let folder = store.addFolder(name: "Work", symbolName: "briefcase", to: 0, in: [])
        store.assign(.builtIn(.live), to: 2, in: [folder.id])
        store.clear(4, in: [])

        store.move(from: RingSlotAddress(path: [folder.id], index: 2), to: RingSlotAddress(index: 4))

        XCTAssertEqual(store.layout.slots[4], .builtIn(.live))
        XCTAssertEqual(store.ring(at: [folder.id])?.slots[2], .empty)
    }

    @MainActor
    func testAMoveInsideOneRingIsASwap() {
        let (store, cleanup) = self.store()
        defer { cleanup() }

        let (first, second) = (store.layout.slots[1], store.layout.slots[4])

        store.move(from: RingSlotAddress(index: 1), to: RingSlotAddress(index: 4))

        XCTAssertEqual(store.layout.slots[1], second)
        XCTAssertEqual(store.layout.slots[4], first)
    }

    @MainActor
    func testTheArrangementSurvivesARestart() {
        let suiteName = "RingDragTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let folderID: UUID
        let carried: RingSlotContent
        do {
            let store = RingLayoutStore(defaults: defaults)
            let folder = store.addFolder(name: "Work", symbolName: "briefcase", to: 0, in: [])
            folderID = folder.id
            carried = store.layout.slots[1]
            store.move(from: RingSlotAddress(index: 1), to: RingSlotAddress(path: [folder.id], index: 3))
        }

        // Both halves of the move are one change: a reopened store must not find
        // the button in its old slot as well as its new one.
        let reopened = RingLayoutStore(defaults: defaults)
        XCTAssertEqual(reopened.ring(at: [folderID])?.slots[3], carried)
        XCTAssertEqual(reopened.layout.slots[1], .empty)
    }

    // MARK: - Drops that must be refused

    @MainActor
    func testASubRingCannotBeCarriedInsideItself() {
        let (store, cleanup) = self.store()
        defer { cleanup() }

        let folder = store.addFolder(name: "Work", symbolName: "briefcase", to: 0, in: [])
        let target = RingSlotAddress(path: [folder.id], index: 2)

        XCTAssertFalse(store.canMove(from: RingSlotAddress(index: 0), to: target))
        store.move(from: RingSlotAddress(index: 0), to: target)

        XCTAssertEqual(store.layout.slots[0], .folder(folder.id))
        XCTAssertEqual(store.ring(at: [folder.id])?.slots[2], .empty)
    }

    @MainActor
    func testASubRingCannotBeCarriedInsideOneOfItsOwn() {
        let (store, cleanup) = self.store()
        defer { cleanup() }

        let outer = store.addFolder(name: "Outer", symbolName: "folder", to: 0, in: [])
        let inner = store.addFolder(name: "Inner", symbolName: "folder", to: 1, in: [outer.id])

        XCTAssertFalse(
            store.canMove(from: RingSlotAddress(index: 0), to: RingSlotAddress(path: [inner.id], index: 0)),
            "filing a sub-ring inside its own child would put both out of reach"
        )
    }

    /// A sub-ring holding sub-rings needs one more orbit than an empty one, and
    /// the menu only draws three. Where it may be dropped therefore depends on
    /// what it is carrying.
    @MainActor
    func testHowDeepASubRingMayGoDependsOnWhatIsInside() {
        let (store, cleanup) = self.store()
        defer { cleanup() }

        let host = store.addFolder(name: "Host", symbolName: "tray", to: 0, in: [])
        let loaded = store.addFolder(name: "Loaded", symbolName: "folder", to: 1, in: [])
        store.addFolder(name: "Nested", symbolName: "folder", to: 0, in: [loaded.id])
        let plain = store.addFolder(name: "Plain", symbolName: "folder", to: 2, in: [])

        XCTAssertFalse(
            store.canMove(from: RingSlotAddress(index: 1), to: RingSlotAddress(path: [host.id], index: 0)),
            "its own sub-ring would need a fourth orbit"
        )
        XCTAssertTrue(
            store.canMove(from: RingSlotAddress(index: 2), to: RingSlotAddress(path: [host.id], index: 0)),
            "an empty sub-ring still has an orbit to open out there"
        )
        XCTAssertEqual(store.layout.slots[1], .folder(loaded.id))
        XCTAssertEqual(store.layout.slots[2], .folder(plain.id))
    }

    @MainActor
    func testAnEmptySlotAndASlotOffTheRingAreNeverPickedUpOrDroppedOn() {
        let (store, cleanup) = self.store()
        defer { cleanup() }

        store.clear(5, in: [])

        XCTAssertFalse(store.canMove(from: RingSlotAddress(index: 5), to: RingSlotAddress(index: 6)))
        XCTAssertFalse(store.canMove(from: RingSlotAddress(index: 0), to: RingSlotAddress(index: RingLayout.slotCount)))
        XCTAssertFalse(store.canMove(from: RingSlotAddress(index: 0), to: RingSlotAddress(index: 0)))
    }

    // MARK: - Aiming

    func testTheNearestSlotWithinReachClaimsTheCarriedDisc() {
        let candidates = [
            RingDragCandidate(address: RingSlotAddress(index: 0), center: CGPoint(x: 100, y: 0)),
            RingDragCandidate(address: RingSlotAddress(path: [UUID()], index: 4), center: CGPoint(x: 140, y: 40)),
        ]

        XCTAssertEqual(
            RingDragTargeting.nearest(to: CGPoint(x: 110, y: 8), among: candidates, snap: 48),
            candidates[0].address
        )
        XCTAssertEqual(
            RingDragTargeting.nearest(to: CGPoint(x: 132, y: 34), among: candidates, snap: 48),
            candidates[1].address
        )
    }

    func testLettingGoOverOpenSpaceLandsOnNothing() {
        let candidates = [
            RingDragCandidate(address: RingSlotAddress(index: 0), center: CGPoint(x: 100, y: 0))
        ]

        XCTAssertNil(RingDragTargeting.nearest(to: .zero, among: candidates, snap: 48))
    }

    /// Letting go has to be able to mean "never mind", so the catch areas of two
    /// orbits must not meet across the space between them.
    func testOrbitsLeaveOpenSpaceBetweenTheirCatchAreas() {
        let snap = RadialMenuLayoutPolicy.buttonDiameter * RingDragTargeting.snapFraction
        let gap = RadialMenuLayoutPolicy.outerRingRadius - RadialMenuLayoutPolicy.ringRadius

        XCTAssertLessThan(snap * 2, gap)
        XCTAssertLessThan(snap * 2, RadialMenuLayoutPolicy.thirdRingRadius - RadialMenuLayoutPolicy.outerRingRadius)
    }

    /// A click that wobbles by a pixel is still a click — the slop has to stay
    /// well under the distance to the next slot, or picking a button up would be
    /// indistinguishable from opening its picker.
    func testTheClickSlopIsSmallerThanAButton() {
        XCTAssertLessThan(RingDragTargeting.clickSlop, RadialMenuLayoutPolicy.buttonDiameter / 4)
    }
}
