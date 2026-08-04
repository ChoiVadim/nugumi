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
    /// works. The last line that parses wins. Trailing lines after the JSON
    /// (a "done" message, a stray newline) are what actually exercise the
    /// backward walk's skip — with the JSON as the true last line, the scan
    /// would match on its first try and never look at anything else.
    func testChatterBeforeTheJSONIsIgnored() throws {
        let rows = try SurfaceRows.decode(stdout: """
        scanning ~/Downloads
        still scanning...
        {"rows":[{"id":"1","name":"a.txt"}]}
        cleanup complete
        goodbye
        """)
        XCTAssertEqual(rows.count, 1)
    }

    func testNumbersBecomeStrings() throws {
        let rows = try SurfaceRows.decode(stdout: #"{"rows":[{"id":"1","size":4096}]}"#)
        XCTAssertEqual(rows[0]["size"], "4096")
    }

    /// Pinned to the specific case, not just "it throws": an array has to
    /// report `.valueNotAString`, not `.valueTooLong` — the two send a
    /// repairing model down completely different, and for this case wrong,
    /// paths. See `SurfaceRowsError.valueNotAString`.
    func testNestedValuesAreRejected() {
        XCTAssertThrowsError(
            try SurfaceRows.decode(stdout: #"{"rows":[{"id":"1","tags":["a"]}]}"#)
        ) { error in
            guard case SurfaceRowsError.valueNotAString(let key, let kind) = error else {
                XCTFail("expected .valueNotAString, got \(error)")
                return
            }
            XCTAssertEqual(key, "tags")
            XCTAssertEqual(kind, "an array")
        }
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

    /// The padding lives in leading chatter, not inside a row's value — put
    /// it in a `"note"` field instead and `maximumValueBytes` (1024) would
    /// throw `.valueTooLong` first, at 256x under this test's padding size,
    /// and the test would pass even with the stdout cap deleted. Pinning
    /// `.tooMany` is what proves the cap fired rather than some other guard —
    /// and it is the case that actually tells a repairing model what to do:
    /// this stdout is genuinely valid JSON, just too much of it, so `.notJSON`
    /// would send it hunting for a syntax bug that was never there.
    func testStdoutOverTheByteCapFails() {
        let chatter = String(repeating: "x", count: SurfaceRows.maximumStdoutBytes)
        let stdout = chatter + "\n" + #"{"rows":[{"id":"1","name":"a"}]}"#
        XCTAssertThrowsError(try SurfaceRows.decode(stdout: stdout)) { error in
            guard case SurfaceRowsError.tooMany = error else {
                XCTFail("expected .tooMany, got \(error)")
                return
            }
        }
    }

    func testBooleansBecomeTrueOrFalse() throws {
        let rows = try SurfaceRows.decode(stdout: #"{"rows":[{"id":"1","active":true,"archived":false}]}"#)
        XCTAssertEqual(rows[0]["active"], "true")
        XCTAssertEqual(rows[0]["archived"], "false")
    }
}
