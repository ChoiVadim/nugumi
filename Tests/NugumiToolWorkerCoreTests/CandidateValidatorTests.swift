import Darwin
import Foundation
import NugumiToolAgentCore
import NugumiToolIPC
@testable import NugumiToolWorkerCore
import XCTest

final class CandidateValidatorTests: XCTestCase {
    private let systemPython = URL(fileURLWithPath: "/usr/bin/python3")

    func testUppercaseCandidatePassesWithAttestedFingerprint() async throws {
        // Given
        let candidate = try makeCandidate(
            source: "import sys\nprint(sys.argv[1].upper())",
            input: "Hello, Nugumi",
            expectedOutput: "HELLO, NUGUMI"
        )
        let request = try makeRequest(candidate: candidate)

        // When
        let reply = await makeValidator().validate(
            request,
            executionID: UUID()
        )

        // Then
        XCTAssertEqual(reply.outcome, .passed)
        XCTAssertEqual(reply.passingFingerprint, request.fingerprint)
        XCTAssertNil(reply.failure)
    }

    func testSyntaxErrorIsClassifiedBeforeFixtureExecution() async throws {
        // Given
        let candidate = try makeCandidate(source: "def broken(:\n  pass")

        // When
        let reply = await makeValidator().validate(
            try makeRequest(candidate: candidate),
            executionID: UUID()
        )

        // Then
        XCTAssertEqual(reply.failure, .syntaxError)
        XCTAssertNil(reply.fixtureIndex)
    }

    func testNonzeroExitIsRuntimeError() async throws {
        // Given
        let candidate = try makeCandidate(
            source: "import sys\nsys.stderr.write('boom')\nsys.exit(7)"
        )

        // When
        let reply = await makeValidator().validate(
            try makeRequest(candidate: candidate),
            executionID: UUID()
        )

        // Then
        XCTAssertEqual(reply.failure, .runtimeError)
        XCTAssertEqual(reply.exitCode, 7)
        XCTAssertEqual(reply.stderrDetail, "boom")
    }

    func testWhitespaceMismatchIsWrongOutput() async throws {
        // Given
        let candidate = try makeCandidate(
            source: "print('HELLO ')",
            expectedOutput: "HELLO"
        )

        // When
        let reply = await makeValidator().validate(
            try makeRequest(candidate: candidate),
            executionID: UUID()
        )

        // Then
        XCTAssertEqual(reply.failure, .wrongOutput)
        XCTAssertEqual(reply.actualOutput, "HELLO ")
        XCTAssertEqual(reply.fixtureIndex, 0)
    }

    func testCRLFNormalizationStripsExactlyOneTerminalLineFeed() async throws {
        // Given
        let candidate = try makeCandidate(
            source: "import sys\nsys.stdout.write('HELLO\\r\\n\\r\\n')",
            expectedOutput: "HELLO\n\n"
        )

        // When
        let reply = await makeValidator().validate(
            try makeRequest(candidate: candidate),
            executionID: UUID()
        )

        // Then
        XCTAssertEqual(reply.outcome, .passed)
    }

    func testInvalidUTF8OutputIsRejected() async throws {
        // Given
        let candidate = try makeCandidate(
            source: "import os\nos.write(1, b'\\xff')",
            expectedOutput: ""
        )

        // When
        let reply = await makeValidator().validate(
            try makeRequest(candidate: candidate),
            executionID: UUID()
        )

        // Then
        XCTAssertEqual(reply.failure, .invalidOutput)
    }

    func testTimeoutTerminatesCandidateProcessGroup() async throws {
        // Given
        let candidate = try makeCandidate(
            source: "import os, time\nif os.fork() == 0:\n  while True: time.sleep(1)\nwhile True: time.sleep(1)"
        )
        let validator = makeValidator(wallSeconds: 1)

        // When
        let reply = await validator.validate(
            try makeRequest(candidate: candidate),
            executionID: UUID()
        )

        // Then
        XCTAssertEqual(reply.failure, .timedOut)
        XCTAssertTrue(reply.processGroupTerminated)
    }

    func testOutputCapsProduceStableFailureAndTruncationFlags() async throws {
        // Given
        let candidate = try makeCandidate(
            source: "import sys\nsys.stdout.write('o' * 4096)\nsys.stderr.write('e' * 4096)"
        )

        // When
        let reply = await makeValidator(stdoutBytes: 64, stderrBytes: 64)
            .validate(try makeRequest(candidate: candidate), executionID: UUID())

        // Then
        XCTAssertEqual(reply.failure, .outputLimit)
        XCTAssertTrue(reply.stdoutWasTruncated)
        XCTAssertTrue(reply.stderrWasTruncated)
        XCTAssertLessThanOrEqual(reply.actualOutput?.utf8.count ?? 0, 64)
        XCTAssertLessThanOrEqual(reply.stderrDetail?.utf8.count ?? 0, 64)
    }

