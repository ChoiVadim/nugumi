import Foundation
import NugumiToolIPC

enum ToolWorkerHostBridgeError: Error {
    case connectionUnavailable
    case rejected
}

enum ToolWorkerHostBridge {
    static func fetchFixture(
        through connection: NSXPCConnection,
        runID: UUID
    ) async throws -> Data {
        guard let url = URL(string: "https://example.com/") else {
            throw ToolWorkerHostBridgeError.connectionUnavailable
        }
        let request = ProbeFixtureRequest(
            runID: runID,
            url: url
        )
        let requestData = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: error)
            }
            guard let host = proxy as? NugumiToolWorkerHostProtocol else {
                continuation.resume(
                    throwing: ToolWorkerHostBridgeError.connectionUnavailable
                )
                return
            }
            host.fetchProbeFixture(requestData) { responseData in
                do {
                    let response = try JSONDecoder().decode(
                        ProbeFixtureResponse.self,
                        from: responseData
                    )
                    guard
                        response.accepted,
                        response.statusCode == 200
                    else {
                        throw ToolWorkerHostBridgeError.rejected
                    }
                    continuation.resume(returning: response.body)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
