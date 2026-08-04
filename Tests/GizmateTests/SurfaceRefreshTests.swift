import XCTest
@testable import Gizmate

@MainActor
final class SurfaceRefreshTests: XCTestCase {
    /// The one branch worth a test without a live uv: a gizmo the user never
    /// approved must not be executed by a pointer crossing a screen edge.
    func testAnUnapprovedSurfaceIsNotRun() async {
        var tool = GizmateTool()
        tool.kind = .python
        tool.output = .surface
        tool.layout = .list(row: .text(.key("name")), empty: "Nothing")
        let outcome = await SurfaceRefresh.outcome(
            for: tool, isApproved: false
        ) { _ in XCTFail("an unapproved surface must not run"); return "" }
        guard case .failed = outcome else { return XCTFail("expected .failed") }
    }

    func testRowsThatDidNotChangeReportUnchanged() async {
        var tool = GizmateTool()
        tool.kind = .python
        tool.output = .surface
        tool.layout = .list(row: .text(.key("name")), empty: "Nothing")
        let json = #"{"rows":[{"id":"1","name":"a.txt"}]}"#
        // `SurfaceRows.decode` copies every key the script printed into
        // `values`, `id` included — only a fallback index is withheld (see
        // `SurfaceRows.rows(from:)`) — so a row decoded from this JSON
        // carries `id` in `values` too, not just as `SurfaceRow.id`.
        let decoded = SurfaceRow(id: "1", values: ["id": "1", "name": "a.txt"])
        _ = await SurfaceRefresh.outcome(for: tool, isApproved: true) { _ in json }
        let again = await SurfaceRefresh.outcome(
            for: tool, isApproved: true, previous: [decoded]
        ) { _ in json }
        XCTAssertEqual(again, .unchanged)
    }

    /// A run whose script actually changed the rows must report the new
    /// rows, not merely "not unchanged" — otherwise `.refreshed([])` would
    /// pass the same assertion an empty stub does.
    func testRowsThatChangedReportTheNewRows() async {
        var tool = GizmateTool()
        tool.kind = .python
        tool.output = .surface
        tool.layout = .list(row: .text(.key("name")), empty: "Nothing")
        let previous = SurfaceRow(id: "1", values: ["id": "1", "name": "a.txt"])
        let json = #"{"rows":[{"id":"1","name":"b.txt"}]}"#
        let outcome = await SurfaceRefresh.outcome(
            for: tool, isApproved: true, previous: [previous]
        ) { _ in json }
        XCTAssertEqual(outcome, .refreshed([SurfaceRow(id: "1", values: ["id": "1", "name": "b.txt"])]))
    }

    /// A run the closure throws from (a timeout, a non-zero exit, uv missing)
    /// has to surface as `.failed`, not crash `outcome` or silently vanish.
    func testAFailedRunReportsFailed() async {
        var tool = GizmateTool()
        tool.kind = .python
        tool.output = .surface
        tool.layout = .list(row: .text(.key("name")), empty: "Nothing")
        let outcome = await SurfaceRefresh.outcome(
            for: tool, isApproved: true
        ) { _ in throw ToolRunError.launchFailed("boom") }
        guard case .failed = outcome else { return XCTFail("expected .failed") }
    }
}
