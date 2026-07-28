import Darwin
import Foundation
import XCTest
@testable import GizmateToolWorkerCore
import GizmateToolIPC

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

    func testStandardErrorIsCappedWhilePipeStillDrains() async throws {
        // Given
        let command = BoundedCommand(
            runID: UUID(),
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "yes e | head -c 131072 >&2"],
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: ["HOME": FileManager.default.temporaryDirectory.path],
            limits: .feasibility
        )

        // When
        let result = try await BoundedProcess().run(command)

        // Then
        XCTAssertEqual(result.stderr.count, SandboxProbeLimits.feasibility.stderrBytes)
        XCTAssertTrue(result.stderrWasTruncated)
        XCTAssertFalse(result.timedOut)
    }

    func testExplicitCancellationKillsKnownDescendant() async throws {
        // Given
        let process = BoundedProcess()
        let runID = UUID()
        let fifo = try ProcessPIDFIFO()
        let command = cancellationCommand(runID: runID, fifoURL: fifo.url)
        let runTask = Task {
            try await process.run(command)
        }
        defer { runTask.cancel() }
        let childPID = try await fifo.readPID()

        // When
        process.cancel(runID: runID)

        // Then
        await assertCancelled(runTask)
        assertProcessIsGone(childPID)
    }

    func testTaskCancellationKillsKnownDescendant() async throws {
        // Given
        let process = BoundedProcess()
        let runID = UUID()
        let fifo = try ProcessPIDFIFO()
        let command = cancellationCommand(runID: runID, fifoURL: fifo.url)
        let runTask = Task {
            try await process.run(command)
        }
        defer { runTask.cancel() }
        let childPID = try await fifo.readPID()

        // When
        runTask.cancel()

        // Then
        await assertCancelled(runTask)
        assertProcessIsGone(childPID)
    }

    func testMissingExecutableReturnsENOENT() async throws {
        // Given
        let command = BoundedCommand(
            runID: UUID(),
            executable: URL(fileURLWithPath: "/definitely/missing/gizmate-tool"),
            arguments: [],
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: ["HOME": FileManager.default.temporaryDirectory.path],
            limits: .feasibility
        )

        // When
        do {
            _ = try await BoundedProcess().run(command)
            XCTFail("Expected spawn to fail")
        } catch let error as BoundedProcessError {
            // Then
            XCTAssertEqual(error, .spawn(errno: ENOENT))
        }
    }

    private func cancellationCommand(runID: UUID, fifoURL: URL) -> BoundedCommand {
        BoundedCommand(
            runID: runID,
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "sleep 60 & child=$!; printf '%s\\n' \"$child\" > \"$1\"; wait",
                "gizmate-cancel-test",
                fifoURL.path,
            ],
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: ["HOME": FileManager.default.temporaryDirectory.path],
            limits: SandboxProbeLimits(
                wallSeconds: 3,
                cpuSeconds: 2,
                addressSpaceBytes: 256 * 1_024 * 1_024,
                fileBytes: 4 * 1_024 * 1_024,
                stdoutBytes: 64 * 1_024,
                stderrBytes: 64 * 1_024
            )
        )
    }

    private func assertCancelled(
        _ task: Task<BoundedProcessResult, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("Expected cancellation", file: file, line: line)
        } catch let error as BoundedProcessError {
            XCTAssertEqual(error, .cancelled, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertProcessIsGone(
        _ pid: pid_t,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        errno = 0
        XCTAssertEqual(Darwin.kill(pid, 0), -1, file: file, line: line)
        XCTAssertEqual(errno, ESRCH, file: file, line: line)
    }
}
