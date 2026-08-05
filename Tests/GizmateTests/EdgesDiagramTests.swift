import XCTest
@testable import Gizmate

/// Where a point on the Edges figure lands.
///
/// This exists because the first two versions of the figure could not be
/// checked at all. Both moved a dragged tool through the pasteboard
/// (`.draggable` / `.dropDestination`), whose payload type —
/// `UTType(exportedAs: "com.nugumi.app.edge-resident")` — is declared in no
/// `Info.plist`, and under `swift run` there is no bundle to declare it in.
/// Every drag picked up and every drop silently did nothing, and no test could
/// have said so: the failure was in AppKit's type registry, not in any code
/// this repo owns.
///
/// Hit-testing by hand is what makes it checkable. `EdgesDiagram.zone` is a
/// pure function of a point and a size, so every landing the figure has is
/// reachable here without rendering a view.
final class EdgesDiagramTests: XCTestCase {
    /// Wide enough that the two rails don't meet in the middle — with a figure
    /// narrower than `sideRailWidth * 2` there is no middle to land in, and
    /// every assertion below would pass for the wrong reason.
    private let size = CGSize(width: 640, height: 400)

    private func zone(_ x: CGFloat, _ y: CGFloat, left: Int = 0, right: Int = 0) -> EdgesDiagram.Zone? {
        EdgesDiagram.zone(
            at: CGPoint(x: x, y: y), in: size, leftCount: left, rightCount: right
        )
    }

    func testTheFixtureHasAMiddleToLandIn() {
        XCTAssertGreaterThan(
            size.width, EdgesDiagram.sideRailWidth * 2 + EdgesDiagram.tileWidth,
            "a figure this narrow is all rails, and testMiddle below would pass by accident"
        )
    }

    // MARK: - Which zone

    func testTheTopBandIsTheTopRailAcrossItsWholeWidth() {
        for x in [EdgesDiagram.sideRailWidth / 2, size.width / 2, size.width - 10] {
            XCTAssertEqual(zone(x, 20), .edge(.top, 0), "x = \(x)")
        }
    }

    /// The top holds one, so there is nothing to insert in front of.
    func testTheTopRailAlwaysReportsTheOnlySlotItHas() {
        XCTAssertEqual(zone(size.width / 2, 5, left: 4, right: 4), .edge(.top, 0))
        XCTAssertEqual(zone(size.width / 2, EdgesDiagram.topRailHeight - 1), .edge(.top, 0))
    }

    func testTheSideBandsAreTheirOwnRailsAndNotEachOther() {
        XCTAssertEqual(zone(10, 200)?.edge, .left)
        XCTAssertEqual(zone(size.width - 10, 200)?.edge, .right)
        XCTAssertEqual(zone(EdgesDiagram.sideRailWidth - 1, 200)?.edge, .left)
        XCTAssertEqual(zone(size.width - EdgesDiagram.sideRailWidth + 1, 200)?.edge, .right)
    }

    func testEverythingBetweenTheRailsIsTheMiddle() {
        XCTAssertEqual(zone(size.width / 2, 200), .middle)
        XCTAssertEqual(zone(EdgesDiagram.sideRailWidth + 1, EdgesDiagram.topRailHeight + 1), .middle)
        XCTAssertEqual(zone(size.width / 2, size.height - 1), .middle)
    }

    func testAPointOffTheFigureLandsNowhere() {
        XCTAssertNil(zone(-1, 200))
        XCTAssertNil(zone(size.width + 1, 200))
        XCTAssertNil(zone(200, -1))
        XCTAssertNil(zone(200, size.height + 1))
    }

    // MARK: - Where on a rail

    /// Above the first tile is "in front of everything", however many are there.
    func testLandingAboveTheFirstTileInsertsAtTheFront() {
        XCTAssertEqual(zone(10, EdgesDiagram.railContentTop, left: 3), .edge(.left, 0))
        XCTAssertEqual(zone(10, EdgesDiagram.topRailHeight + 1, left: 3), .edge(.left, 0))
    }

    /// The half that matters: rounding, not truncating. Truncating puts every
    /// landing in front of the tile it is over, which makes dragging something
    /// to the *end* of a rail impossible — the bug this rule exists to avoid.
    func testTheBottomHalfOfATileLandsBehindIt() {
        let slot = EdgesDiagram.tileHeight + EdgesDiagram.tileSpacing
        let firstTileTop = EdgesDiagram.railContentTop

        XCTAssertEqual(zone(10, firstTileTop + slot * 0.2, left: 2), .edge(.left, 0))
        XCTAssertEqual(zone(10, firstTileTop + slot * 0.8, left: 2), .edge(.left, 1))
    }

    /// Past the last tile is the end of the list, not somewhere inside it.
    func testLandingBelowEveryTileAppends() {
        XCTAssertEqual(zone(10, size.height - 5, left: 2), .edge(.left, 2))
        XCTAssertEqual(zone(size.width - 10, size.height - 5, right: 3), .edge(.right, 3))
    }

    /// An empty rail has exactly one landing, and it is not a negative index —
    /// `EdgesSection.moveToEnd` would clamp it, but a rail reporting -1 would
    /// mean the clamp is the only thing standing between a drop and a crash.
    func testAnEmptyRailOnlyEverReportsSlotZero() {
        for y in stride(from: 0, through: size.height, by: 25) {
            guard let landed = zone(10, y), case .edge(_, let index) = landed else { continue }
            XCTAssertEqual(index, 0, "y = \(y)")
        }
    }
}
