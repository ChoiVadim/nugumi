import GizmateToolAgentCore
import XCTest
@testable import Gizmate

final class SurfaceCandidateValidationTests: XCTestCase {
    private let rows = [SurfaceRow(id: "1", values: ["name": "a.txt", "path": "/tmp/a.txt"])]

    func testALayoutWhoseKeysAllExistPasses() {
        let layout = ToolAgentLayoutV1.list(
            row: .card(.init(title: .key("name"),
                       drag: .file(key: "path"))),
            empty: "Nothing"
        )
        XCTAssertNil(SurfaceLayoutCheck.diagnostic(for: layout, against: rows))
    }

    func testAKeyNoRowHasIsNamedInTheDiagnostic() {
        let layout = ToolAgentLayoutV1.list(
            row: .card(.init(title: .key("filename"))),
            empty: "Nothing"
        )
        let diagnostic = SurfaceLayoutCheck.diagnostic(for: layout, against: rows)
        XCTAssertNotNil(diagnostic)
        XCTAssertTrue(diagnostic!.contains("filename"))
        XCTAssertTrue(diagnostic!.contains("name"), "the diagnostic should list the keys that do exist")
    }

    func testAFileKeyHoldingSomethingThatIsNotAPathIsRefused() {
        let layout = ToolAgentLayoutV1.list(
            row: .card(.init(title: .key("name"),
                       drag: .file(key: "name"))),
            empty: "Nothing"
        )
        XCTAssertNotNil(SurfaceLayoutCheck.diagnostic(for: layout, against: rows))
    }

    /// A script that legitimately has nothing to show today cannot be checked
    /// against its keys, and failing the build for an empty Downloads folder
    /// would be absurd. It passes and grades as a smoke run.
    func testNoRowsIsNotAFailure() {
        let layout = ToolAgentLayoutV1.list(row: .text(.key("name")), empty: "Nothing")
        XCTAssertNil(SurfaceLayoutCheck.diagnostic(for: layout, against: []))
    }

    func testAResolvableIconSymbolPasses() {
        let layout = ToolAgentLayoutV1.list(
            row: .card(.init(title: .key("name"), icon: .symbol("folder"))),
            empty: "Nothing"
        )
        XCTAssertNil(SurfaceLayoutCheck.diagnostic(for: layout, against: rows))
    }

    /// The model has an SF Symbol shortlist in the very same prompt and can
    /// still invent a name that doesn't exist — "symbol:not-a-real-glyph"
    /// used to pass every layer and draw a silent blank icon (I3). This is
    /// the layer that now catches it, naming the bad glyph the way any other
    /// diagnostic here names its bad key.
    func testAnUnresolvableIconSymbolIsRefused() {
        let layout = ToolAgentLayoutV1.list(
            row: .card(.init(title: .key("name"), icon: .symbol("not-a-real-glyph"))),
            empty: "Nothing"
        )
        let diagnostic = SurfaceLayoutCheck.diagnostic(for: layout, against: rows)
        XCTAssertNotNil(diagnostic)
        XCTAssertTrue(diagnostic!.contains("not-a-real-glyph"))
    }

    /// Unlike a key check, an icon symbol's validity has nothing to do with
    /// what the script printed — it either resolves on this OS or it
    /// doesn't — so it has to be caught even when a script has nothing to
    /// show yet, not just the day its folder stops being empty.
    func testAnUnresolvableIconSymbolIsRefusedEvenWithNoRows() {
        let layout = ToolAgentLayoutV1.list(
            row: .card(.init(title: .key("name"), icon: .symbol("not-a-real-glyph"))),
            empty: "Nothing"
        )
        XCTAssertNotNil(SurfaceLayoutCheck.diagnostic(for: layout, against: []))
    }

