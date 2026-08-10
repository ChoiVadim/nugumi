import AppKit
import XCTest

@testable import Gizmate

final class RadialMenuLayoutTests: XCTestCase {
    func testButtonCentersCountMatchesRequest() {
        for n in 1...8 {
            XCTAssertEqual(RadialMenuLayoutPolicy.buttonCenters(count: n).count, n)
        }
    }

    func testAllCentersSitOnTheRing() {
        for n in 1...8 {
            for offset in RadialMenuLayoutPolicy.buttonCenters(count: n) {
                let d = (offset.x * offset.x + offset.y * offset.y).squareRoot()
                XCTAssertEqual(d, RadialMenuLayoutPolicy.ringRadius, accuracy: 0.001)
            }
        }
    }

    func testButtonCentersSitOnTheRing() {
        for offset in RadialMenuLayoutPolicy.buttonCenters(count: 4) {
            let distance = (offset.x * offset.x + offset.y * offset.y).squareRoot()
            XCTAssertEqual(distance, RadialMenuLayoutPolicy.ringRadius, accuracy: 0.001)
        }
    }

    func testPanelAlwaysCentersOnAnchorEvenNearEdges() {
        // No edge clamping by design: the ring never detaches from the
        // button; near an edge part of it just falls off-screen.
        let anchors = [
            NSPoint(x: 700, y: 450),
            NSPoint(x: 10, y: 10),
            NSPoint(x: 1430, y: 890),
        ]
        for anchor in anchors {
            let frame = RadialMenuLayoutPolicy.panelFrame(anchor: anchor)
            XCTAssertEqual(frame.midX, anchor.x, accuracy: 0.001)
            XCTAssertEqual(frame.midY, anchor.y, accuracy: 0.001)
        }
    }

    func testLabelPlacementMatchesRingSide() {
        XCTAssertEqual(RadialMenuLayoutPolicy.labelPlacement(for: CGPoint(x: 0, y: 64)), .top)
        XCTAssertEqual(RadialMenuLayoutPolicy.labelPlacement(for: CGPoint(x: -64, y: 0)), .left)
        XCTAssertEqual(RadialMenuLayoutPolicy.labelPlacement(for: CGPoint(x: 64, y: 0)), .right)
        XCTAssertEqual(RadialMenuLayoutPolicy.labelPlacement(for: CGPoint(x: 0, y: -64)), .bottom)
        XCTAssertEqual(RadialMenuLayoutPolicy.labelPlacement(for: CGPoint(x: 45, y: 45)), .topRight)
        XCTAssertEqual(RadialMenuLayoutPolicy.labelPlacement(for: CGPoint(x: -45, y: 45)), .topLeft)
        XCTAssertEqual(RadialMenuLayoutPolicy.labelPlacement(for: CGPoint(x: 45, y: -45)), .bottomRight)
        XCTAssertEqual(RadialMenuLayoutPolicy.labelPlacement(for: CGPoint(x: -45, y: -45)), .bottomLeft)
    }

    // MARK: - Angular selection

    /// Three filled slots: right, bottom, top-right — the shape a ring with
    /// five empty slots actually has.
    private var sparseRing: [CGPoint] {
        RadialMenuLayoutPolicy.buttonCenters(count: 3)
    }

    func testEmptyDirectionGoesToItsNearestNeighbour() {
        // Pointing dead left, where no button lives. The bottom one (−90°) is
        // 90° away; the right one is a full 180°.
        let pick = RadialMenuLayoutPolicy.angularPick(
            cursor: CGPoint(x: -90, y: 0),
            layers: [sparseRing]
        )
        XCTAssertEqual(pick?.layer, 0)
        XCTAssertEqual(pick?.index, 1)
    }

    func testPointingAtAButtonPicksItFromAnywhereInTheBand() {
        // The disc is 46pt wide at radius 78; every one of these misses it.
        for distance in [30.0, 60.0, 110.0] {
            let pick = RadialMenuLayoutPolicy.angularPick(
                cursor: CGPoint(x: distance * cos(.pi / 4), y: distance * sin(.pi / 4)),
                layers: [sparseRing]
            )
            XCTAssertEqual(pick?.index, 2, "at \(distance)pt out")
        }
    }

    func testDeadZoneAndOuterWallPickNothing() {
        XCTAssertNil(RadialMenuLayoutPolicy.angularPick(
            cursor: CGPoint(x: 10, y: 0),
            layers: [sparseRing]
        ))
        // 152pt out is the second orbit's radius — past the wall while only
        // the ring is up, so a click there still means "dismiss".
        XCTAssertNil(RadialMenuLayoutPolicy.angularPick(
            cursor: CGPoint(x: 152, y: 0),
            layers: [sparseRing]
        ))
    }

    func testOpeningAnOrbitMovesTheWallAndSplitsTheBands() {
        let orbit = RadialMenuLayoutPolicy.orbitSlotCenters(
            radius: RadialMenuLayoutPolicy.outerRingRadius,
            count: 4
        )
        let layers = [sparseRing, orbit]
        // Same 152pt reading, now that the orbit is out there.
        XCTAssertEqual(
            RadialMenuLayoutPolicy.angularPick(cursor: CGPoint(x: 152, y: 0), layers: layers)?.layer,
            1
        )
        // The ring keeps everything inside the midpoint between the two.
        XCTAssertEqual(
            RadialMenuLayoutPolicy.angularPick(cursor: CGPoint(x: 100, y: 0), layers: layers)?.layer,
            0
        )
        XCTAssertNil(
            RadialMenuLayoutPolicy.angularPick(cursor: CGPoint(x: 220, y: 0), layers: layers)
        )
    }

    func testEveryDirectionOutsideTheDeadZonePicksSomething() {
        // The point of the whole scheme: inside the band there is no direction
        // that selects nothing, however few slots are filled.
        for filled in 1...8 {
            let ring = RadialMenuLayoutPolicy.buttonCenters(count: filled)
            for step in 0..<72 {
                let heading = Double(step) * .pi / 36
                let cursor = CGPoint(x: 90 * cos(heading), y: 90 * sin(heading))
                XCTAssertNotNil(
                    RadialMenuLayoutPolicy.angularPick(cursor: cursor, layers: [ring]),
                    "\(filled) slots, heading \(step * 5)°"
                )
            }
        }
    }

    func testDefaultRingSymbolsResolve() {
        let symbolNames = [
            "text.magnifyingglass",
            "pencil.line",
            "arrowshape.turn.up.left",
            "questionmark.bubble",
        ]
        for name in symbolNames {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil))
        }
    }

    func testRingRemoveControlAppearsOnlyForHoveredPopulatedSlot() {
        XCTAssertFalse(
            RingSlotControlVisibility.showsClearControl(
                isEmpty: false,
                isHovering: false
            )
        )
        XCTAssertTrue(
            RingSlotControlVisibility.showsClearControl(
                isEmpty: false,
                isHovering: true
            )
        )
        XCTAssertFalse(
            RingSlotControlVisibility.showsClearControl(
                isEmpty: true,
                isHovering: true
            )
        )
    }

    func testRingRemoveAccessibilityActionAppearsOnlyForPopulatedSlot() {
        XCTAssertTrue(
            RingSlotControlVisibility.showsClearAccessibilityAction(isEmpty: false)
        )
        XCTAssertFalse(
            RingSlotControlVisibility.showsClearAccessibilityAction(isEmpty: true)
        )
    }
}
