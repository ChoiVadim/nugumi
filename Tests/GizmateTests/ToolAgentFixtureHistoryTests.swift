import GizmateToolAgentCore
import XCTest
@testable import Gizmate

final class ToolAgentFixtureHistoryTests: XCTestCase {
    private func input(fixtures: [ToolAgentFixtureV1]) throws -> ToolBuildValidationInputV1 {
        let candidate = try ToolAgentCandidateV1(
            kind: .python,
            name: "Download",
            brief: "Downloads a video.",
            symbolName: "arrow.down.circle",
            input: .selection,
            output: .files,
            trigger: .always,
            hosts: ["example.com"],
            source: "print('ok')",
            fixtures: fixtures,
            outputDirectory: "~/Downloads",
            timeoutSeconds: 60,
            declaresNetwork: true
        )
        return ToolBuildValidationInputV1(
            request: ToolBuildRequestV1(description: "download"),
            candidateID: UUID(),
            fingerprint: try ToolAgentCandidateFingerprintV1.make(
                candidate: candidate,
                runtimeVersion: "test",
                policyVersion: "test"
            ),
            candidate: candidate
        )
    }

    /// The cheapest way past a failing check is to delete the test. Observed in
    /// the eval: a working downloader whose test URL was dead came back with no
    /// test at all and would have shipped unproven.
    func testCandidateCannotDropItsFixturesAfterOfferingThem() async throws {
        // Given
        let history = ToolAgentFixtureHistory()
        let withFixture = try input(fixtures: [.init(input: "https://example.com/a")])
        let withoutFixture = try input(fixtures: [])

        // When
        let first = try await history.retreatReport(for: withFixture)
        let second = try await history.retreatReport(for: withoutFixture)

        // Then
        XCTAssertNil(first)
        XCTAssertEqual(second?.outcome, .failed)
        XCTAssertEqual(second?.failure, .invalidCandidate)
        XCTAssertEqual(second?.candidateID, withoutFixture.candidateID)
        XCTAssertTrue(second?.stderrDetail?.contains("removing the test") == true)
    }

    /// A tool whose run would really have an unwanted side effect says so with
    /// its first candidate, and must stay buildable.
    func testCandidateThatNeverOfferedFixturesIsLeftAlone() async throws {
        // Given
        let history = ToolAgentFixtureHistory()

        // When
        let first = try await history.retreatReport(for: try input(fixtures: []))
        let second = try await history.retreatReport(for: try input(fixtures: []))

        // Then
        XCTAssertNil(first)
        XCTAssertNil(second)
    }
}
