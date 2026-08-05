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

/// `SurfaceRefresh.caption(for:rowsAreEmpty:)` is what `SurfaceHostView` used
/// to decide by itself with a bare `isStale` flag — swallowing the real
/// failure message and showing "Nothing in Downloads" stacked on a generic
/// staleness caption for every failure, approval included. Pulling the
/// decision out here is what makes it testable without a view at all (I5).
final class SurfaceRefreshCaptionTests: XCTestCase {
    func testARefreshedOutcomeHasNoCaption() {
        XCTAssertNil(SurfaceRefresh.caption(for: .refreshed([]), rowsAreEmpty: true))
    }

    func testAnUnchangedOutcomeHasNoCaption() {
        XCTAssertNil(SurfaceRefresh.caption(for: .unchanged, rowsAreEmpty: false))
    }

    /// With nothing cached, there is no "what was here last" to point to —
    /// the real reason has to be the whole caption, not discarded in favor
    /// of a generic one stacked over the layout's own empty-state copy.
    func testAFailureWithNoCachedRowsShowsTheRealMessage() {
        let caption = SurfaceRefresh.caption(
            for: .failed("Not approved yet — run “Downloads” once from the ring or Home first."),
            rowsAreEmpty: true
        )
        XCTAssertEqual(caption, "Not approved yet — run “Downloads” once from the ring or Home first.")
    }

    /// Only when there is something cached behind it does "showing what was
    /// here last" become a true sentence.
    func testAFailureWithCachedRowsShowsTheStaleCaptionInstead() {
        let caption = SurfaceRefresh.caption(for: .failed("uv is not installed."), rowsAreEmpty: false)
        XCTAssertEqual(caption, "Couldn't refresh — showing what was here last.")
    }
}
