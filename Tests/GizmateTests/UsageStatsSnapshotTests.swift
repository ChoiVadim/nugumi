import XCTest
@testable import Gizmate

final class UsageStatsSnapshotTests: XCTestCase {
    func testReplacementEventsDoNotDoubleCountWordUsage() {
        let now = Date()
        let translation = UsageStatsEvent(
            id: UUID(),
            date: now,
            kind: .draftMessage,
            sourceWordCount: 4,
            resultWordCount: 5,
            characterCount: 20,
            targetLanguageID: "ko"
        )
        let replacement = UsageStatsEvent(
            id: UUID(),
            date: now,
            kind: .replacement,
            sourceWordCount: 0,
            resultWordCount: 5,
            characterCount: 18,
            targetLanguageID: nil
        )

        let snapshot = UsageStatsSnapshot.make(events: [translation, replacement])

        XCTAssertEqual(snapshot.totalUses, 1)
        XCTAssertEqual(snapshot.totalReplacements, 1)
        XCTAssertEqual(snapshot.totalSourceWords, 5)
        XCTAssertEqual(snapshot.currentMonthWords, 5)
        XCTAssertEqual(snapshot.activeDays, 1)
    }

    func testReplacementOnlyEventsDoNotCreateWordActivity() {
        let replacement = UsageStatsEvent(
            id: UUID(),
            date: Date(),
            kind: .replacement,
            sourceWordCount: 0,
            resultWordCount: 7,
            characterCount: 28,
            targetLanguageID: nil
        )

        let snapshot = UsageStatsSnapshot.make(events: [replacement])

        XCTAssertEqual(snapshot.totalUses, 0)
        XCTAssertEqual(snapshot.totalReplacements, 1)
        XCTAssertEqual(snapshot.totalSourceWords, 0)
        XCTAssertEqual(snapshot.currentMonthWords, 0)
        XCTAssertEqual(snapshot.activeDays, 0)
    }
}
