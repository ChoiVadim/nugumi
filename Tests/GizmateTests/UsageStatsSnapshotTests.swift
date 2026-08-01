import XCTest
@testable import Gizmate

final class UsageStatsSnapshotTests: XCTestCase {
    private func event(
        _ kind: UsageStatsEventKind,
        gizmoName: String? = nil,
        date: Date = Date()
    ) -> UsageStatsEvent {
        UsageStatsEvent(
            id: UUID(),
            date: date,
            kind: kind,
            sourceWordCount: 0,
            resultWordCount: 0,
            characterCount: 0,
            targetLanguageID: nil,
            gizmoName: gizmoName
        )
    }

    /// A replacement is the follow-up to a run that already counted. Counting it
    /// would show two runs for one press of one button.
    func testReplacementsAreNotRuns() {
        let snapshot = UsageStatsSnapshot.make(events: [
            event(.draftMessage),
            event(.replacement)
        ])

        XCTAssertEqual(snapshot.totalRuns, 1)
        XCTAssertEqual(snapshot.distinctGizmos, 1)
        XCTAssertEqual(snapshot.gizmoBreakdown.map(\.name), ["My writing"])
    }

    func testReplacementOnlyHistoryHasNoRuns() {
        let snapshot = UsageStatsSnapshot.make(events: [event(.replacement)])

        XCTAssertEqual(snapshot.totalRuns, 0)
        XCTAssertEqual(snapshot.distinctGizmos, 0)
        XCTAssertTrue(snapshot.gizmoBreakdown.isEmpty)
        XCTAssertEqual(snapshot.currentStreak, 0)
    }

    /// The built-ins share the leaderboard with the user's own gizmos: same ring,
    /// same slots, so the same list. Built-ins are named by their kind, user
    /// gizmos by themselves.
    func testBuiltInsAndGizmosShareOneLeaderboard() {
        let snapshot = UsageStatsSnapshot.make(events: [
            event(.gizmoRun, gizmoName: "Resize Images"),
            event(.gizmoRun, gizmoName: "Resize Images"),
            event(.gizmoRun, gizmoName: "Resize Images"),
            event(.gizmoRun, gizmoName: "PDF to Markdown"),
            event(.smartReply)
        ])

        XCTAssertEqual(snapshot.totalRuns, 5)
        XCTAssertEqual(snapshot.distinctGizmos, 3)
        XCTAssertEqual(
            snapshot.gizmoBreakdown.map(\.name),
            ["Resize Images", "PDF to Markdown", "Replies"]
        )
        XCTAssertEqual(snapshot.gizmoBreakdown.map(\.count), [3, 1, 1])
        XCTAssertEqual(snapshot.gizmoBreakdown[0].fraction, 0.6, accuracy: 0.0001)
    }

    /// Ties break by name so the donut's slice order — and therefore its
    /// lightness ramp — doesn't shuffle between reads of the same data.
    func testEqualCountsSortByName() {
        let snapshot = UsageStatsSnapshot.make(events: [
            event(.gizmoRun, gizmoName: "Zip"),
            event(.gizmoRun, gizmoName: "Alpha")
        ])

        XCTAssertEqual(snapshot.gizmoBreakdown.map(\.name), ["Alpha", "Zip"])
    }

    func testTodayAndBusiestDayCountRuns() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let snapshot = UsageStatsSnapshot.make(events: [
            event(.gizmoRun, gizmoName: "Resize Images"),
            event(.gizmoRun, gizmoName: "Resize Images", date: yesterday),
            event(.gizmoRun, gizmoName: "Resize Images", date: yesterday),
            event(.replacement, date: yesterday)
        ])

        XCTAssertEqual(snapshot.runsToday, 1)
        XCTAssertEqual(snapshot.busiestDay?.runCount, 2)
        XCTAssertEqual(snapshot.currentStreak, 2)
    }

    /// Events written before gizmo runs were counted carry no `gizmoName` key.
    /// They have to keep decoding, or everyone's history reads as empty.
    func testLegacyEventDecodesWithoutGizmoName() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","date":0,"kind":"selection",
          "sourceWordCount":4,"resultWordCount":5,"characterCount":20}]
        """
        let decoded = try JSONDecoder().decode([UsageStatsEvent].self, from: Data(json.utf8))

        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].gizmoName)
        XCTAssertEqual(decoded[0].displayName, "Selected text")
    }
}
