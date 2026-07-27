import Foundation
import NugumiToolAgentCore
import NugumiToolIPC

public struct CandidateValidatorRuntime: Sendable {
    public let pythonExecutable: URL
    public let runtimeVersion: String

    public init(pythonExecutable: URL, runtimeVersion: String) {
        self.pythonExecutable = pythonExecutable
        self.runtimeVersion = runtimeVersion
    }
}

public final class CandidateValidator: @unchecked Sendable {
    public static let runtimeVersion = "3.12.11"
    public static let policyVersion = "validation-v1"

    private let runtime: CandidateValidatorRuntime
    private let limits: SandboxProbeLimits
    private let process: BoundedProcess
    private let fileManager: FileManager

    public init(
        runtime: CandidateValidatorRuntime,
        limits: SandboxProbeLimits = .candidateValidation,
        process: BoundedProcess = BoundedProcess(),
        fileManager: FileManager = .default
    ) {
        self.runtime = runtime
        self.limits = limits
        self.process = process
        self.fileManager = fileManager
    }

    public func cancel(runID: UUID) {
        process.cancel(runID: runID)
    }

    public func validate(
        _ request: CandidateValidationRequestV1,
        executionID: UUID
    ) async -> CandidateValidationReplyV1 {
        let started = DispatchTime.now().uptimeNanoseconds
        guard runtime.runtimeVersion == Self.runtimeVersion,
              let expectedFingerprint = try? ToolAgentCandidateFingerprintV1.make(
                  candidate: request.candidate,
                  runtimeVersion: Self.runtimeVersion,
                  policyVersion: Self.policyVersion
              ),
              expectedFingerprint == request.fingerprint else {
            return reply(
                request,
                failure: .invalidCandidate,
                started: started
            )
        }
        guard fileManager.isExecutableFile(
            atPath: runtime.pythonExecutable.path
        ) else {
            return reply(request, failure: .workerFailure, started: started)
        }

        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "NugumiCandidate-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? fileManager.removeItem(at: directory) }
            let script = directory.appendingPathComponent("main.py")
            try Data(request.candidate.source.utf8).write(
                to: script,
                options: [.atomic]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: script.path
            )

            if let syntaxFailure = await compile(
                request,
                directory: directory,
                executionID: executionID,
                started: started
            ) {
                return syntaxFailure
            }
            for (fixtureIndex, fixture) in request.candidate.fixtures.enumerated() {
                if let failure = await execute(
                    request,
                    fixture: fixture,
                    fixtureIndex: fixtureIndex,
                    directory: directory,
                    executionID: executionID,
                    started: started
                ) {
                    return failure
                }
            }
            return reply(
                request,
                outcome: .passed,
                started: started,
                passingFingerprint: request.fingerprint
            )
        } catch BoundedProcessError.cancelled {
            return reply(request, failure: .cancelled, started: started)
        } catch {
            return reply(request, failure: .workerFailure, started: started)
        }
    }

    private func compile(
        _ request: CandidateValidationRequestV1,
        directory: URL,
        executionID: UUID,
        started: UInt64
    ) async -> CandidateValidationReplyV1? {
        do {
            let result = try await process.run(
                command(
                    arguments: ["-I", "-S", "-m", "py_compile", "main.py"],
                    directory: directory,
                    executionID: executionID
                )
            )
            if result.timedOut {
                return reply(
                    request,
                    failure: .timedOut,
                    processResult: result,
                    directory: directory,
                    started: started
                )
            }
            if result.stdoutWasTruncated || result.stderrWasTruncated {
                return reply(
                    request,
                    failure: .outputLimit,
                    processResult: result,
                    directory: directory,
                    started: started
                )
            }
            guard result.exitCode == 0 else {
                return reply(
                    request,
                    failure: .syntaxError,
                    processResult: result,
                    directory: directory,
                    started: started
                )
            }
            return nil
        } catch BoundedProcessError.cancelled {
            return reply(request, failure: .cancelled, started: started)
        } catch {
            return reply(request, failure: .workerFailure, started: started)
        }
    }

    private func execute(
        _ request: CandidateValidationRequestV1,
        fixture: ToolAgentFixtureV1,
        fixtureIndex: Int,
        directory: URL,
        executionID: UUID,
        started: UInt64
    ) async -> CandidateValidationReplyV1? {
        do {
            let result = try await process.run(
                command(
                    arguments: ["-I", "-S", "main.py", fixture.input],
                    directory: directory,
                    executionID: executionID
                )
            )
            let actual = String(data: result.stdout, encoding: .utf8)
                .map(Self.normalizedOutput)
            let expected = Self.normalizedOutput(fixture.expectedOutput)
            let failure: ToolAgentFailureCodeV1?
            if result.timedOut {
                failure = .timedOut
            } else if result.stdoutWasTruncated || result.stderrWasTruncated {
                failure = .outputLimit
            } else if result.exitCode != 0 {
                failure = .runtimeError
            } else if actual == nil {
                failure = .invalidOutput
            } else if actual != expected {
                failure = .wrongOutput
            } else {
                failure = nil
            }
            return failure.map {
                reply(
                    request,
                    fixtureIndex: fixtureIndex,
                    failure: $0,
                    processResult: result,
                    actualOutput: actual,
                    directory: directory,
                    started: started
                )
            }
        } catch BoundedProcessError.cancelled {
            return reply(
                request,
                fixtureIndex: fixtureIndex,
                failure: .cancelled,
                started: started
            )
        } catch {
            return reply(
                request,
                fixtureIndex: fixtureIndex,
                failure: .workerFailure,
                started: started
            )
        }
    }

    private func command(
        arguments: [String],
        directory: URL,
        executionID: UUID
    ) -> BoundedCommand {
        let temporary = directory.appendingPathComponent(
            "tmp",
            isDirectory: true
        )
        try? fileManager.createDirectory(
            at: temporary,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return BoundedCommand(
            runID: executionID,
            executable: runtime.pythonExecutable,
            arguments: arguments,
            workingDirectory: directory,
            environment: [
                "HOME": directory.path,
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "PYTHONHASHSEED": "0",
                "PYTHONIOENCODING": "utf-8",
                "PYTHONUTF8": "1",
                "TMPDIR": temporary.path,
            ],
            limits: limits
        )
    }

}
