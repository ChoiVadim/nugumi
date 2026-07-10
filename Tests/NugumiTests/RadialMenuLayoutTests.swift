import AppKit
import XCTest

@testable import Nugumi

final class RadialMenuLayoutTests: XCTestCase {
    func testOneButtonCenterPerAction() {
        XCTAssertEqual(
            RadialMenuLayoutPolicy.buttonCenters().count,
            RadialAction.allCases.count
        )
    }

    func testButtonCentersSitOnTheRing() {
        for offset in RadialMenuLayoutPolicy.buttonCenters() {
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
    }

    func testEveryActionHasLabelAndSymbol() {
        for action in RadialAction.allCases {
            XCTAssertFalse(action.label.isEmpty)
            XCTAssertNotNil(NSImage(systemSymbolName: action.symbolName, accessibilityDescription: nil))
        }
    }
}
