import Foundation
import NugumiToolIPC
import NugumiToolWorkerCore

final class ToolWorkerService: NSObject, NugumiToolWorkerProtocol {
    private weak var connection: NSXPCConnection?
    private let probe: SandboxProbe?
    private let coordinator = ProbeRunCoordinator()

    init(connection: NSXPCConnection) {
        self.connection = connection
        probe = ToolWorkerRuntime.bundled().map { SandboxProbe(runtime: $0) }
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
}
