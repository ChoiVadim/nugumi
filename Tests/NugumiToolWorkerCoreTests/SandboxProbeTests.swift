import Foundation
import NugumiToolIPC
@testable import NugumiToolWorkerCore
import XCTest

final class SandboxProbeTests: XCTestCase {
    func testEveryBoundaryBooleanIsRequired() {
        let runID = UUID()
        let values: [(Int, SandboxProbeResult)] = [
            (0, result(runID: runID, workspaceWriteSucceeded: false)),
            (1, result(runID: runID, hostReadDenied: false)),
            (2, result(runID: runID, hostWriteDenied: false)),
            (3, result(runID: runID, rawNetworkDenied: false)),
            (4, result(runID: runID, mediatedNetworkSucceeded: false)),
            (5, result(runID: runID, stdoutBounded: false)),
            (6, result(runID: runID, stderrBounded: false)),
            (7, result(runID: runID, timedOutProcessGroupTerminated: false)),
        ]

        for (index, value) in values {
            XCTAssertFalse(value.gatePassed, "boundary index \(index) must be required")
        }
    }

    func testExactPythonVersionIsRequired() {
        XCTAssertFalse(result(pythonVersion: "3.12.10").gatePassed)
    }

    func testExactDependencyVersionIsRequired() {
        XCTAssertFalse(result(dependencyVersion: "3.9").gatePassed)
    }

    func testSanitizedEnvironmentHasExactlySixAllowlistedKeys() {
        let environment = SandboxProbe.sanitizedEnvironment(
            home: URL(fileURLWithPath: "/container/workspace"),
            runtimeBin: URL(fileURLWithPath: "/runtime/bin"),
            temporaryDirectory: URL(fileURLWithPath: "/container/tmp")
        )

        XCTAssertEqual(
            Set(environment.keys),
            [
                "HOME",
                "PATH",
                "LANG",
                "PYTHONNOUSERSITE",
                "PYTHONDONTWRITEBYTECODE",
                "TMPDIR",
            ]
        )
        XCTAssertEqual(environment.count, 6)
        XCTAssertEqual(environment["HOME"], "/container/workspace")
        XCTAssertEqual(environment["PATH"], "/runtime/bin")
        XCTAssertEqual(environment["TMPDIR"], "/container/tmp")
        XCTAssertNil(environment["USER"])
        XCTAssertNil(environment["SSH_AUTH_SOCK"])
        XCTAssertNil(environment["OPENAI_API_KEY"])
    }

    func testMacOSMemoryLimitIsNotRepresentedAsApplied() async throws {
        let command = BoundedCommand(
            runID: UUID(),
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: ["HOME": FileManager.default.temporaryDirectory.path],
            limits: .feasibility
        )

        let result = try await BoundedProcess().run(command)

        XCTAssertFalse(result.memoryLimitApplied)
    }

    private func result(
        runID: UUID = UUID(),
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
            runID: runID,
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
