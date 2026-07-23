import AppKit
import XCTest

@testable import Nugumi

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
}
