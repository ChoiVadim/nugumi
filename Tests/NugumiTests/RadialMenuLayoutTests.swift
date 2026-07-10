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

    func testPanelCentersOnAnchorAwayFromEdges() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = RadialMenuLayoutPolicy.panelFrame(
            anchor: NSPoint(x: 700, y: 450),
            screenVisibleFrame: screen
        )
        XCTAssertEqual(frame.midX, 700, accuracy: 0.001)
        XCTAssertEqual(frame.midY, 450, accuracy: 0.001)
    }

    func testPanelClampsInsideBottomLeftCorner() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = RadialMenuLayoutPolicy.panelFrame(
            anchor: NSPoint(x: 10, y: 10),
            screenVisibleFrame: screen
        )
        XCTAssertGreaterThanOrEqual(frame.minX, 0)
        XCTAssertGreaterThanOrEqual(frame.minY, 0)
    }

    func testPanelClampsInsideTopRightCorner() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = RadialMenuLayoutPolicy.panelFrame(
            anchor: NSPoint(x: 1430, y: 890),
            screenVisibleFrame: screen
        )
        XCTAssertLessThanOrEqual(frame.maxX, 1440)
        XCTAssertLessThanOrEqual(frame.maxY, 900)
    }

    func testEveryActionHasLabelAndSymbol() {
        for action in RadialAction.allCases {
            XCTAssertFalse(action.label.isEmpty)
            XCTAssertNotNil(NSImage(systemSymbolName: action.symbolName, accessibilityDescription: nil))
        }
    }
}
