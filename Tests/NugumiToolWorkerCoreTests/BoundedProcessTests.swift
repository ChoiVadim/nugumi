import Darwin
import Foundation
import XCTest
@testable import NugumiToolWorkerCore
import NugumiToolIPC

final class BoundedProcessTests: XCTestCase {
    func testOutputIsCappedWhilePipeStillDrains() async throws {
        // Given
        let command = BoundedCommand(
            runID: UUID(),
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "yes x | head -c 131072"],
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: ["HOME": FileManager.default.temporaryDirectory.path],
            limits: .feasibility
        )

        // When
        let result = try await BoundedProcess().run(command)

        // Then
        XCTAssertEqual(result.stdout.count, SandboxProbeLimits.feasibility.stdoutBytes)
        XCTAssertTrue(result.stdoutWasTruncated)
    }

    func testTimeoutKillsSpawnedChild() async throws {
        // Given
        let command = BoundedCommand(
            runID: UUID(),
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 60 & child=$!; echo $child; wait"],
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: ["HOME": FileManager.default.temporaryDirectory.path],
            limits: SandboxProbeLimits(
                wallSeconds: 1,
                cpuSeconds: 2,
                addressSpaceBytes: 256 * 1_024 * 1_024,
                fileBytes: 4 * 1_024 * 1_024,
                stdoutBytes: 64 * 1_024,
                stderrBytes: 64 * 1_024
            )
        )

        // When
        let result = try await BoundedProcess().run(command)

        // Then
        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(result.processGroupTerminated)
        let childPID = try XCTUnwrap(
            Int32(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        )
        errno = 0
        XCTAssertEqual(Darwin.kill(childPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}
