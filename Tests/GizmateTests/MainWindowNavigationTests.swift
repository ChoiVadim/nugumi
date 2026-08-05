import XCTest
@testable import Gizmate

final class MainWindowNavigationTests: XCTestCase {
    /// The raw value is the restored sidebar selection, so a build that
    /// renames one silently drops the user on a different screen.
    func testHomeKeepsItsPersistedRawValue() {
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

    /// Two cases must never share a raw value — the sidebar restores by it.
    func testRawValuesAreUnique() {
        let raws = MainWindowSection.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count)
    }
}
