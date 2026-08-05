import GizmateToolAgentCore
import XCTest
@testable import Gizmate

final class SurfaceCandidateValidationTests: XCTestCase {
    private let rows = [SurfaceRow(id: "1", values: ["name": "a.txt", "path": "/tmp/a.txt"])]

    func testALayoutWhoseKeysAllExistPasses() {
        let layout = ToolAgentLayoutV1.list(
            row: .card(title: .key("name"), subtitle: nil, icon: nil,
                       drag: .file(key: "path"), tap: nil),
            empty: "Nothing"
        )
        XCTAssertNil(SurfaceLayoutCheck.diagnostic(for: layout, against: rows))
    }

    func testAKeyNoRowHasIsNamedInTheDiagnostic() {
        let layout = ToolAgentLayoutV1.list(
            row: .card(title: .key("filename"), subtitle: nil, icon: nil, drag: nil, tap: nil),
            empty: "Nothing"
        )
        let diagnostic = SurfaceLayoutCheck.diagnostic(for: layout, against: rows)
        XCTAssertNotNil(diagnostic)
        XCTAssertTrue(diagnostic!.contains("filename"))
        XCTAssertTrue(diagnostic!.contains("name"), "the diagnostic should list the keys that do exist")
    }

    func testAFileKeyHoldingSomethingThatIsNotAPathIsRefused() {
        let layout = ToolAgentLayoutV1.list(
            row: .card(title: .key("name"), subtitle: nil, icon: nil,
                       drag: .file(key: "name"), tap: nil),
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
            row: .card(title: .key("name"), subtitle: nil, icon: .symbol("folder"), drag: nil, tap: nil),
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
            row: .card(title: .key("name"), subtitle: nil, icon: .symbol("not-a-real-glyph"), drag: nil, tap: nil),
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
            row: .card(title: .key("name"), subtitle: nil, icon: .symbol("not-a-real-glyph"), drag: nil, tap: nil),
            empty: "Nothing"
        )
        XCTAssertNotNil(SurfaceLayoutCheck.diagnostic(for: layout, against: []))
    }
}
