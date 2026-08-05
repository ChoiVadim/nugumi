import XCTest
@testable import Gizmate

final class SurfaceCardTests: XCTestCase {
    func testAPresentNonEmptyValueResolves() {
        let row = SurfaceRow(id: "1", values: ["path": "/tmp/a.txt"])
        XCTAssertEqual(SurfaceCard.path(for: "path", in: row), "/tmp/a.txt")
    }

    /// The bug this closes (I2): `URL(fileURLWithPath: "")` resolves to the
    /// process's working directory, and `NSItemProvider(contentsOf:)` hands
    /// out a live provider for it. Treating an empty value as "no path"
    /// rather than "the path is empty" is what keeps a stale row from
    /// dragging out the volume root.
    func testAnEmptyValueResolvesToNilNotAnEmptyString() {
        let row = SurfaceRow(id: "1", values: ["path": ""])
        XCTAssertNil(SurfaceCard.path(for: "path", in: row))
    }

    func testAMissingKeyResolvesToNil() {
        let row = SurfaceRow(id: "1", values: [:])
        XCTAssertNil(SurfaceCard.path(for: "path", in: row))
    }
}
