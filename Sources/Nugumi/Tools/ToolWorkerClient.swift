import Foundation
import NugumiToolIPC

enum ToolWorkerClientError: Error, Equatable {
    case cancelled
    case connectionUnavailable
    case invalidReply
    case workerFailure(SandboxProbeFailure)
}

enum ToolWorkerClient {
    typealias ProbeOperation = () async throws -> SandboxProbeResult
    typealias ProbeRequestOperation = (
        SandboxProbeRequest
    ) async throws -> SandboxProbeResult

    static func runProbe() async throws -> SandboxProbeResult {
        try await withSentinels(at: NugumiPaths.root, send: requestProbe)
    }

    static func withSentinels(
        at root: URL,
        send: ProbeRequestOperation
    ) async throws -> SandboxProbeResult {
        let runID = UUID()
        let directory = root
            .appendingPathComponent("ToolWorkerGate", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let readSentinel = directory.appendingPathComponent(
            "read-\(UUID().uuidString)"
        )
        let writeTarget = directory.appendingPathComponent(
            "write-\(UUID().uuidString)"
        )
        try Data(runID.uuidString.utf8).write(to: readSentinel, options: .atomic)
        let request = SandboxProbeRequest(
            runID: runID,
            deniedReadPath: readSentinel.path,
            deniedWritePath: writeTarget.path,
            limits: .feasibility
        )
        return try await send(request)
    }

    static func runAndWriteReport(to url: URL) async -> Int32 {
        await runAndWriteReport(to: url, runProbe: runProbe)
    }

    static func runAndWriteReport(
        to url: URL,
        runProbe: ProbeOperation
    ) async -> Int32 {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let result = try await runProbe()
            let data = try encoder.encode(SandboxProbeGateReport(result: result))
            try data.write(to: url, options: .atomic)
            return result.gatePassed ? 0 : 1
        } catch {
            let failure = SandboxProbeReply.failure(failure(for: error))
            if let data = try? encoder.encode(failure) {
                try? data.write(to: url, options: .atomic)
            }
            return 1
        }
    }

    private static func requestProbe(
        _ request: SandboxProbeRequest
    ) async throws -> SandboxProbeResult {
        let connection = NSXPCConnection(
            serviceName: "com.nugumi.app.tool-worker"
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: NugumiToolWorkerProtocol.self
        )
        connection.exportedInterface = NSXPCInterface(
            with: NugumiToolWorkerHostProtocol.self
        )
        connection.exportedObject = ProbeFixtureProxy()
        let state = ToolWorkerReplyState(connection: connection)
        connection.interruptionHandler = {
            state.resolve(.failure(ToolWorkerClientError.connectionUnavailable))
        }
        connection.invalidationHandler = {
            state.resolve(.failure(ToolWorkerClientError.connectionUnavailable))
        }
        connection.resume()

        let requestData = try JSONEncoder().encode(request)
        return try await withTaskCancellationHandler {
            let replyData = try await withCheckedThrowingContinuation {
                continuation in
                state.install(continuation)
                let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                    state.resolve(
                        .failure(ToolWorkerClientError.connectionUnavailable)
                    )
                }
                guard let worker = proxy as? NugumiToolWorkerProtocol else {
                    state.resolve(
                        .failure(ToolWorkerClientError.connectionUnavailable)
                    )
                    return
                }
                worker.runProbe(requestData) { data in
                    state.resolve(.success(data))
                }
            }
            return try decode(replyData)
        } onCancel: {
            state.resolve(.failure(ToolWorkerClientError.cancelled))
        }
    }

    private static func decode(_ data: Data) throws -> SandboxProbeResult {
        guard let reply = try? JSONDecoder().decode(
            SandboxProbeReply.self,
            from: data
        ) else {
            throw ToolWorkerClientError.invalidReply
        }
        switch reply {
        case let .success(result):
            return result
        case let .failure(failure):
            throw ToolWorkerClientError.workerFailure(failure)
        }
    }

    private static func failure(for error: Error) -> SandboxProbeFailure {
        if case let ToolWorkerClientError.workerFailure(failure) = error {
            return failure
        }
        let code: SandboxProbeFailureCode
        switch error as? ToolWorkerClientError {
        case .cancelled:
            code = .cancelled
        case .invalidReply:
            code = .invalidProbeOutput
        case .connectionUnavailable, .none:
            code = .launchFailed
        case .workerFailure:
            code = .launchFailed
        }
        return SandboxProbeFailure(runID: nil, code: code)
    }
}

private final class ToolWorkerReplyState: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NSXPCConnection
    private var continuation: CheckedContinuation<Data, Error>?
    private var pendingResult: Result<Data, Error>?
    private var completed = false

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    func install(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        if let result = pendingResult {
            pendingResult = nil
            completed = true
            lock.unlock()
            continuation.resume(with: result)
            connection.invalidate()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resolve(_ result: Result<Data, Error>) {
        lock.lock()
        guard !completed, pendingResult == nil else {
            lock.unlock()
            return
        }
        guard let continuation else {
            pendingResult = result
            lock.unlock()
            return
        }
        self.continuation = nil
        completed = true
        lock.unlock()
        continuation.resume(with: result)
        connection.invalidate()
    }
}
