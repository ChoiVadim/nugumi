import Foundation
import GizmateToolAgentCore

/// Checks a `.agent` candidate before it can be finished.
///
/// The other three kinds are validated by examining something fixed: a prompt is
/// structural, a native action names a real app, a Python script compiles and
/// runs against a fixture. An agent tool has none of that — its behavior does
/// not exist until someone presses its button — so the strongest honest check is
/// that it *gets somewhere*: the sidecar starts, the model drives it, and it
/// reaches an answer within a tight budget.
///
/// That is worth `.smoke` and never `.verified`. Running a non-deterministic
/// tool once and calling it verified would put a claim in the UI that the next
/// run can contradict.
enum AgentCandidateValidation {
    /// Deliberately smaller than the tool's own budget. The trial is asking
    /// "does this get off the ground", not "does it do the whole job", and a
    /// build should not cost a full-length agent run.
    private static let trialSteps = 3
    private static let trialSeconds = 90

    @MainActor
    static func validate(
        _ input: ToolBuildValidationInputV1,
        backend: any LLMBackend,
        thinkingLevel: ThinkingLevel,
        uv: URL
    ) async throws -> ToolAgentValidationReportV1 {
        let candidate = input.candidate

        // No fixture means the model judged that really running this would do
        // something to the user's data or to the outside world. Taking it on
        // structure is the same bargain a fixture-less Python candidate gets,
        // and for the same reason: the alternative is doing the thing.
        guard let fixture = candidate.fixtures.first else {
            return try ToolAgentValidationReportV1(
                candidateID: input.candidateID,
                fingerprint: input.fingerprint,
                outcome: .passed,
                assurance: .unverified,
                passingFingerprint: input.fingerprint
            )
        }

        var trial = ToolAgentLiveBuilder.generatedTool(from: candidate).tool
        trial.maxSteps = min(candidate.maxSteps, trialSteps)
        trial.timeoutSeconds = min(candidate.timeoutSeconds, trialSeconds)

        let started = Date()
        do {
            let answer = try await AgentToolRunner.run(
                tool: trial,
                input: fixture.input,
                backend: backend,
                thinkingLevel: thinkingLevel,
                uv: uv
            )
            let duration = Int(Date().timeIntervalSince(started) * 1000)
            guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return try report(
                    input,
                    failure: .invalidOutput,
                    detail: "The agent finished without saying anything. Its instruction has "
                        + "to leave it something to answer with."
                )
            }
            return try ToolAgentValidationReportV1(
                candidateID: input.candidateID,
                fingerprint: input.fingerprint,
                outcome: .passed,
                assurance: .smoke,
                actualOutput: ToolAgentLiveBuilder.boundedDiagnostic(answer),
                durationMilliseconds: duration,
                passingFingerprint: input.fingerprint
            )
        } catch AgentToolRunError.failed(.budgetExhausted, _),
            AgentToolRunError.failed(.timedOut, _) {
            // The trial's budgets — steps and clock alike — are deliberately
            // smaller than the tool's own, so running out of either says
            // nothing bad about the candidate. Failing here would make the
            // model "repair" a tool that was fine by simplifying it until it
            // fits three steps and ninety seconds: a run of four candidates
            // did exactly that, each one promising harder not to save files,
            // because the trial's timeout surfaced as a pipe write error.
            return try ToolAgentValidationReportV1(
                candidateID: input.candidateID,
                fingerprint: input.fingerprint,
                outcome: .passed,
                assurance: .unverified,
                passingFingerprint: input.fingerprint
            )
        } catch {
            // The diagnostic is what the model reads to repair the candidate, so
            // it carries the real reason rather than "validation failed".
            return try report(
                input,
                failure: failureCode(for: error),
                detail: error.localizedDescription
            )
        }
    }

    private static func report(
        _ input: ToolBuildValidationInputV1,
        failure: ToolAgentFailureCodeV1,
        detail: String
    ) throws -> ToolAgentValidationReportV1 {
        try ToolAgentValidationReportV1(
            candidateID: input.candidateID,
            fingerprint: input.fingerprint,
            outcome: .failed,
            failure: failure,
            stderrDetail: ToolAgentLiveBuilder.boundedDiagnostic(detail)
        )
    }

    private static func failureCode(for error: Error) -> ToolAgentFailureCodeV1 {
        guard case AgentToolRunError.failed(let code, _) = error else {
            return .runtimeError
        }
        return code
    }
}