    /// A `symbol:$key` icon lets each row name its own glyph, which is the
    /// whole point of it — one surface showing a CPU card beside a disk card.
    func testAnIconKeyWhoseRowsHoldRealGlyphsPasses() {
        let layout = ToolAgentLayoutV1.list(
            row: .card(.init(title: .key("name"), icon: .symbolKey(key: "glyph"))),
            empty: "Nothing"
        )
        let rows = [
            SurfaceRow(id: "1", values: ["name": "CPU", "glyph": "cpu"]),
            SurfaceRow(id: "2", values: ["name": "Disk", "glyph": "internaldrive"]),
        ]
        XCTAssertNil(SurfaceLayoutCheck.diagnostic(for: layout, against: rows))
    }

    /// The glyph now comes from the script's own output, so the literal check
    /// above never sees it. Without this the renderer falls back to `sparkles`
    /// and every card wears the same wrong icon — the exact silent failure a
    /// per-row icon was added to end.
    func testAnIconKeyHoldingSomethingThatIsNotAGlyphIsRefused() {
        let layout = ToolAgentLayoutV1.list(
            row: .card(.init(title: .key("name"), icon: .symbolKey(key: "glyph"))),
            empty: "Nothing"
        )
        let rows = [SurfaceRow(id: "1", values: ["name": "CPU", "glyph": "not-a-real-glyph"])]
        let diagnostic = SurfaceLayoutCheck.diagnostic(for: layout, against: rows)
        XCTAssertNotNil(diagnostic)
        XCTAssertTrue(diagnostic!.contains("not-a-real-glyph"))
    }

    private func statRow(meter: String? = nil, chart: String? = nil) -> ToolAgentLayoutV1 {
        .list(
            row: .card(.init(title: .key("name"), details: [.key("detail")],
                             meter: meter, chart: chart)),
            empty: "Nothing"
        )
    }

    func testAMeterAndAChartTheRowsCanActuallyFillPass() {
        let layout = statRow(meter: "load", chart: "history")
        let rows = [SurfaceRow(id: "1", values: [
            "name": "CPU", "detail": "System: 7.5%", "load": "19.8%", "history": "18,22,19,41"
        ])]
        XCTAssertNil(SurfaceLayoutCheck.diagnostic(for: layout, against: rows))
    }

    /// The one a script is most likely to get wrong: a percentage written
    /// without its sign is a number ten times too big for a fraction, and a
    /// bar clamped to full would look like a working panel reporting a full
    /// disk. The diagnostic names the value and both accepted spellings.
    func testAMeterValueThatIsNeitherFractionNorPercentageIsRefused() {
        let layout = statRow(meter: "load")
        let rows = [SurfaceRow(id: "1", values: ["name": "CPU", "detail": "x", "load": "19.8"])]
        let diagnostic = SurfaceLayoutCheck.diagnostic(for: layout, against: rows)
        XCTAssertNotNil(diagnostic)
        XCTAssertTrue(diagnostic!.contains("19.8"))
        XCTAssertTrue(diagnostic!.contains("%"))
    }

    func testAChartValueThatIsNotASeriesIsRefused() {
        let layout = statRow(chart: "history")
        let rows = [SurfaceRow(id: "1", values: ["name": "CPU", "detail": "x", "history": "41"])]
        let diagnostic = SurfaceLayoutCheck.diagnostic(for: layout, against: rows)
        XCTAssertNotNil(diagnostic)
        XCTAssertTrue(diagnostic!.contains("41"))
    }

    /// Checked from the layout alone, so a script with nothing to show today
    /// still can't ship a grid full of readings that would be clipped away.
    func testAGridCellAskingForRowOnlyFieldsIsRefusedWithNoRows() {
        let layout = ToolAgentLayoutV1.grid(
            cell: .card(.init(title: .key("name"), details: [.key("detail")], meter: "load")),
            minimumWidth: 120,
            empty: "Nothing"
        )
        let diagnostic = SurfaceLayoutCheck.diagnostic(for: layout, against: [])
        XCTAssertNotNil(diagnostic)
        XCTAssertTrue(diagnostic!.contains("details"))
        XCTAssertTrue(diagnostic!.contains("meter"))
        XCTAssertTrue(diagnostic!.contains("list"), "the diagnostic should name the fix")
    }
}
