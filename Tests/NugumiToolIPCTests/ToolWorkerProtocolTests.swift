import Foundation
import NugumiToolAgentCore
import XCTest
@testable import NugumiToolIPC

final class ToolWorkerProtocolTests: XCTestCase {
    func testCandidateRequestRoundTripsWithoutRuntimeOrHostPaths() throws {
        // Given
        let candidate = try ToolAgentCandidateV1(
            name: "Uppercase",
            brief: "Uppercase text",
            symbolName: "textformat",
            source: "import sys\nprint(sys.argv[1].upper())",
            fixtures: [.init(input: "hello", expectedOutput: "HELLO")]
        )
        let request = CandidateValidationRequestV1(
            runID: UUID(),
            candidateID: UUID(),
            candidate: candidate,
            fingerprint: try ToolAgentCandidateFingerprintV1.make(
                candidate: candidate,
                runtimeVersion: "3.12.11",
                policyVersion: "validation-v1"
            )
        )

        // When
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(
            CandidateValidationRequestV1.self,
            from: data
        )
        let payload = try XCTUnwrap(String(data: data, encoding: .utf8))

        // Then
        XCTAssertEqual(decoded, request)
        XCTAssertFalse(payload.contains("pythonExecutable"))
        XCTAssertFalse(payload.contains("workingDirectory"))
        XCTAssertFalse(payload.contains("sitePackages"))
    }

    func testCandidateFailureReplyRoundTripsWithBoundedDiagnostics() throws {
        // Given
        let reply = CandidateValidationReplyV1(
            runID: UUID(),
            candidateID: UUID(),
            fingerprint: ToolAgentFingerprintV1(
                String(repeating: "a", count: 64)
            ),
            fixtureIndex: 0,
            outcome: .failed,
            failure: .wrongOutput,
            exitCode: 0,
            terminationSignal: nil,
            actualOutput: "wrong",
            stderrDetail: "",
            stdoutWasTruncated: false,
            stderrWasTruncated: false,
            processGroupTerminated: true,
            durationMilliseconds: 12,
            passingFingerprint: nil
        )

        // When
        let decoded = try JSONDecoder().decode(
            CandidateValidationReplyV1.self,
            from: JSONEncoder().encode(reply)
        )

        // Then
        XCTAssertEqual(decoded, reply)
    }

    func testMalformedCandidateRequestHasVersionedTypedFailureReply() throws {
        // Given
        let failure = CandidateWorkerProtocolFailureV1(
            code: .invalidRequest
        )
        let reply = CandidateWorkerReplyV1.protocolFailure(failure)

        // When
        let decoded = try JSONDecoder().decode(
            CandidateWorkerReplyV1.self,
            from: JSONEncoder().encode(reply)
        )

        // Then
        XCTAssertEqual(decoded, reply)
        XCTAssertEqual(failure.schemaVersion, 1)
        XCTAssertEqual(failure.code, .invalidRequest)
    }

    func testProbeRequestRoundTrips() throws {
        // Given
        let request = SandboxProbeRequest(
            runID: UUID(),
            deniedReadPath: "/Users/example/private.txt",
            deniedWritePath: "/Users/example/outside.txt",
            limits: .feasibility
        )

        // When
        let decoded = try JSONDecoder().decode(
            SandboxProbeRequest.self,
            from: JSONEncoder().encode(request)
        )

        // Then
        XCTAssertEqual(decoded, request)
    }

    func testProbeResultPayloadExcludesHostPathSentinels() throws {
        // Given
        let deniedReadPath = "/Users/example/private.txt"
        let deniedWritePath = "/Users/example/outside.txt"
        let result = makeResult()

        // When
        let payload = try XCTUnwrap(
            String(data: JSONEncoder().encode(result), encoding: .utf8)
        )

        // Then
        XCTAssertFalse(payload.contains(deniedReadPath))
        XCTAssertFalse(payload.contains(deniedWritePath))
    }

    func testGatePassesWhenEveryBoundaryCheckAndVersionMatch() {
        // Given
        let result = makeResult()

        // When
        let gatePassed = result.gatePassed

        // Then
        XCTAssertTrue(gatePassed)
    }

    func testGatePassRequiresWorkspaceWrite() {
        XCTAssertFalse(makeResult(workspaceWriteSucceeded: false).gatePassed)
    }

    func testGatePassRequiresHostReadDenial() {
        XCTAssertFalse(makeResult(hostReadDenied: false).gatePassed)
    }

    func testGatePassRequiresHostWriteDenial() {
        XCTAssertFalse(makeResult(hostWriteDenied: false).gatePassed)
    }

    func testGatePassRequiresRawNetworkDenial() {
        XCTAssertFalse(makeResult(rawNetworkDenied: false).gatePassed)
    }

    func testGatePassRequiresMediatedNetworkSuccess() {
        XCTAssertFalse(makeResult(mediatedNetworkSucceeded: false).gatePassed)
    }

    func testGatePassRequiresBoundedStandardOutput() {
        XCTAssertFalse(makeResult(stdoutBounded: false).gatePassed)
    }

    func testGatePassRequiresBoundedStandardError() {
        XCTAssertFalse(makeResult(stderrBounded: false).gatePassed)
    }

    func testGatePassRequiresTerminatedTimedOutProcessGroup() {
        XCTAssertFalse(makeResult(timedOutProcessGroupTerminated: false).gatePassed)
    }

    func testGatePassRequiresExpectedPythonVersion() {
        XCTAssertFalse(makeResult(pythonVersion: "3.12.10").gatePassed)
    }

    func testGatePassRequiresExpectedDependencyVersion() {
        XCTAssertFalse(makeResult(dependencyVersion: "3.9").gatePassed)
    }

    private func makeResult(
        pythonVersion: String = "3.12.11",
        dependencyVersion: String = "3.10",
        workspaceWriteSucceeded: Bool = true,
        hostReadDenied: Bool = true,
        hostWriteDenied: Bool = true,
        rawNetworkDenied: Bool = true,
        mediatedNetworkSucceeded: Bool = true,
        stdoutBounded: Bool = true,
        stderrBounded: Bool = true,
        timedOutProcessGroupTerminated: Bool = true
    ) -> SandboxProbeResult {
        SandboxProbeResult(
            runID: UUID(),
            pythonVersion: pythonVersion,
            dependencyVersion: dependencyVersion,
            workspaceWriteSucceeded: workspaceWriteSucceeded,
            hostReadDenied: hostReadDenied,
            hostWriteDenied: hostWriteDenied,
            rawNetworkDenied: rawNetworkDenied,
            mediatedNetworkSucceeded: mediatedNetworkSucceeded,
            stdoutBounded: stdoutBounded,
            stderrBounded: stderrBounded,
            timedOutProcessGroupTerminated: timedOutProcessGroupTerminated
        )
    }
}
