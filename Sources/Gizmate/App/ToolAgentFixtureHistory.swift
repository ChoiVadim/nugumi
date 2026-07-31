import Foundation
import GizmateToolAgentCore

/// Stops a build from getting easier every time it fails.
///
/// Running a candidate on a fixture is the only evidence Gizmate has that a
/// generated tool works; a candidate with no fixtures is only compiled. So the
/// cheapest way past a failing check is to delete the fixture — and a model
/// that has just been told its tool failed will take it. The eval caught
/// exactly that: a working video downloader was written, its test URL turned
/// out to be dead, and the next candidate simply had no test at all and
/// shipped unproven.
///
/// Asking the model not to do it is not enough, so the host refuses instead:
/// once a run has offered a candidate it was willing to have run, every later
/// candidate has to be runnable too. A tool whose run would really have an
/// unwanted side effect declares that from its first candidate, which this
/// leaves alone.
actor ToolAgentFixtureHistory {
    private var offeredFixtures = false

    func retreatReport(
        for input: ToolBuildValidationInputV1
    ) throws -> ToolAgentValidationReportV1? {
        guard input.candidate.fixtures.isEmpty, offeredFixtures else {
            offeredFixtures = offeredFixtures || !input.candidate.fixtures.isEmpty
            return nil
        }
        return try ToolAgentValidationReportV1(
            candidateID: input.candidateID,
            fingerprint: input.fingerprint,
            outcome: .failed,
            failure: .invalidCandidate,
            stderrDetail: """
                This candidate has no fixtures, but an earlier candidate in this \
                build had one. A failed check means either the tool or the test \
                input was wrong, and removing the test fixes neither. Keep a \
                fixture and repair whichever of the two was actually wrong.
                """
        )
    }
}
