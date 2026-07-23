import XCTest
@testable import Nugumi

final class FullDiskAccessProbeTests: XCTestCase {
    func testProbeReturnsBoolWithoutThrowing() {
        // Can't assert a fixed value (depends on machine grant state), but the
        // probe must never crash and must return deterministically twice.
        let a = FullDiskAccessProbe.isGranted()
        let b = FullDiskAccessProbe.isGranted()
        XCTAssertEqual(a, b)
    }
}
