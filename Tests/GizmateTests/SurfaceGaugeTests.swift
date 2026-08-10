import XCTest
@testable import Gizmate

/// The two parsers a layout's `meter` and `chart` promise. Both are read by
/// the renderer and by `SurfaceLayoutCheck`, so a disagreement between them
/// would be a build that passes and a panel that draws less than it said.
final class SurfaceGaugeTests: XCTestCase {
    func testAFractionIsReadBothWaysItMayBeWritten() {
        XCTAssertEqual(SurfaceMeter.fraction(from: "0.488"), 0.488)
        XCTAssertEqual(SurfaceMeter.fraction(from: "48.8%") ?? 0, 0.488, accuracy: 0.0001)
        XCTAssertEqual(SurfaceMeter.fraction(from: " 100 % "), 1)
        XCTAssertEqual(SurfaceMeter.fraction(from: "0"), 0)
    }

    /// Refused rather than clamped. A script printing 48.8 without a `%` meant
    /// something, and a bar pinned at full would hide that it meant it wrongly
    /// — which is exactly the reading a stats panel exists to give.
    func testAFractionOutsideItsRangeIsRefused() {
        XCTAssertNil(SurfaceMeter.fraction(from: "48.8"))
        XCTAssertNil(SurfaceMeter.fraction(from: "-0.1"))
        XCTAssertNil(SurfaceMeter.fraction(from: "120%"))
        XCTAssertNil(SurfaceMeter.fraction(from: "half"))
        XCTAssertNil(SurfaceMeter.fraction(from: ""))
    }

    func testASeriesIsCommaSeparatedNumbers() {
        XCTAssertEqual(SurfaceSeries.values(from: "18,22,19.5"), [18, 22, 19.5])
        XCTAssertEqual(SurfaceSeries.values(from: " 1 , 2 "), [1, 2])
    }

    /// One point is a number, not a graph, and a row's value is capped at a
    /// kilobyte anyway — both ends are stated so the diagnostic can say which.
    func testASeriesTooShortOrTooLongOrNotNumbersIsRefused() {
        XCTAssertNil(SurfaceSeries.values(from: "42"))
        XCTAssertNil(SurfaceSeries.values(from: ""))
        XCTAssertNil(SurfaceSeries.values(from: "1,2,three"))
        XCTAssertNil(SurfaceSeries.values(from: "1,,2"))
        let tooMany = (0...SurfaceSeries.maximumCount).map(String.init).joined(separator: ",")
        XCTAssertNil(SurfaceSeries.values(from: tooMany))
    }
}
