import Foundation
import NugumiToolIPC
import NugumiToolWorkerCore

final class ToolWorkerService: NSObject, NugumiToolWorkerProtocol {
    private struct ActiveRun {
        var task: Task<Void, Never>?
    }

    private weak var connection: NSXPCConnection?
    private let probe: SandboxProbe?
    private let lock = NSLock()
    private var activeRuns: [UUID: ActiveRun] = [:]

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
            reply(encodedFailure(runID: nil, code: .invalidRequest))
            return
        }

        lock.lock()
        guard activeRuns[request.runID] == nil else {
            lock.unlock()
            reply(encodedFailure(runID: request.runID, code: .invalidRequest))
            return
        }
        activeRuns[request.runID] = ActiveRun()
        lock.unlock()

        let task = Task { [weak self] in
            guard let self else { return }
            let replyData = await execute(request)
            removeRun(runID: request.runID)
            reply(replyData)
        }
        lock.lock()
        guard var run = activeRuns[request.runID] else {
            lock.unlock()
            task.cancel()
            return
        }
        run.task = task
        activeRuns[request.runID] = run
        lock.unlock()
    }

    func cancelProbe(
        _ runID: String,
        withReply reply: @escaping (Bool) -> Void
    ) {
        guard let identifier = UUID(uuidString: runID) else {
            reply(false)
            return
        }
        lock.lock()
        guard let run = activeRuns.removeValue(forKey: identifier) else {
            lock.unlock()
            reply(false)
            return
        }
        let task = run.task
        lock.unlock()
        probe?.cancel(runID: identifier)
        task?.cancel()
        reply(true)
    }

    private func execute(_ request: SandboxProbeRequest) async -> Data {
        guard let connection, let probe else {
            return encodedFailure(runID: request.runID, code: .runtimeMissing)
        }
        do {
            let fixture = try await ToolWorkerHostBridge.fetchFixture(
                through: connection,
                runID: request.runID
            )
            let result = try await probe.run(
                request: request,
                mediatedFixture: fixture
            )
            return encoded(.success(result))
        } catch let error as SandboxProbeError {
            return encodedFailure(runID: request.runID, code: code(for: error))
        } catch {
            return encodedFailure(runID: request.runID, code: .hostProxyRejected)
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

    private func removeRun(runID: UUID) {
        lock.lock()
        activeRuns.removeValue(forKey: runID)
        lock.unlock()
    }

    private func encodedFailure(
        runID: UUID?,
        code: SandboxProbeFailureCode
    ) -> Data {
        encoded(.failure(SandboxProbeFailure(runID: runID, code: code)))
    }

    private func encoded(_ reply: SandboxProbeReply) -> Data {
        (try? JSONEncoder().encode(reply)) ?? Data()
    }
}
