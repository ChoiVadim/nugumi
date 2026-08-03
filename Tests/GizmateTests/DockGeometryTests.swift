import AppKit
import XCTest
@testable import Gizmate

/// Pure geometry, so this is where the dock's real bugs are catchable without
/// ever opening a window. The two screens that matter are a MacBook with a
/// camera housing and everything else.
final class DockGeometryTests: XCTestCase {

    /// A 14" MacBook Pro: 1512x982 points, 74pt of notch-tall menu bar, with
    /// the housing occupying the middle 200pt.
    private let notchedFrame = NSRect(x: 0, y: 0, width: 1512, height: 982)
    private var notchedAuxLeft: NSRect { NSRect(x: 0, y: 982 - 74, width: 656, height: 74) }
    private var notchedAuxRight: NSRect { NSRect(x: 856, y: 982 - 74, width: 656, height: 74) }

    /// An external display: no housing, 24pt menu bar.
    private let plainFrame = NSRect(x: 0, y: 0, width: 2560, height: 1440)

    // MARK: - Notch

    func testNotchRectSitsBetweenTheAuxiliaryAreas() {
        let rect = DockGeometry.notchRect(
            screenFrame: notchedFrame,
            menuBarHeight: 74,
            auxLeft: notchedAuxLeft,
            auxRight: notchedAuxRight
        )

        XCTAssertEqual(rect.minX, 656)
        XCTAssertEqual(rect.maxX, 856)
        XCTAssertEqual(rect.width, 200)
        XCTAssertEqual(rect.maxY, notchedFrame.maxY)
        XCTAssertEqual(rect.height, 74)
    }

    func testScreenWithoutHousingGetsAVirtualNotch() {
        let rect = DockGeometry.notchRect(
            screenFrame: plainFrame,
            menuBarHeight: 24,
            auxLeft: nil,
            auxRight: nil
        )

        XCTAssertEqual(rect.width, DockGeometry.virtualNotchWidth)
        XCTAssertEqual(rect.midX, plainFrame.midX, "the fake notch is centred like a real one")
        XCTAssertEqual(rect.maxY, plainFrame.maxY)
        XCTAssertEqual(rect.height, 24)
    }

    func testOneAuxiliaryAreaAloneFallsBackToVirtual() {
        // Not a shape macOS reports today, but half-answers must not produce a
        // negative-width notch.
        let rect = DockGeometry.notchRect(
            screenFrame: notchedFrame,
            menuBarHeight: 74,
            auxLeft: notchedAuxLeft,
            auxRight: nil
        )

        XCTAssertEqual(rect.width, DockGeometry.virtualNotchWidth)
    }

    func testNotchIsNeverNegativeWidth() {
        // Overlapping auxiliary areas would invert the gap.
        let rect = DockGeometry.notchRect(
            screenFrame: notchedFrame,
            menuBarHeight: 74,
            auxLeft: NSRect(x: 0, y: 908, width: 900, height: 74),
            auxRight: NSRect(x: 800, y: 908, width: 712, height: 74)
        )

        XCTAssertEqual(rect.width, DockGeometry.virtualNotchWidth)
    }

    // MARK: - Reveal zones

    func testTopRevealZoneIsTheNotch() {
        let zone = DockGeometry.revealZone(
            for: .top,
            screenFrame: notchedFrame,
            menuBarHeight: 74,
            auxLeft: notchedAuxLeft,
            auxRight: notchedAuxRight
        )

        XCTAssertEqual(zone, DockGeometry.notchRect(
            screenFrame: notchedFrame,
            menuBarHeight: 74,
            auxLeft: notchedAuxLeft,
            auxRight: notchedAuxRight
        ))
    }

    func testSideRevealZonesHugTheEdgeAndAvoidTheCorners() {
        let left = DockGeometry.revealZone(
            for: .left, screenFrame: plainFrame, menuBarHeight: 24, auxLeft: nil, auxRight: nil
        )
        let right = DockGeometry.revealZone(
            for: .right, screenFrame: plainFrame, menuBarHeight: 24, auxLeft: nil, auxRight: nil
        )

        XCTAssertEqual(left.minX, plainFrame.minX)
        XCTAssertEqual(left.width, DockGeometry.revealThickness)
        XCTAssertEqual(right.maxX, plainFrame.maxX)
        XCTAssertEqual(right.width, DockGeometry.revealThickness)

        // Middle half only: the corners belong to the menu bar, the Dock and
        // every window's resize handle.
        XCTAssertEqual(left.height, plainFrame.height / 2)
        XCTAssertEqual(left.midY, plainFrame.midY)
        XCTAssertEqual(right.midY, plainFrame.midY)
    }

    // MARK: - Strip

    func testSideStripGrowsWithTabCountAndStaysCentred() {
        let one = DockGeometry.stripFrame(
            for: .right, tabCount: 1, screenFrame: plainFrame,
            menuBarHeight: 24, auxLeft: nil, auxRight: nil
        )
        let three = DockGeometry.stripFrame(
            for: .right, tabCount: 3, screenFrame: plainFrame,
            menuBarHeight: 24, auxLeft: nil, auxRight: nil
        )

        XCTAssertEqual(one.maxX, plainFrame.maxX)
        XCTAssertEqual(three.maxX, plainFrame.maxX)
        XCTAssertEqual(one.midY, plainFrame.midY)
        XCTAssertEqual(three.midY, plainFrame.midY)
        XCTAssertGreaterThan(three.height, one.height)
        XCTAssertEqual(
            three.height - one.height,
            2 * (DockGeometry.tabSize + DockGeometry.tabSpacing),
            accuracy: 0.01
        )
    }

