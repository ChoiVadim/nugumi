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
}
