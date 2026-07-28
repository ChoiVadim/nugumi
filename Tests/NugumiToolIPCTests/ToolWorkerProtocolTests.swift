import Foundation
import NugumiToolAgentCore
import XCTest
@testable import NugumiToolIPC

final class ToolWorkerProtocolTests: XCTestCase {
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
