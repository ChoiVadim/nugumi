import Foundation
import NugumiToolAgentCore
import NugumiToolIPC
import NugumiToolWorkerCore

final class ToolWorkerService: NSObject, NugumiToolWorkerProtocol {
    private weak var connection: NSXPCConnection?
    private let probe: SandboxProbe?
    private let coordinator = ProbeRunCoordinator()
    private let candidateValidator: CandidateValidator?
    private let candidateCoordinator = CandidateRunCoordinator()

    init(connection: NSXPCConnection) {
        self.connection = connection
        probe = ToolWorkerRuntime.bundled().map { SandboxProbe(runtime: $0) }
        candidateValidator = ToolWorkerRuntime.candidateRuntime().map {
            CandidateValidator(runtime: $0)
        }
    }

    func runProbe(
        _ requestData: Data,
        withReply reply: @escaping (Data) -> Void
    ) {
        guard let request = try? JSONDecoder().decode(
            SandboxProbeRequest.self,
            from: requestData
        ) else {
            reply(Self.encodedFailure(runID: nil, code: .invalidRequest))
            return
        }

        let accepted = coordinator.start(
            runID: request.runID,
            operation: { [weak self] executionID in
                guard let self else {
                    return .failure(
                        SandboxProbeFailure(
                            runID: request.runID,
                            code: .cancelled
                        )
                    )
                }
                return await execute(request, executionID: executionID)
            },
            reply: { result in
                reply(Self.encoded(result))
            }
        )
        guard accepted else {
            reply(
                Self.encodedFailure(
                    runID: request.runID,
                    code: .invalidRequest
                )
            )
            return
        }
    }

    func cancelProbe(
        _ runID: String,
        withReply reply: @escaping (Bool) -> Void
    ) {
        guard let identifier = UUID(uuidString: runID) else {
            reply(false)
            return
        }
        reply(
            coordinator.cancel(runID: identifier) { [probe] executionID in
                probe?.cancel(runID: executionID)
            }
        )
    }

    func runCandidate(
        _ requestData: Data,
        withReply reply: @escaping (Data) -> Void
    ) {
        guard let request = try? JSONDecoder().decode(
            CandidateValidationRequestV1.self,
            from: requestData
        ) else {
            reply(
                Self.encoded(
                    .protocolFailure(
                        CandidateWorkerProtocolFailureV1(
                            code: .invalidRequest
                        )
                    )
                )
            )
            return
        }
        guard let candidateValidator else {
            reply(
                Self.encoded(
                    .validation(
                    Self.candidateFailure(
                        request,
                        failure: .workerFailure
                    )
                    )
                )
            )
            return
        }
        let accepted = candidateCoordinator.start(
            runID: request.runID,
            operation: { executionID in
                await candidateValidator.validate(
                    request,
                    executionID: executionID
                )
            },
            reply: {
                result in reply(Self.encoded(.validation(result)))
            }
        )
        guard accepted else {
            reply(
                Self.encoded(
                    .validation(
                    Self.candidateFailure(
                        request,
                        failure: .workerFailure
                    )
                    )
                )
            )
            return
        }
    }

    func cancelCandidate(
        _ runID: String,
        withReply reply: @escaping (Bool) -> Void
    ) {
        guard let identifier = UUID(uuidString: runID) else {
            reply(false)
            return
        }
        reply(
            candidateCoordinator.cancel(runID: identifier) {
                [candidateValidator] executionID in
                candidateValidator?.cancel(runID: executionID)
            }
        )
    }

    private func execute(
        _ request: SandboxProbeRequest,
        executionID: UUID
    ) async -> SandboxProbeReply {
        guard let connection, let probe else {
            return .failure(
                SandboxProbeFailure(
                    runID: request.runID,
                    code: .runtimeMissing
                )
            )
        }
        do {
            let fixture = try await ToolWorkerHostBridge.fetchFixture(
                through: connection,
                runID: request.runID
            )
            let result = try await probe.run(
                request: request,
                mediatedFixture: fixture,
                executionID: executionID
            )
            return .success(result)
        } catch let error as SandboxProbeError {
            return .failure(
                SandboxProbeFailure(
                    runID: request.runID,
                    code: code(for: error)
                )
            )
        } catch HostFixtureBridgeError.cancelled {
            return .failure(
                SandboxProbeFailure(
                    runID: request.runID,
                    code: .cancelled
                )
            )
        } catch {
            return .failure(
                SandboxProbeFailure(
                    runID: request.runID,
                    code: .hostProxyRejected
                )
            )
        }
    }

    private func code(for error: SandboxProbeError) -> SandboxProbeFailureCode {
        switch error {
        case .runtimeMissing:
            return .runtimeMissing
        case .launchFailed:
            return .launchFailed
        case .invalidProbeOutput:
            return .invalidProbeOutput
        case .cancelled:
            return .cancelled
        }
    }

    private static func encodedFailure(
        runID: UUID?,
        code: SandboxProbeFailureCode
    ) -> Data {
        encoded(.failure(SandboxProbeFailure(runID: runID, code: code)))
    }

    private static func encoded(_ reply: SandboxProbeReply) -> Data {
        (try? JSONEncoder().encode(reply)) ?? Data()
    }

    private static func encoded(_ reply: CandidateWorkerReplyV1) -> Data {
        (try? JSONEncoder().encode(reply)) ?? Data()
    }

    private static func candidateFailure(
        _ request: CandidateValidationRequestV1,
        failure: ToolAgentFailureCodeV1
    ) -> CandidateValidationReplyV1 {
        CandidateValidationReplyV1(
            runID: request.runID,
            candidateID: request.candidateID,
            fingerprint: request.fingerprint,
            fixtureIndex: nil,
            outcome: .failed,
            failure: failure,
            exitCode: nil,
            terminationSignal: nil,
            actualOutput: nil,
            stderrDetail: nil,
            stdoutWasTruncated: false,
            stderrWasTruncated: false,
            processGroupTerminated: true,
            durationMilliseconds: 0,
            passingFingerprint: nil
        )
    }
}
