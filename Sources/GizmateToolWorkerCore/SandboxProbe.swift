import Foundation
import GizmateToolIPC

public struct SandboxProbeRuntime: Sendable {
    public let pythonExecutable: URL
    public let script: URL
    public let sitePackages: URL

    public init(pythonExecutable: URL, script: URL, sitePackages: URL) {
        self.pythonExecutable = pythonExecutable
        self.script = script
        self.sitePackages = sitePackages
    }
}

public enum SandboxProbeError: Error, Equatable, Sendable {
    case runtimeMissing
    case launchFailed
    case invalidProbeOutput
    case cancelled
}

public final class SandboxProbe: @unchecked Sendable {
    private struct ExecutionContext {
        let request: SandboxProbeRequest
        let executionID: UUID
        let workspace: URL
        let fixture: URL
    }

    private let runtime: SandboxProbeRuntime
    private let process: BoundedProcess
    private let fileManager: FileManager

    public init(
        runtime: SandboxProbeRuntime,
        process: BoundedProcess = BoundedProcess(),
        fileManager: FileManager = .default
    ) {
        self.runtime = runtime
        self.process = process
        self.fileManager = fileManager
    }

    public static func sanitizedEnvironment(
        home: URL,
        runtimeBin: URL,
        temporaryDirectory: URL
    ) -> [String: String] {
        [
            "HOME": home.path,
            "PATH": runtimeBin.path,
            "LANG": "en_US.UTF-8",
            "PYTHONNOUSERSITE": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            "TMPDIR": temporaryDirectory.path,
        ]
    }

    public func run(
        request: SandboxProbeRequest,
        mediatedFixture: Data,
        executionID: UUID
    ) async throws -> SandboxProbeResult {
        try requireRuntime()
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent(
                "gizmate-tool-probe-\(executionID.uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        let fixture = workspace.appendingPathComponent("mediated-fixture.html")
        try mediatedFixture.write(to: fixture, options: .atomic)
        let context = ExecutionContext(
            request: request,
            executionID: executionID,
            workspace: workspace,
            fixture: fixture
        )
        let normal = try await runMode(
            "normal",
            context: context
        )
        guard normal.exitCode == 0, !normal.timedOut else {
            throw SandboxProbeError.invalidProbeOutput
        }

        let output: PythonProbeOutput
        do {
            output = try JSONDecoder().decode(PythonProbeOutput.self, from: normal.stdout)
        } catch {
            throw SandboxProbeError.invalidProbeOutput
        }

        let timeout = try await runMode(
            "timeout",
            context: context,
            wallSeconds: 1
        )
        return SandboxProbeResult(
            runID: request.runID,
            pythonVersion: output.pythonVersion,
            dependencyVersion: output.dependencyVersion,
            workspaceWriteSucceeded: output.workspaceWriteSucceeded,
            hostReadDenied: output.hostReadDenied,
            hostWriteDenied: output.hostWriteDenied,
            rawNetworkDenied: output.rawNetworkDenied,
            mediatedNetworkSucceeded: output.mediatedNetworkSucceeded,
            stdoutBounded: normal.stdout.count <= request.limits.stdoutBytes
                && !normal.stdoutWasTruncated,
            stderrBounded: normal.stderr.count <= request.limits.stderrBytes
                && !normal.stderrWasTruncated,
            timedOutProcessGroupTerminated: timeout.timedOut
                && timeout.processGroupTerminated
        )
    }

    public func cancel(runID: UUID) {
        process.cancel(runID: runID)
    }

    private func requireRuntime() throws {
        guard
            fileManager.isExecutableFile(atPath: runtime.pythonExecutable.path),
            fileManager.fileExists(atPath: runtime.script.path),
            fileManager.fileExists(atPath: runtime.sitePackages.path)
        else {
            throw SandboxProbeError.runtimeMissing
        }
    }

    private func runMode(
        _ mode: String,
        context: ExecutionContext,
        wallSeconds: Int? = nil
    ) async throws -> BoundedProcessResult {
        let limits = wallSeconds.map {
            SandboxProbeLimits(
                wallSeconds: $0,
                cpuSeconds: context.request.limits.cpuSeconds,
                addressSpaceBytes: context.request.limits.addressSpaceBytes,
                fileBytes: context.request.limits.fileBytes,
                stdoutBytes: context.request.limits.stdoutBytes,
                stderrBytes: context.request.limits.stderrBytes
            )
        } ?? context.request.limits
        let command = BoundedCommand(
            runID: context.executionID,
            executable: runtime.pythonExecutable,
            arguments: [
                runtime.script.path,
                mode,
                runtime.sitePackages.path,
                context.fixture.path,
                context.request.deniedReadPath,
                context.request.deniedWritePath,
            ],
            workingDirectory: context.workspace,
            environment: Self.sanitizedEnvironment(
                home: context.workspace,
                runtimeBin: runtime.pythonExecutable.deletingLastPathComponent(),
                temporaryDirectory: context.workspace
            ),
            limits: limits
        )
        do {
            return try await process.run(command)
        } catch BoundedProcessError.cancelled {
            throw SandboxProbeError.cancelled
        } catch {
            throw SandboxProbeError.launchFailed
        }
    }
}
