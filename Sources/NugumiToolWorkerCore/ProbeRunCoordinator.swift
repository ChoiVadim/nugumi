import Foundation
import NugumiToolIPC

public final class ProbeRunCoordinator: @unchecked Sendable {
    public typealias Operation = @Sendable (UUID) async -> SandboxProbeReply
    public typealias Reply = @Sendable (SandboxProbeReply) -> Void

    private struct ActiveRun {
        let generation: UUID
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
        let generation = UUID()
        lock.lock()
        guard activeRuns[runID] == nil else {
            lock.unlock()
            return false
        }
        activeRuns[runID] = ActiveRun(generation: generation)
        lock.unlock()

        let task = Task { [weak self] in
            let result = await operation(generation)
            self?.finish(runID: runID, generation: generation)
            reply(result)
        }
        lock.lock()
        guard
            var run = activeRuns[runID],
            run.generation == generation
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
        onCancel(run.generation)
        run.task?.cancel()
        return true
    }

    private func finish(runID: UUID, generation: UUID) {
        lock.lock()
        if activeRuns[runID]?.generation == generation {
            activeRuns.removeValue(forKey: runID)
        }
        lock.unlock()
    }
}
