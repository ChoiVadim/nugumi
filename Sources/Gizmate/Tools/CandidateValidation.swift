import Foundation
import GizmateToolAgentCore

/// Runs a candidate the agent just wrote, exactly the way the user's Mac will
/// run it once it is saved.
///
/// The point is that there is now only one execution path. Validation used to
/// go through a sandboxed XPC worker driving a CPython baked into the app
/// bundle — no network, no installable packages, no user files. A candidate
/// could therefore only ever be proven if it was a pure standard-library text
/// transform, which is exactly why the agent was instructed to refuse
/// everything else and why one video downloader had to be smuggled in as a
/// hardcoded profile. Running the candidate through the same `uv` that
/// `ToolRunner` uses makes "it passed" and "it will work" the same sentence,
/// and any dependency the script declares is simply resolved.
///
/// What that costs is stated in `ToolRunner`: a validation run is a real run,
/// with the user's access. The compensating control is that a candidate the
/// agent could not run without side effects is not run at all — it comes back
/// `unverified` and says so — and that nothing is saved before the user presses
/// Save.
enum CandidateValidation {
    /// Dependency resolution and interpreter download happen inside the same
    /// process the script runs in, so validation gets more room than the tool's
    /// own timeout. Capped so one slow candidate cannot eat the whole build.
    private static let resolveAllowanceSeconds = 90
    private static let maximumSeconds = 240

    static func validate(
        _ input: ToolBuildValidationInputV1,
        uv: URL
    ) async throws -> ToolAgentValidationReportV1 {
        let candidate = input.candidate
        guard candidate.kind == .python else {
            return try report(input, failure: .invalidCandidate)
        }
        guard candidate.fixtures.isEmpty == false else {
            return try await checkWithoutRunning(input, uv: uv)
        }

        var assurance = ToolAgentAssuranceV1.verified
        for (index, fixture) in candidate.fixtures.enumerated() {
            let outcome = try await run(
                input,
                fixture: fixture,
                fixtureIndex: index,
                uv: uv
            )
            switch outcome {
            case .failed(let failure):
                return failure
            case .matched:
                continue
            case .ranWithoutComparison:
                // Never upgrades a grade an earlier fixture already weakened.
                if assurance == .verified { assurance = .smoke }
            case .tooSlowToValidate:
                assurance = .unverified
            }
        }
        return try report(input, assurance: assurance)
    }

    // MARK: - Running a fixture

    private enum FixtureOutcome {
        case matched
        case ranWithoutComparison
        case tooSlowToValidate
        case failed(ToolAgentValidationReportV1)
    }

    private static func run(
        _ input: ToolBuildValidationInputV1,
        fixture: ToolAgentFixtureV1,
        fixtureIndex: Int,
        uv: URL
    ) async throws -> FixtureOutcome {
        let candidate = input.candidate
        var tool = ToolAgentLiveBuilder.generatedTool(from: candidate).tool
        tool.timeoutSeconds = min(
            candidate.timeoutSeconds + resolveAllowanceSeconds,
            maximumSeconds
        )
        let started = Date()

        let result: ToolRunResult
        do {
            result = try await ToolRunner.run(
                tool: tool,
                script: candidate.source,
                arguments: [fixture.input],
                uv: uv,
                deliverOutputs: false
            )
        } catch {
            // A tool that legitimately declared a longer runtime than the build
            // can wait for is not broken, and telling the model to repair it
            // would send it chasing a bug that is not there.
            if case ToolRunError.timedOut = error, exceedsValidationBudget(candidate) {
                return .tooSlowToValidate
            }
            return .failed(try report(
                input,
                fixtureIndex: fixtureIndex,
                failure: failureCode(for: error),
                stderrDetail: error.localizedDescription,
                started: started
            ))
        }

        guard result.isSuccess else {
            return .failed(try report(
                input,
                fixtureIndex: fixtureIndex,
                failure: .runtimeError,
                stderrDetail: result.stderr.isEmpty
                    ? "The script exited with code \(result.exitCode)."
                    : result.stderr,
                exitCode: result.exitCode,
                started: started
            ))
        }

        // A tool that promised files has to have produced one. Checked before
        // the text comparison because "it printed the right thing but wrote
        // nothing" is the more useful diagnostic of the two.
        if candidate.output == .files, result.producedFiles.isEmpty {
            return .failed(try report(
                input,
                fixtureIndex: fixtureIndex,
                failure: .invalidOutput,
                stderrDetail: "The tool declares a file output but produced no "
                    + "file. Write the result to the working directory.",
                exitCode: result.exitCode,
                started: started
            ))
        }

        guard let expected = fixture.expectedOutput else {
            return .ranWithoutComparison
        }
        let actual = normalized(result.stdout)
        guard actual == normalized(expected) else {
            return .failed(try report(
                input,
                fixtureIndex: fixtureIndex,
                failure: .wrongOutput,
                expectedOutput: expected,
                actualOutput: result.stdout,
                stderrDetail: result.stderr.isEmpty ? nil : result.stderr,
                exitCode: result.exitCode,
                started: started
            ))
        }
        return .matched
    }

