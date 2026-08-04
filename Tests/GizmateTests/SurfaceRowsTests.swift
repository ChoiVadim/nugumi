import XCTest
@testable import Gizmate

final class SurfaceRowsTests: XCTestCase {
    func testItReadsTheRowsAScriptPrinted() throws {
        let rows = try SurfaceRows.decode(stdout: #"""
        {"rows":[{"id":"1","name":"cv.pdf","path":"/tmp/cv.pdf"}]}
        """#)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "1")
        XCTAssertEqual(rows[0]["name"], "cv.pdf")
    }

    /// A script that printed a log line before its JSON is doing something
    /// reasonable, and failing it would send the model repairing a tool that
    /// works. The last line that parses wins.
    func testChatterBeforeTheJSONIsIgnored() throws {
        let rows = try SurfaceRows.decode(stdout: """
        scanning ~/Downloads
        {"rows":[{"id":"1","name":"a.txt"}]}
        """)
        XCTAssertEqual(rows.count, 1)
    }

    func testNumbersBecomeStrings() throws {
        let rows = try SurfaceRows.decode(stdout: #"{"rows":[{"id":"1","size":4096}]}"#)
        XCTAssertEqual(rows[0]["size"], "4096")
    }

    func testNestedValuesAreRejected() {
        XCTAssertThrowsError(
            try SurfaceRows.decode(stdout: #"{"rows":[{"id":"1","tags":["a"]}]}"#)
        )
    }

    /// No id means nothing survives a refresh — rows would reshuffle under the
    /// pointer. The index is a fair fallback and cheaper than failing the tool.
    func testAMissingIdFallsBackToThePosition() throws {
        let rows = try SurfaceRows.decode(stdout: #"{"rows":[{"name":"a"},{"name":"b"}]}"#)
        XCTAssertEqual(rows.map(\.id), ["0", "1"])
    }

    func testEmptyRowsAreFine() throws {
        XCTAssertEqual(try SurfaceRows.decode(stdout: #"{"rows":[]}"#), [])
    }

    func testTextThatIsNotJSONFails() {
        XCTAssertThrowsError(try SurfaceRows.decode(stdout: "Traceback (most recent call last):"))
    }

    func testMoreThanFiveHundredRowsFails() {
        let many = (0..<501).map { #"{"id":"\#($0)"}"# }.joined(separator: ",")
        XCTAssertThrowsError(try SurfaceRows.decode(stdout: #"{"rows":[\#(many)]}"#))
    }

    /// `maximumRows` has its own test above; the other three limits named in
    /// the brief (keys per row, value length, total stdout) had no coverage
    /// at all, so a row with e.g. a 10 000-byte value would have decoded
    /// clean. These close that gap.
    func testMoreThanThirtyTwoKeysOnARowFails() {
        let keys = (0..<33).map { #""k\#($0)":"v""# }.joined(separator: ",")
        XCTAssertThrowsError(try SurfaceRows.decode(stdout: #"{"rows":[{\#(keys)}]}"#))
    }

    func testAValueOverOneKilobyteFails() {
        let value = String(repeating: "a", count: 1025)
        XCTAssertThrowsError(
            try SurfaceRows.decode(stdout: #"{"rows":[{"id":"1","note":"\#(value)"}]}"#)
        )
    }

    func testStdoutOverTheByteCapFails() {
        let padding = String(repeating: "x", count: 262_144)
        XCTAssertThrowsError(
            try SurfaceRows.decode(stdout: #"{"rows":[{"id":"1","note":"\#(padding)"}]}"#)
        )
    }
}
