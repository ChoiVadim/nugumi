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
}
