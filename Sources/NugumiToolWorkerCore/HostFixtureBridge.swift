import Foundation
import NugumiToolIPC

public enum HostFixtureBridgeError: Error, Equatable, Sendable {
    case cancelled
    case connectionUnavailable
    case invalidResponse
    case rejected
}

public enum HostFixtureBridge {
    public typealias Completion = (
        Result<Data, HostFixtureBridgeError>
    ) -> Void
    public typealias Sender = (Data, @escaping Completion) -> Void

    public static func fetch(
        request: ProbeFixtureRequest,
        send: @escaping Sender
    ) async throws -> Data {
        let requestData = try JSONEncoder().encode(request)
        let state = HostFixtureContinuation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                guard !Task.isCancelled else {
                    state.resolve(.failure(.cancelled))
                    return
                }
                send(requestData) { response in
                    state.resolve(decode(response))
                }
            }
        } onCancel: {
            state.resolve(.failure(.cancelled))
        }
    }

    private static func decode(
        _ response: Result<Data, HostFixtureBridgeError>
    ) -> Result<Data, HostFixtureBridgeError> {
        switch response {
        case let .failure(error):
            return .failure(error)
        case let .success(responseData):
            guard
                let decoded = try? JSONDecoder().decode(
                    ProbeFixtureResponse.self,
                    from: responseData
                )
            else {
                return .failure(.invalidResponse)
            }
            guard decoded.accepted, decoded.statusCode == 200 else {
                return .failure(.rejected)
            }
            return .success(decoded.body)
        }
    }
}

private final class HostFixtureContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var pendingResult: Result<Data, HostFixtureBridgeError>?
    private var isFinished = false

    func install(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        if let result = pendingResult {
            pendingResult = nil
            isFinished = true
            lock.unlock()
            resume(continuation, with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resolve(_ result: Result<Data, HostFixtureBridgeError>) {
        lock.lock()
        guard !isFinished, pendingResult == nil else {
            lock.unlock()
            return
        }
        guard let continuation else {
            pendingResult = result
            lock.unlock()
            return
        }
        self.continuation = nil
        isFinished = true
        lock.unlock()
        resume(continuation, with: result)
    }

    private func resume(
        _ continuation: CheckedContinuation<Data, Error>,
        with result: Result<Data, HostFixtureBridgeError>
    ) {
        switch result {
        case let .success(data):
            continuation.resume(returning: data)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}
