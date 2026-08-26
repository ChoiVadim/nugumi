import AppKit
import XCTest

@testable import Gizmate

/// The pointer's shape is the only thing on screen that says a component can be
/// pressed or picked up before it is. These are the three ways the mechanism
/// behind it can silently do nothing.
@MainActor
final class CursorTrackingTests: XCTestCase {
    private func attached() throws -> (NSView, CursorTrackingView) {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        CursorTrackingView.attach(.pointingHand, to: host)
        return (host, try tracker(in: host))
    }

    private func tracker(in host: NSView) throws -> CursorTrackingView {
        try XCTUnwrap(host.subviews.compactMap { $0 as? CursorTrackingView }.first)
    }

    /// The whole reason this is a tracking area and not `.onHover`: Gizmate's
    /// panels are non-activating and the app is usually not the active one, so
    /// an area scoped to the active app would go quiet exactly where the app
    /// does its work.
    func testTheAreaIsLiveWhileTheAppIsNot() throws {
        let (_, tracker) = try attached()
        tracker.updateTrackingAreas()

        let options = tracker.trackingAreas.first?.options
        XCTAssertEqual(options?.contains(.activeAlways), true)
        XCTAssertEqual(options?.contains(.cursorUpdate), true)
    }

    /// It is described as sitting behind its content. A view that hit-tests
    /// would take the very click it exists to advertise.
    func testItNeverTakesAClick() throws {
        let (_, tracker) = try attached()
        XCTAssertNil(tracker.hitTest(NSPoint(x: 10, y: 10)))
    }

    /// Hosts are routinely still zero-sized when the tracker goes in, so the
    /// area has to re-take their bounds rather than be sized once.
    func testItGrowsIntoAHostThatHadNoSizeYet() throws {
        let host = NSView(frame: .zero)
        CursorTrackingView.attach(.openHand, to: host)
        let tracker = try tracker(in: host)
        XCTAssertEqual(tracker.frame, .zero)

        host.frame = NSRect(x: 0, y: 0, width: 200, height: 60)
        tracker.updateTrackingAreas()
        XCTAssertEqual(tracker.frame, host.bounds)
    }

    /// `viewDidMoveToWindow` fires more than once, so attaching has to be
    /// idempotent or a long-lived button stacks trackers for its whole life.
    func testAttachingAgainLeavesOne() throws {
        let (host, _) = try attached()
        CursorTrackingView.attach(.pointingHand, to: host)
        CursorTrackingView.attach(.pointingHand, to: host)
        XCTAssertEqual(host.subviews.compactMap { $0 as? CursorTrackingView }.count, 1)
    }
}
