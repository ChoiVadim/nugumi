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
        let state = ToolWorkerReplyCoordinator {
            connection.invalidate()
        }
        connection.interruptionHandler = {
            state.receive(.interruption)
        }
        connection.invalidationHandler = {
            state.receive(.invalidation)
        }
        connection.resume()

        let requestData = try JSONEncoder().encode(request)
        return try await withTaskCancellationHandler {
            let replyData: Data = try await withCheckedThrowingContinuation {
                continuation in
                state.install { continuation.resume(with: $0) }
                guard !Task.isCancelled else {
                    state.receive(.cancellation)
                    return
                }
                let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                    state.receive(.remoteProxyError)
                }
                guard let worker = proxy as? NugumiToolWorkerProtocol else {
                    state.receive(.remoteProxyError)
                    return
                }
                worker.runProbe(requestData) { data in
                    state.receive(.reply(data))
                }
            }
            return try decode(replyData)
        } onCancel: {
            state.receive(.cancellation)
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
