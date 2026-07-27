import Foundation
import NugumiToolIPC
import NugumiToolWorkerCore

enum ToolWorkerHostBridge {
    static func fetchFixture(
        through connection: NSXPCConnection,
        runID: UUID
    ) async throws -> Data {
        guard let url = URL(string: "https://example.com/") else {
            throw HostFixtureBridgeError.connectionUnavailable
        }
        let request = ProbeFixtureRequest(
            runID: runID,
            url: url
        )
        return try await HostFixtureBridge.fetch(request: request) {
            requestData,
            completion in
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                completion(.failure(.connectionUnavailable))
            }
            guard let host = proxy as? NugumiToolWorkerHostProtocol else {
                completion(.failure(.connectionUnavailable))
                return
            }
            host.fetchProbeFixture(requestData) { responseData in
                completion(.success(responseData))
            }
        }
    }
}
