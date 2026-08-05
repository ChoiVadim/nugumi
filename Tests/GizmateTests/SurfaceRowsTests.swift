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

    /// `ForEach(rows, id: \.id)` requires unique ids — two rows sharing one
    /// have to fall back to position for the whole batch, not just patch the
    /// collision, or `id` would mean "the script's own id" for some rows and
    /// "its position" for others in the same batch.
    func testDuplicateExplicitIdsFallBackToPosition() throws {
        let rows = try SurfaceRows.decode(
            stdout: #"{"rows":[{"id":"x","name":"a"},{"id":"x","name":"b"}]}"#
        )
        XCTAssertEqual(rows.map(\.id), ["0", "1"])
    }

    /// `"id":""` is a legal string value, not a missing key — `values["id"]`
    /// sees it as present, so without the batch-wide uniqueness check both
    /// rows would decode to the same blank id.
    func testRowsWithBlankIdsFallBackToPosition() throws {
        let rows = try SurfaceRows.decode(
            stdout: #"{"rows":[{"id":"","name":"a"},{"id":"","name":"b"}]}"#
        )
        XCTAssertEqual(rows.map(\.id), ["0", "1"])
    }

    /// The collision `testAMissingIdFallsBackToThePosition` can't reach on
    /// its own: row 0 has no id and would synthesize "0", and row 1's own id
    /// happens to already be "0" — a script that named only some of its rows
    /// used to produce this collision silently.
    func testAnIdOnSomeRowsButNotOthersFallsBackToPositionForAll() throws {
        let rows = try SurfaceRows.decode(
            stdout: #"{"rows":[{"name":"a"},{"id":"0","name":"b"}]}"#
        )
        XCTAssertEqual(rows.map(\.id), ["0", "1"])
    }

    func testEmptyRowsAreFine() throws {
        XCTAssertEqual(try SurfaceRows.decode(stdout: #"{"rows":[]}"#), [])
    }

    func testTextThatIsNotJSONFails() {
        XCTAssertThrowsError(try SurfaceRows.decode(stdout: "Traceback (most recent call last):"))
    }

    /// Pinned to the case and the shape it names, not just "it throws": the
    /// document parsed fine, so `.notJSON` here would send a repairing model
    /// hunting for a syntax error that was never there. `{"rows":["a.txt"]}`
    /// is the model mistake this case exists for.
    func testARowThatIsNotAnObjectNamesItsShape() {
        XCTAssertThrowsError(try SurfaceRows.decode(stdout: #"{"rows":["a.txt"]}"#)) { error in
            guard case SurfaceRowsError.rowNotAnObject(let index, let kind) = error else {
                XCTFail("expected .rowNotAnObject, got \(error)")
                return
            }
            XCTAssertEqual(index, 0)
            XCTAssertEqual(kind, "a string")
        }
    }

    func testMoreThanFiveHundredRowsFails() {
        let many = (0..<501).map { #"{"id":"\#($0)"}"# }.joined(separator: ",")
        XCTAssertThrowsError(try SurfaceRows.decode(stdout: #"{"rows":[\#(many)]}"#)) { error in
            guard case SurfaceRowsError.tooManyRows(let count) = error else {
                XCTFail("expected .tooManyRows, got \(error)")
                return
            }
            XCTAssertEqual(count, 501)
        }
    }

    /// `maximumRows` has its own test above; the other three limits named in
    /// the brief (keys per row, value length, total stdout) had no coverage
    /// at all, so a row with e.g. a 10 000-byte value would have decoded
    /// clean. These close that gap.
    func testMoreThanThirtyTwoKeysOnARowFails() {
        let keys = (0..<33).map { #""k\#($0)":"v""# }.joined(separator: ",")
        XCTAssertThrowsError(try SurfaceRows.decode(stdout: #"{"rows":[{\#(keys)}]}"#)) { error in
            guard case SurfaceRowsError.tooManyKeys(let rowIndex, let count) = error else {
                XCTFail("expected .tooManyKeys, got \(error)")
                return
            }
            XCTAssertEqual(rowIndex, 0)
            XCTAssertEqual(count, 33)
        }
    }

    func testAValueOverOneKilobyteFails() {
        let value = String(repeating: "a", count: 1025)
        XCTAssertThrowsError(
            try SurfaceRows.decode(stdout: #"{"rows":[{"id":"1","note":"\#(value)"}]}"#)
        ) { error in
            guard case SurfaceRowsError.valueTooLong(let key, let bytes) = error else {
                XCTFail("expected .valueTooLong, got \(error)")
                return
            }
            XCTAssertEqual(key, "note")
            XCTAssertEqual(bytes, 1025)
        }
    }

    /// The padding lives in leading chatter, not inside a row's value — put
    /// it in a `"note"` field instead and `maximumValueBytes` (1024) would
    /// throw `.valueTooLong` first, at 256x under this test's padding size,
    /// and the test would pass even with the stdout cap deleted. Pinning
    /// `.tooMuchOutput` is what proves the cap fired rather than some other
    /// guard — and it is the case that actually tells a repairing model what
    /// to do: this stdout is genuinely valid JSON, just too much of it, so
    /// `.notJSON` would send it hunting for a syntax bug that was never there.
    func testStdoutOverTheByteCapFails() {
        let chatter = String(repeating: "x", count: SurfaceRows.maximumStdoutBytes)
        let stdout = chatter + "\n" + #"{"rows":[{"id":"1","name":"a"}]}"#
        XCTAssertThrowsError(try SurfaceRows.decode(stdout: stdout)) { error in
            guard case SurfaceRowsError.tooMuchOutput(let bytes) = error else {
                XCTFail("expected .tooMuchOutput, got \(error)")
                return
            }
            XCTAssertEqual(bytes, stdout.utf8.count)
        }
    }

    func testBooleansBecomeTrueOrFalse() throws {
        let rows = try SurfaceRows.decode(stdout: #"{"rows":[{"id":"1","active":true,"archived":false}]}"#)
        XCTAssertEqual(rows[0]["active"], "true")
        XCTAssertEqual(rows[0]["archived"], "false")
    }
}
