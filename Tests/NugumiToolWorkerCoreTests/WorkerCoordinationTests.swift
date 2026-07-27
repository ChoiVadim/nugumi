import Foundation
import NugumiToolAgentCore
import NugumiToolIPC
@testable import NugumiToolWorkerCore
import XCTest

final class WorkerCoordinationTests: XCTestCase {
    func testCandidateCoordinatorRejectsDuplicateAndCancelsAcceptedRun() async {
        let coordinator = CandidateRunCoordinator()
        let runID = UUID()
        let operation = ManualAsyncValue<CandidateValidationReplyV1>()
        let execution = ManualAsyncValue<UUID>()
        let cancelledExecution = ManualAsyncValue<UUID>()
        let replies = CandidateReplyRecorder()

        XCTAssertTrue(
            coordinator.start(
                runID: runID,
                operation: { executionID in
                    execution.resolve(executionID)
                    return await operation.value()
                },
                reply: { replies.record($0) }
            )
        )
        let executionID = await execution.value()
        await operation.waitUntilRequested()
        XCTAssertFalse(
            coordinator.start(
                runID: runID,
                operation: { _ in self.candidateFailure(runID: runID) },
                reply: { replies.record($0) }
            )
        )

        XCTAssertTrue(
            coordinator.cancel(runID: runID) {
                cancelledExecution.resolve($0)
            }
        )
        let cancelledExecutionID = await cancelledExecution.value()
        XCTAssertEqual(cancelledExecutionID, executionID)
        operation.resolve(candidateFailure(runID: runID, failure: .cancelled))
        let firstReply = await replies.waitForFirst()
        XCTAssertEqual(firstReply.failure, .cancelled)
        XCTAssertFalse(coordinator.cancel(runID: runID, onCancel: { _ in }))
    }

    func testStaleCompletionCannotEraseReusedRun() async throws {
        let coordinator = ProbeRunCoordinator()
        let runID = UUID()
        let oldOperation = ManualAsyncValue<SandboxProbeReply>()
        let oldReply = ManualAsyncValue<SandboxProbeReply>()
        let oldExecution = ManualAsyncValue<UUID>()
        let cancelledOldExecution = ManualAsyncValue<UUID>()

        XCTAssertTrue(
            coordinator.start(
                runID: runID,
                operation: { executionID in
                    oldExecution.resolve(executionID)
                    return await oldOperation.value()
                },
                reply: { oldReply.resolve($0) }
            )
        )
        let oldExecutionID = await oldExecution.value()
        await oldOperation.waitUntilRequested()
        XCTAssertTrue(
            coordinator.cancel(runID: runID) {
                cancelledOldExecution.resolve($0)
            }
        )
        let cancelledOldID = await cancelledOldExecution.value()
        XCTAssertEqual(cancelledOldID, oldExecutionID)

        let newOperation = ManualAsyncValue<SandboxProbeReply>()
        let newReply = ManualAsyncValue<SandboxProbeReply>()
        let newExecution = ManualAsyncValue<UUID>()
        let cancelledNewExecution = ManualAsyncValue<UUID>()
        XCTAssertTrue(
            coordinator.start(
                runID: runID,
                operation: { executionID in
                    newExecution.resolve(executionID)
                    return await newOperation.value()
                },
                reply: { newReply.resolve($0) }
            )
        )
        let newExecutionID = await newExecution.value()
        XCTAssertNotEqual(newExecutionID, oldExecutionID)
        await newOperation.waitUntilRequested()

        oldOperation.resolve(failure(runID: runID, code: .cancelled))
        _ = await oldReply.value()

        XCTAssertTrue(
            coordinator.cancel(runID: runID) {
                cancelledNewExecution.resolve($0)
            }
        )
        let cancelledNewID = await cancelledNewExecution.value()
        XCTAssertEqual(cancelledNewID, newExecutionID)
        newOperation.resolve(failure(runID: runID, code: .cancelled))
        _ = await newReply.value()
    }

