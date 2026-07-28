import Foundation

enum ToolWorkerReplyEvent {
    case reply(Data)
    case remoteProxyError
    case interruption
    case invalidation
    case cancellation

    var result: Result<Data, Error> {
        switch self {
        case let .reply(data):
            return .success(data)
        case .remoteProxyError, .interruption, .invalidation:
            return .failure(ToolWorkerClientError.connectionUnavailable)
        case .cancellation:
            return .failure(ToolWorkerClientError.cancelled)
        }
    }
}

final class ToolWorkerReplyCoordinator: @unchecked Sendable {
    typealias Completion = (Result<Data, Error>) -> Void

    private let lock = NSLock()
    private let invalidate: () -> Void
    private var completion: Completion?
    private var pendingResult: Result<Data, Error>?
    private var completed = false

    init(invalidate: @escaping () -> Void) {
        self.invalidate = invalidate
    }

    func install(_ completion: @escaping Completion) {
        lock.lock()
        guard
            self.completion == nil,
            !completed || pendingResult != nil
        else {
            lock.unlock()
            return
        }
        guard let pendingResult else {
            self.completion = completion
            lock.unlock()
            return
        }
        self.pendingResult = nil
        lock.unlock()
        completion(pendingResult)
    }

    func receive(_ event: ToolWorkerReplyEvent) {
        let result = event.result
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let completion = self.completion
        self.completion = nil
        if completion == nil {
            pendingResult = result
        }
        lock.unlock()

        invalidate()
        completion?(result)
    }
}