    func testTopStripIsHorizontalUnderTheNotch() {
        let strip = DockGeometry.stripFrame(
            for: .top, tabCount: 3, screenFrame: notchedFrame,
            menuBarHeight: 74, auxLeft: notchedAuxLeft, auxRight: notchedAuxRight
        )
        let notch = DockGeometry.notchRect(
            screenFrame: notchedFrame, menuBarHeight: 74,
            auxLeft: notchedAuxLeft, auxRight: notchedAuxRight
        )

        XCTAssertGreaterThan(strip.width, strip.height)
        XCTAssertEqual(strip.midX, notch.midX, accuracy: 0.01)
        XCTAssertEqual(strip.maxY, notch.minY, accuracy: 0.01, "hangs below the notch, not over it")
    }

    // MARK: - Shape

    /// The side paths are the top path rotated, and a wrong transform shows up
    /// as a shape that no longer fills its bounds.
    func testPanelPathFillsItsBoundsOnEveryEdge() {
        let bounds = CGRect(x: 0, y: 0, width: 380, height: 520)
        for edge in DockEdge.allCases {
            let box = DockGeometry.panelPath(for: edge, in: bounds).boundingBoxOfPath
            XCTAssertEqual(box.minX, bounds.minX, accuracy: 0.5, "\(edge) minX")
            XCTAssertEqual(box.minY, bounds.minY, accuracy: 0.5, "\(edge) minY")
            XCTAssertEqual(box.maxX, bounds.maxX, accuracy: 0.5, "\(edge) maxX")
            XCTAssertEqual(box.maxY, bounds.maxY, accuracy: 0.5, "\(edge) maxY")
        }
    }

    /// The flare pulls the body in, so a point just inside the bezel corner is
    /// outside the shape while the same point further along the edge is inside.
    func testTopFlareCarvesTheCornersAndKeepsTheBezelEdge() {
        let bounds = CGRect(x: 0, y: 0, width: 380, height: 520)
        let path = DockGeometry.panelPath(for: .top, in: bounds)

        XCTAssertFalse(
            path.contains(CGPoint(x: 2, y: 500)),
            "the top-left corner is carved out by the concave arc"
        )
        XCTAssertTrue(
            path.contains(CGPoint(x: 190, y: 519)),
            "the bezel edge itself still runs the full width"
        )
        XCTAssertTrue(
            path.contains(CGPoint(x: 190, y: 260)),
            "the body is untouched"
        )
    }

    func testTabStripLengthClearsTheFlareAtBothEnds() {
        XCTAssertEqual(
            DockGeometry.stripLength(tabCount: 1),
            DockGeometry.tabSize + DockGeometry.inverseCornerRadius * 2
        )
    }

    // MARK: - Expanded

    func testExpandedPanelHugsItsEdge() {
        let size = NSSize(width: 380, height: 520)
        let right = DockGeometry.expandedFrame(
            for: .right, contentSize: size, screenFrame: plainFrame,
            visibleFrame: plainFrame.insetBy(dx: 0, dy: 24),
            menuBarHeight: 24, auxLeft: nil, auxRight: nil
        )

        XCTAssertEqual(right.maxX, plainFrame.maxX)
        XCTAssertEqual(right.width, 380)
        XCTAssertEqual(right.height, 520)
    }

    func testExpandedPanelIsClampedToWhatIsVisible() {
        let visible = NSRect(x: 0, y: 24, width: 2560, height: 1392)
        let tall = DockGeometry.expandedFrame(
            for: .right, contentSize: NSSize(width: 380, height: 9000),
            screenFrame: plainFrame, visibleFrame: visible,
            menuBarHeight: 24, auxLeft: nil, auxRight: nil
        )

        XCTAssertLessThanOrEqual(tall.height, visible.height)
        XCTAssertGreaterThanOrEqual(tall.minY, visible.minY)
        XCTAssertLessThanOrEqual(tall.maxY, visible.maxY)
    }

    func testTopExpandedPanelHangsFromTheNotch() {
        let panel = DockGeometry.expandedFrame(
            for: .top, contentSize: NSSize(width: 620, height: 260),
            screenFrame: notchedFrame,
            visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 908),
            menuBarHeight: 74, auxLeft: notchedAuxLeft, auxRight: notchedAuxRight
        )
        let notch = DockGeometry.notchRect(
            screenFrame: notchedFrame, menuBarHeight: 74,
            auxLeft: notchedAuxLeft, auxRight: notchedAuxRight
        )

        XCTAssertEqual(panel.midX, notch.midX, accuracy: 0.01)
        XCTAssertEqual(panel.maxY, notchedFrame.maxY, "tucks under the notch, sharing its top edge")
        XCTAssertEqual(panel.width, 620)
    }
}
