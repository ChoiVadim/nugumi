import XCTest
@testable import Gizmate

final class SurfaceBindingTests: XCTestCase {
    private let row = SurfaceRow(id: "1", values: ["name": "cv.pdf", "size": "4 KB"])

    func testAKeyResolvesToItsValue() {
        XCTAssertEqual(SurfaceBinding.resolve(.key("name"), in: row), "cv.pdf")
    }

    func testALiteralIsItself() {
        XCTAssertEqual(SurfaceBinding.resolve(.literal("Downloads"), in: row), "Downloads")
    }

    /// Validation rejects a layout naming a key the rows do not have, so this
    /// is only reachable when a script's output changed after the tool was
    /// built. Empty, not "nil" or a crash: a card missing its subtitle should
    /// lose the line, not the card.
    func testAMissingKeyResolvesToNothing() {
        XCTAssertEqual(SurfaceBinding.resolve(.key("author"), in: row), "")
    }
}