    func testCandidateSizeLimitsRejectSourceInputAndOutput() throws {
        // Given / When / Then
        XCTAssertThrowsError(
            try makeCandidate(
                source: String(
                    repeating: "x",
                    count: ToolAgentProtocolLimitsV1.maximumSourceBytes + 1
                )
            )
        )
        XCTAssertThrowsError(
            try makeCandidate(
                input: String(
                    repeating: "x",
                    count: ToolAgentProtocolLimitsV1.maximumFixtureInputBytes + 1
                )
            )
        )
        XCTAssertThrowsError(
            try makeCandidate(
                expectedOutput: String(
                    repeating: "x",
                    count: ToolAgentProtocolLimitsV1.maximumFixtureOutputBytes + 1
                )
            )
        )
    }

    func testFingerprintMustMatchPinnedRuntimeAndPolicy() async throws {
        // Given
        let candidate = try makeCandidate()
        let wrongFingerprint = try ToolAgentCandidateFingerprintV1.make(
            candidate: candidate,
            runtimeVersion: "3.12.12",
            policyVersion: CandidateValidator.policyVersion
        )
        let request = CandidateValidationRequestV1(
            runID: UUID(),
            candidateID: UUID(),
            candidate: candidate,
            fingerprint: wrongFingerprint
        )

        // When
        let reply = await makeValidator().validate(
            request,
            executionID: UUID()
        )

        // Then
        XCTAssertEqual(reply.failure, .invalidCandidate)
        XCTAssertNil(reply.passingFingerprint)
    }

    func testFailureReportRedactsPrivateAndWorkspacePaths() async throws {
        // Given
        let workspacePath = FileManager.default.currentDirectoryPath
        let candidate = try makeCandidate(
            source: "raise RuntimeError(__file__ + ' \(workspacePath)')"
        )

        // When
        let reply = await makeValidator().validate(
            try makeRequest(candidate: candidate),
            executionID: UUID()
        )
        let payload = try XCTUnwrap(
            String(data: JSONEncoder().encode(reply), encoding: .utf8)
        )

        // Then
        XCTAssertFalse(payload.contains(workspacePath))
        XCTAssertFalse(payload.contains("/private/"))
        XCTAssertFalse(payload.contains("/Users/"))
        XCTAssertTrue(payload.contains("[REDACTED_PATH]"))
    }

    func testFailureReportRedactsEveryAbsolutePathRoot() async throws {
        // Given
        let sentinels = [
            "/Volumes/External/private/sentinel.txt",
            "/Applications/Hidden.app/Contents/secret",
            "/Library/Application Support/Nugumi/secret.db",
            "/tmp/nugumi-secret-output",
            "/opt/custom/private-data",
            "/arbitrary-root/deeply/nested/secret",
            "/",
        ]
        let joinedPaths = sentinels.joined(separator: "|")
        let candidate = try makeCandidate(
            source: """
            import sys
            paths = "\(joinedPaths)".split("|")
            sys.stdout.write("\\n".join(paths))
            sys.stderr.write("\\n".join(paths))
            sys.exit(7)
            """
        )

        // When
        let reply = await makeValidator().validate(
            try makeRequest(candidate: candidate),
            executionID: UUID()
        )
        let actualOutput = try XCTUnwrap(reply.actualOutput)
        let stderrDetail = try XCTUnwrap(reply.stderrDetail)

        // Then
        XCTAssertEqual(reply.failure, .runtimeError)
        for sentinel in sentinels {
            XCTAssertFalse(actualOutput.contains(sentinel))
            XCTAssertFalse(stderrDetail.contains(sentinel))
        }
        XCTAssertTrue(actualOutput.contains("[REDACTED_PATH]"))
        XCTAssertTrue(stderrDetail.contains("[REDACTED_PATH]"))
    }

    private func makeValidator(
        wallSeconds: Int = 3,
        stdoutBytes: Int = 16 * 1_024,
        stderrBytes: Int = 16 * 1_024
    ) -> CandidateValidator {
        CandidateValidator(
            runtime: CandidateValidatorRuntime(
                pythonExecutable: systemPython,
                runtimeVersion: CandidateValidator.runtimeVersion
            ),
            limits: SandboxProbeLimits(
                wallSeconds: wallSeconds,
                cpuSeconds: 2,
                addressSpaceBytes: 256 * 1_024 * 1_024,
                fileBytes: 4 * 1_024 * 1_024,
                stdoutBytes: stdoutBytes,
                stderrBytes: stderrBytes
            )
        )
    }

    private func makeCandidate(
        source: String = "import sys\nprint(sys.argv[1].upper())",
        input: String = "hello",
        expectedOutput: String = "HELLO"
    ) throws -> ToolAgentCandidateV1 {
        try ToolAgentCandidateV1(
            name: "Uppercase",
            brief: "Uppercase text",
            symbolName: "textformat",
            source: source,
            fixtures: [
                ToolAgentFixtureV1(
                    input: input,
                    expectedOutput: expectedOutput
                )
            ]
        )
    }

    private func makeRequest(
        candidate: ToolAgentCandidateV1
    ) throws -> CandidateValidationRequestV1 {
        CandidateValidationRequestV1(
            runID: UUID(),
            candidateID: UUID(),
            candidate: candidate,
            fingerprint: try ToolAgentCandidateFingerprintV1.make(
                candidate: candidate,
                runtimeVersion: CandidateValidator.runtimeVersion,
                policyVersion: CandidateValidator.policyVersion
            )
        )
    }
}