    // MARK: - Checking without running

    /// For a candidate whose whole purpose is a side effect. Resolves the
    /// script's declared dependencies and compiles its source without importing
    /// it, so a nonexistent package or a syntax error still fails the build —
    /// the two things that would otherwise blow up in the user's face on the
    /// first real run.
    private static func checkWithoutRunning(
        _ input: ToolBuildValidationInputV1,
        uv: URL
    ) async throws -> ToolAgentValidationReportV1 {
        let candidate = input.candidate
        let started = Date()
        var checker = ToolAgentLiveBuilder.generatedTool(from: candidate).tool
        checker.output = .clipboard
        checker.timeoutSeconds = min(
            resolveAllowanceSeconds * 2,
            maximumSeconds
        )

        let result: ToolRunResult
        do {
            result = try await ToolRunner.run(
                tool: checker,
                script: checkerScript(for: candidate.source),
                // The source travels as an argument rather than a second file
                // because the runner writes exactly one script. 64 KiB is the
                // candidate ceiling and ARG_MAX here is a megabyte.
                arguments: [candidate.source],
                uv: uv,
                deliverOutputs: false
            )
        } catch {
            return try report(
                input,
                failure: failureCode(for: error),
                stderrDetail: error.localizedDescription,
                started: started
            )
        }
        guard result.isSuccess else {
            return try report(
                input,
                failure: result.stderr.contains("SyntaxError")
                    ? .syntaxError
                    : .runtimeError,
                stderrDetail: result.stderr.isEmpty
                    ? "Could not resolve the script's dependencies."
                    : result.stderr,
                exitCode: result.exitCode,
                started: started
            )
        }
        return try report(input, assurance: .unverified, started: started)
    }

    static func checkerScript(for source: String) -> String {
        let header = pep723Header(of: source)
        let body = """
        import sys

        compile(sys.argv[1], "main.py", "exec")
        print("gizmate: dependencies resolved and the source compiles")
        """
        return header.isEmpty ? body : header + "\n" + body
    }

    /// The candidate's PEP 723 block, verbatim. Running the checker under the
    /// same header is what proves the header itself resolves.
    static func pep723Header(of source: String) -> String {
        let lines = source.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "# /// script"
        }), let end = lines[(start + 1)...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "# ///"
        }) else {
            return ""
        }
        return lines[start...end].joined(separator: "\n") + "\n"
    }

    // MARK: - Reporting

    private static func report(
        _ input: ToolBuildValidationInputV1,
        assurance: ToolAgentAssuranceV1 = .verified,
        fixtureIndex: Int? = nil,
        failure: ToolAgentFailureCodeV1? = nil,
        expectedOutput: String? = nil,
        actualOutput: String? = nil,
        stderrDetail: String? = nil,
        exitCode: Int32? = nil,
        started: Date? = nil
    ) throws -> ToolAgentValidationReportV1 {
        try ToolAgentValidationReportV1(
            candidateID: input.candidateID,
            fingerprint: input.fingerprint,
            outcome: failure == nil ? .passed : .failed,
            assurance: assurance,
            failure: failure,
            fixtureIndex: failure == nil ? nil : fixtureIndex,
            expectedOutput: expectedOutput.map(bounded),
            actualOutput: actualOutput.map(bounded),
            stderrDetail: stderrDetail.map(bounded),
            exitCode: exitCode,
            durationMilliseconds: started.map {
                min(Int(Date().timeIntervalSince($0) * 1000), 600_000)
            },
            passingFingerprint: failure == nil ? input.fingerprint : nil
        )
    }

    private static func exceedsValidationBudget(
        _ candidate: ToolAgentCandidateV1
    ) -> Bool {
        candidate.timeoutSeconds + resolveAllowanceSeconds > maximumSeconds
    }

    private static func failureCode(for error: Error) -> ToolAgentFailureCodeV1 {
        switch error {
        case ToolRunError.timedOut: return .timedOut
        case ToolRunError.stopped: return .cancelled
        case is CancellationError: return .cancelled
        default: return .workerFailure
        }
    }

    /// Trailing whitespace is not a difference worth failing a build over, and
    /// a model that writes `print(x)` cannot control the final newline anyway.
    private static func normalized(_ value: String) -> String {
        value
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(
                of: #"[ \t]+$"#,
                with: "",
                options: .regularExpression
            ) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bounded(_ text: String) -> String {
        ToolAgentLiveBuilder.boundedDiagnostic(text)
    }
}
