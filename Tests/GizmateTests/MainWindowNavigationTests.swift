import XCTest
@testable import Gizmate

final class MainWindowNavigationTests: XCTestCase {
    /// Nothing restores the sidebar selection across launches today (see the
    /// enum's doc comment) — but raw values are cheap to keep stable, and
    /// free now is not free forever, so pin `.home`'s against a drive-by
    /// rename.
    func testHomeRawValueStaysStable() {
        XCTAssertEqual(MainWindowSection.home.rawValue, "home")
    }

    func testEdgesIsOfferedInTheSidebar() {
        XCTAssertTrue(MainWindowSection.primary.contains(.edges))
    }

    /// Every case has to answer both, or the sidebar renders a blank row.
    func testEveryCaseHasATitleAndASymbol() {
        for section in MainWindowSection.allCases {
            XCTAssertFalse(section.title.isEmpty, "\(section.rawValue) has no title")
            XCTAssertFalse(section.symbol.isEmpty, "\(section.rawValue) has no symbol")
        }
    }

    func testRingIsItsOwnSection() {
        XCTAssertTrue(MainWindowSection.primary.contains(.ring))
    }

    /// Home stays first: it is the front door now, not the ring.
    func testHomeIsStillTheLandingSection() {
        XCTAssertEqual(MainWindowSection.primary.first, .home)
    }
}