    func testCancellationWithWithheldHostReplyRepliesExactlyOnce() async throws {
        let coordinator = ProbeRunCoordinator()
        let runID = UUID()
        let host = HostCompletionCapture()
        let replies = ReplyRecorder()
        let request = ProbeFixtureRequest(
            runID: runID,
            url: try XCTUnwrap(URL(string: "https://example.com/"))
        )

        XCTAssertTrue(
            coordinator.start(
                runID: runID,
                operation: { _ in
                    do {
                        _ = try await HostFixtureBridge.fetch(request: request) {
                            requestData,
                            completion in
                            host.store(requestData: requestData, completion: completion)
                        }
                        return self.failure(runID: runID, code: .invalidProbeOutput)
                    } catch HostFixtureBridgeError.cancelled {
                        return self.failure(runID: runID, code: .cancelled)
                    } catch {
                        return self.failure(runID: runID, code: .hostProxyRejected)
                    }
                },
                reply: { replies.record($0) }
            )
        )
        let completion = await host.waitForCompletion()

        XCTAssertTrue(coordinator.cancel(runID: runID, onCancel: { _ in }))
        let reply = await replies.waitForFirst()
        XCTAssertEqual(reply, failure(runID: runID, code: .cancelled))

        completion(
            .success(
                try JSONEncoder().encode(
                    ProbeFixtureResponse(
                        accepted: true,
                        statusCode: 200,
                        body: Data("<!doctype html>".utf8)
                    )
                )
            )
        )
        XCTAssertEqual(replies.count, 1)
    }

    private func failure(
        runID: UUID,
        code: SandboxProbeFailureCode
    ) -> SandboxProbeReply {
        .failure(SandboxProbeFailure(runID: runID, code: code))
    }

    private func candidateFailure(
        runID: UUID,
        failure: ToolAgentFailureCodeV1 = .workerFailure
    ) -> CandidateValidationReplyV1 {
        CandidateValidationReplyV1(
            runID: runID,
            candidateID: UUID(),
            fingerprint: ToolAgentFingerprintV1(
                String(repeating: "a", count: 64)
            ),
            fixtureIndex: nil,
            outcome: .failed,
            failure: failure,
            exitCode: nil,
            terminationSignal: nil,
            actualOutput: nil,
            stderrDetail: nil,
            stdoutWasTruncated: false,
            stderrWasTruncated: false,
            processGroupTerminated: true,
            durationMilliseconds: 0,
            passingFingerprint: nil
        )
    }
}

private final class ManualAsyncValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var valueContinuation: CheckedContinuation<Value, Never>?
    private var pendingValue: Value?
    private var requestedContinuations: [CheckedContinuation<Void, Never>] = []

    func value() async -> Value {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let pendingValue {
                self.pendingValue = nil
                lock.unlock()
                continuation.resume(returning: pendingValue)
                return
            }
            valueContinuation = continuation
            let waiters = requestedContinuations
            requestedContinuations.removeAll()
            lock.unlock()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilRequested() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard valueContinuation == nil else {
                lock.unlock()
                continuation.resume()
                return
            }
            requestedContinuations.append(continuation)
            lock.unlock()
        }
    }

    func resolve(_ value: Value) {
        lock.lock()
        let continuation = valueContinuation
        valueContinuation = nil
        if continuation == nil {
            pendingValue = value
        }
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

private final class HostCompletionCapture: @unchecked Sendable {
    typealias Completion = (
        Result<Data, HostFixtureBridgeError>
    ) -> Void

    private let lock = NSLock()
    private var completion: Completion?
    private var waiters: [CheckedContinuation<Completion, Never>] = []

    func store(requestData: Data, completion: @escaping Completion) {
        XCTAssertNoThrow(
            try JSONDecoder().decode(ProbeFixtureRequest.self, from: requestData)
        )
        lock.lock()
        self.completion = completion
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume(returning: completion) }
    }

    func waitForCompletion() async -> Completion {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard let completion else {
                waiters.append(continuation)
                lock.unlock()
                return
            }
            lock.unlock()
            continuation.resume(returning: completion)
        }
    }
}

private final class ReplyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [SandboxProbeReply] = []
    private var waiters: [CheckedContinuation<SandboxProbeReply, Never>] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return replies.count
    }

    func record(_ reply: SandboxProbeReply) {
        lock.lock()
        replies.append(reply)
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume(returning: reply) }
    }

    func waitForFirst() async -> SandboxProbeReply {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard let first = replies.first else {
                waiters.append(continuation)
                lock.unlock()
                return
            }
            lock.unlock()
            continuation.resume(returning: first)
        }
    }
}

private final class CandidateReplyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [CandidateValidationReplyV1] = []
    private var waiters: [
        CheckedContinuation<CandidateValidationReplyV1, Never>
    ] = []

    func record(_ reply: CandidateValidationReplyV1) {
        lock.lock()
        replies.append(reply)
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume(returning: reply) }
    }

    func waitForFirst() async -> CandidateValidationReplyV1 {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard let first = replies.first else {
                waiters.append(continuation)
                lock.unlock()
                return
            }
            lock.unlock()
            continuation.resume(returning: first)
        }
    }
}
