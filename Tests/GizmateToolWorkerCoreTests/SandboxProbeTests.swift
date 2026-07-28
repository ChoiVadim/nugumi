import Foundation
import GizmateToolIPC
@testable import GizmateToolWorkerCore
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

    func testActualPythonProbeOnlyAcceptsPermissionErrnosAsNetworkDenial() async throws {
        let classifications = try await actualProbeNetworkClassifications()

        XCTAssertEqual(
            classifications,
            [
                "EACCES": true,
                "ECONNREFUSED": false,
                "EHOSTUNREACH": false,
                "ENETUNREACH": false,
                "EPERM": true,
                "ETIMEDOUT": false,
                "gaierror": false,
            ]
        )
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

    private func actualProbeNetworkClassifications() async throws -> [String: Bool] {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repository.appendingPathComponent(
            "Sources/GizmateToolWorker/Resources/tool_worker_probe.py"
        )
        let python = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".local/share/uv/python/cpython-3.12.11-macos-aarch64-none/bin/python3.12"
            )
        let source = """
        import errno, importlib.util, json, platform, socket, sys
        assert platform.python_version() == "3.12.11"
        spec = importlib.util.spec_from_file_location("tool_worker_probe", sys.argv[1])
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        cases = {
            "EPERM": OSError(errno.EPERM, "injected"),
            "EACCES": OSError(errno.EACCES, "injected"),
            "ETIMEDOUT": OSError(errno.ETIMEDOUT, "injected"),
            "ECONNREFUSED": OSError(errno.ECONNREFUSED, "injected"),
            "EHOSTUNREACH": OSError(errno.EHOSTUNREACH, "injected"),
            "ENETUNREACH": OSError(errno.ENETUNREACH, "injected"),
            "gaierror": socket.gaierror(socket.EAI_NONAME, "injected"),
        }
        report = {}
        for name, injected in cases.items():
            def reject(address, timeout, error=injected):
                assert address == ("127.0.0.1", 9)
                assert timeout == 2
                raise error
            module.socket.create_connection = reject
            report[name] = module.raw_network_is_denied()
        print(json.dumps(report, sort_keys=True))
        """
        let command = BoundedCommand(
            runID: UUID(),
            executable: python,
            arguments: ["-c", source, script.path],
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: SandboxProbe.sanitizedEnvironment(
                home: FileManager.default.temporaryDirectory,
                runtimeBin: python.deletingLastPathComponent(),
                temporaryDirectory: FileManager.default.temporaryDirectory
            ),
            limits: .feasibility
        )
        let output = try await BoundedProcess().run(command)
        XCTAssertEqual(output.exitCode, 0, String(decoding: output.stderr, as: UTF8.self))
        return try JSONDecoder().decode([String: Bool].self, from: output.stdout)
    }
}
