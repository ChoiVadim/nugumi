import Foundation
import NugumiToolIPC

public final class CandidateRunCoordinator: @unchecked Sendable {
    public typealias Operation = @Sendable (
        UUID
    ) async -> CandidateValidationReplyV1
    public typealias Reply = @Sendable (CandidateValidationReplyV1) -> Void

    private struct ActiveRun {
        let executionID: UUID
        var task: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var activeRuns: [UUID: ActiveRun] = [:]

    public init() {}

    @discardableResult
    public func start(
        runID: UUID,
        operation: @escaping Operation,
        reply: @escaping Reply
    ) -> Bool {
        let executionID = UUID()
        lock.lock()
        guard activeRuns[runID] == nil else {
            lock.unlock()
            return false
        }
        activeRuns[runID] = ActiveRun(executionID: executionID)
        lock.unlock()

        let task = Task { [weak self] in
            let result = await operation(executionID)
            self?.finish(runID: runID, executionID: executionID)
            reply(result)
        }
        lock.lock()
        guard
            var run = activeRuns[runID],
            run.executionID == executionID
        else {
            lock.unlock()
            task.cancel()
            return true
        }
        run.task = task
        activeRuns[runID] = run
        lock.unlock()
        return true
    }

    @discardableResult
    public func cancel(
        runID: UUID,
        onCancel: @escaping @Sendable (UUID) -> Void
    ) -> Bool {
        lock.lock()
        guard let run = activeRuns.removeValue(forKey: runID) else {
            lock.unlock()
            return false
        }
        lock.unlock()
        onCancel(run.executionID)
        run.task?.cancel()
        return true
    }

    private func finish(runID: UUID, executionID: UUID) {
        lock.lock()
        if activeRuns[runID]?.executionID == executionID {
            activeRuns.removeValue(forKey: runID)
        }
        lock.unlock()
    }
}
