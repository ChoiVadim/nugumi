import Foundation
import XCTest
@testable import GizmateToolAgentCore

final class ToolBuildSupervisorTests: XCTestCase {
    func testPersistsCreatedBeforeLaunchingProcess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try ToolBuildStore(directoryURL: directory)
        let runID = UUID()
        let request = ToolBuildRequestV1(
            runID: runID,
            description: "uppercase copied text",
            budgets: .preview,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let launchedAfterPersist = LockedFlag()
        let supervisor = ToolBuildSupervisor(
            store: store,
            runtimeVersion: "3.12.11",
            policyVersion: "validation-v1",
            makeProcess: { _ in
                let record = try await store.record(runID: runID)
                launchedAfterPersist.set(record.state == .created)
                throw ToolAgentFailureCodeV1.workerFailure
            },
            model: { _ in .error(.workerFailure) },
            validation: { _ in throw ToolAgentFailureCodeV1.workerFailure }
        )

        do {
            _ = try await supervisor.build(request)
            XCTFail("Expected worker failure")
        } catch {
            XCTAssertEqual(error as? ToolAgentFailureCodeV1, .workerFailure)
        }

        XCTAssertTrue(launchedAfterPersist.value)
        let record = try await store.record(runID: runID)
        XCTAssertEqual(record.request, request)
        XCTAssertEqual(record.state, .failed)
    }

    func testRunsExactRepairPathAndPersistsImmutableAttempts() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try ToolBuildStore(directoryURL: directory)
        let script = try RepairScript()
        let validator = ValidationStub()
        let candidateIDs = UUIDSequence([
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        ])
        let request = ToolBuildRequestV1(description: "uppercase copied text")
        let supervisor = ToolBuildSupervisor(
            store: store,
            runtimeVersion: "3.12.11",
            policyVersion: "validation-v1",
            makeProcess: { _ in script.client() },
            model: { _ in .text(#"{"version":1,"action":"finalText","text":"continue"}"#) },
            validation: { input in try await validator.validate(input) },
            makeCandidateID: { candidateIDs.next() }
        )

        let result = try await supervisor.build(request)
        let record = try await store.record(runID: request.runID)

        XCTAssertEqual(result.candidateID, candidateIDs.values[1])
        XCTAssertEqual(
            record.events.map(\.state),
            [.created, .understanding, .writing, .testing, .diagnosing, .repairing,
             .writing, .testing, .verifying, .candidateReady]
        )
        XCTAssertEqual(record.counters, .init(modelTurns: 1, toolCalls: 5, repairs: 1))
        XCTAssertEqual(record.attempts.map(\.candidate.source), ["print(input())", "print(input().upper())"])
        XCTAssertEqual(record.attempts.map(\.candidateID), candidateIDs.values)
        XCTAssertEqual(record.validations.map(\.report.outcome), [.failed, .passed])
        XCTAssertEqual(record.result, result)
        XCTAssertNil(record.failure)
        let didFinish = await script.didFinish
        let didCancel = await script.didCancel
        XCTAssertTrue(didFinish)
        XCTAssertFalse(didCancel)
    }

    func testDrivesRealPiGateSidecarThroughRepair() async throws {
        let root = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        let nodeURL = root.appendingPathComponent(
            ".build/tool-agent-runtime/arm64/node"
        )
        let gateURL = root.appendingPathComponent("ToolAgent/dist/gate.mjs")
        guard FileManager.default.isExecutableFile(atPath: nodeURL.path),
              FileManager.default.isReadableFile(atPath: gateURL.path) else {
            throw XCTSkip("Prepared Pi gate runtime is unavailable")
        }

        let store = try temporaryStore()
        let validator = ValidationStub()
        let request = ToolBuildRequestV1(
            description: "make copied text uppercase."
        )
        let supervisor = ToolBuildSupervisor(
            store: store,
            runtimeVersion: "3.12.11",
            policyVersion: "validation-v1",
            makeProcess: { _ in
                try JSONLProcess.launch(
                    executableURL: nodeURL,
                    arguments: [gateURL.path]
                ).client()
            },
            model: { _ in .error(.invalidModelAction) },
            validation: { input in try await validator.validate(input) }
        )

        let result = try await supervisor.build(request)
        let record = try await store.record(runID: request.runID)
        XCTAssertEqual(record.attempts.count, 2)
        XCTAssertEqual(record.validations.map(\.report.outcome), [.failed, .passed])
        XCTAssertEqual(record.counters, .init(modelTurns: 0, toolCalls: 6, repairs: 1))
        XCTAssertEqual(record.result, result)
    }

    /// The eval caught this the expensive way: a download tool was written,
    /// repaired twice, and passed validation — then the run died because there
    /// was no turn left to call finish_candidate and say so. A repair budget
    /// the turn budget cannot pay for silently throws away finished work.
    func testTurnBudgetCanPayForEveryRepairItAllows() {
        let budgets = ToolAgentBudgetsV1.preview
        XCTAssertGreaterThanOrEqual(budgets.modelTurns, budgets.minimumModelTurns)
        // Each repair is one more candidate plus its validation, on top of the
        // read, write, validate, finish, and finalText every build pays.
        XCTAssertEqual(budgets.minimumModelTurns, 5 + 2 * budgets.repairs)
        // Every turn is at least one tool call, except the closing finalText.
        XCTAssertGreaterThanOrEqual(budgets.toolCalls, budgets.modelTurns - 1)
    }

    func testChargesOnlyBudgetedModelRequestsAndPersistsBudgetFailure() async throws {
        let store = try temporaryStore()
        let runID = UUID()
        let budgeted = ToolAgentBudgetsV1.preview.modelTurns
        let requests = (0...budgeted).map { index in
            ToolAgentMessageV1.modelRequest(
                runID: runID,
                .init(requestID: UUID(), system: "system", user: "turn \(index)")
            )
        }
        let process = QueueProcess(messages: [
            .state(runID: runID, .init(state: .understanding))
        ] + requests)
        let request = ToolBuildRequestV1(runID: runID, description: "budget")
        let supervisor = ToolBuildSupervisor(
            store: store,
            runtimeVersion: "3.12.11",
            policyVersion: "validation-v1",
            makeProcess: { _ in process.client() },
            model: { _ in .error(.invalidModelAction) },
            validation: { _ in throw ToolAgentFailureCodeV1.workerFailure }
        )

        do {
            _ = try await supervisor.build(request)
            XCTFail("Expected budget exhaustion")
        } catch {
            XCTAssertEqual(error as? ToolAgentFailureCodeV1, .budgetExhausted)
        }

        let record = try await store.record(runID: runID)
        XCTAssertEqual(record.counters.modelTurns, budgeted)
        XCTAssertEqual(record.state, .budgetExhausted)
        XCTAssertEqual(record.failure, .budgetExhausted)
        XCTAssertNil(record.result)
        let didCancel = await process.didCancel
        XCTAssertTrue(didCancel)
    }

    func testRejectsFinishWithoutExactAttestationAndNeverPublishesCandidate() async throws {
        let store = try temporaryStore()
        let runID = UUID()
        let fingerprint = ToolAgentFingerprintV1(String(repeating: "a", count: 64))
        let process = QueueProcess(messages: [
            .state(runID: runID, .init(state: .understanding)),
            .state(runID: runID, .init(state: .writing)),
            .toolRequest(runID: runID, .init(
                callID: UUID(),
                request: .finishCandidate(try .init(candidateID: UUID(), fingerprint: fingerprint))
            ))
        ])
        let request = ToolBuildRequestV1(runID: runID, description: "bad attestation")
        let supervisor = ToolBuildSupervisor(
            store: store,
            runtimeVersion: "3.12.11",
            policyVersion: "validation-v1",
            makeProcess: { _ in process.client() },
            model: { _ in .error(.workerFailure) },
            validation: { _ in throw ToolAgentFailureCodeV1.workerFailure }
        )

        do {
            _ = try await supervisor.build(request)
            XCTFail("Expected attestation failure")
        } catch {
            XCTAssertEqual(error as? ToolAgentFailureCodeV1, .attestationFailed)
        }

        let record = try await store.record(runID: runID)
        XCTAssertNil(record.result)
        XCTAssertEqual(record.failure, .attestationFailed)
        let didCancel = await process.didCancel
        XCTAssertTrue(didCancel)
    }

    func testRealJSONLProcessRetainsChildAndCleansUpOnSuccess() async throws {
        let process = try JSONLProcess.launch(executableURL: URL(fileURLWithPath: "/bin/cat"))
        let client = process.client()
        let message = ToolAgentMessageV1.cancel(runID: UUID(), .init(reason: .userRequested))

        try await client.send(message)
        let received = try await client.receive()
        XCTAssertEqual(received, message)
        await client.finish()
    }

    func testSanitizedEnvironmentDropsSecretsAndCallerPath() {
        let environment = JSONLProcess.sanitizedEnvironment([
            "API_TOKEN": "secret",
            "PATH": "/tmp/untrusted",
            "TMPDIR": "/tmp/safe",
            "LANG": "ko_KR.UTF-8"
        ])

        XCTAssertNil(environment["API_TOKEN"])
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(environment["TMPDIR"], "/tmp/safe")
        XCTAssertEqual(environment["LANG"], "ko_KR.UTF-8")
    }

    func testCreateAnswersClarificationBeforeFirstCandidateWrite() async throws {
        let store = try temporaryStore()
        let request = ToolBuildRequestV1(description: "send selected text")
        let process = ClarificationProcess(
            runID: request.runID,
            mode: .askThenWrite
        )
        let supervisor = ToolBuildSupervisor(
            store: store,
            runtimeVersion: "3.12.11",
            policyVersion: "validation-v1",
            makeProcess: { _ in process.client() },
            model: { _ in .error(.workerFailure) },
            validation: { _ in throw ToolAgentFailureCodeV1.workerFailure },
            clarification: { request in
                XCTAssertEqual(request.question, "Which app should receive the text?")
                return try .init(answer: "Notes")
            }
        )

        do {
            _ = try await supervisor.build(request)
            XCTFail("Expected scripted process to end after the first write")
        } catch {
            XCTAssertEqual(error as? ToolAgentFailureCodeV1, .workerFailure)
        }

        let record = try await store.record(runID: request.runID)
        let processResult = await process.result
        XCTAssertEqual(record.counters.toolCalls, 2)
        XCTAssertEqual(record.attempts.count, 1)
        XCTAssertEqual(processResult.answers, ["Notes"])
        XCTAssertTrue(processResult.didWriteAfterAnswer)
    }

    func testEditAndFixAnswerClarificationBeforeFirstCandidateWrite() async throws {
        let installed = try ToolAgentInstalledToolV1(
            kind: .prompt,
            name: "Rewrite",
            brief: "Rewrites selected text",
            symbolName: "pencil",
            input: .selection,
            output: .panel,
            trigger: .selection,
            prompt: "Rewrite this text."
        )
        let requests: [(request: ToolBuildRequestV1, answer: String)] = [
            (
                try ToolBuildRequestV1(
                description: "Make it concise",
                operation: .edit,
                currentTool: installed
                ),
                "Keep the original tone."
            ),
            (
                try ToolBuildRequestV1(
                description: "Repair the tool",
                operation: .fix,
                currentTool: installed,
                failure: "wrong output"
                ),
                "Use the exact failing input."
            )
        ]

        for entry in requests {
            let request = entry.request
            let store = try temporaryStore()
            let process = ClarificationProcess(runID: request.runID, mode: .askThenWrite)
            let invocations = InvocationCounter()
            let supervisor = ToolBuildSupervisor(
                store: store,
                runtimeVersion: "3.12.11",
                policyVersion: "validation-v1",
                makeProcess: { _ in process.client() },
                model: { _ in .error(.workerFailure) },
                validation: { _ in throw ToolAgentFailureCodeV1.workerFailure },
                clarification: { clarification in
                    XCTAssertEqual(clarification.question, "Which app should receive the text?")
                    await invocations.increment()
                    return try .init(answer: entry.answer)
                }
            )

            await assertBuildFails(supervisor, request: request, with: .workerFailure)
            let record = try await store.record(runID: request.runID)
            let result = await process.result
            let count = await invocations.value
            XCTAssertEqual(record.counters.toolCalls, 2)
            XCTAssertEqual(record.attempts.count, 1)
            XCTAssertEqual(result.answers, [entry.answer])
            XCTAssertTrue(result.didWriteAfterAnswer)
            XCTAssertEqual(count, 1)
        }
    }

    func testRejectsClarificationAfterFirstCandidateWrite() async throws {
        let store = try temporaryStore()
        let request = ToolBuildRequestV1(description: "send selected text")
        let process = ClarificationProcess(runID: request.runID, mode: .writeThenAsk)
        let invocations = InvocationCounter()
        let supervisor = ToolBuildSupervisor(
            store: store,
            runtimeVersion: "3.12.11",
            policyVersion: "validation-v1",
            makeProcess: { _ in process.client() },
            model: { _ in .error(.workerFailure) },
            validation: { _ in throw ToolAgentFailureCodeV1.workerFailure },
            clarification: { _ in
                await invocations.increment()
                return try .init(answer: "Notes")
            }
        )

        await assertBuildFails(supervisor, request: request, with: .invalidProtocol)
        let record = try await store.record(runID: request.runID)
        let count = await invocations.value
        XCTAssertEqual(record.attempts.count, 1)
        XCTAssertEqual(record.counters.toolCalls, 2)
        XCTAssertEqual(count, 0)
    }

    func testRejectsFourthClarificationAfterThreeAcceptedAnswers() async throws {
        let store = try temporaryStore()
        let request = ToolBuildRequestV1(description: "send selected text")
        let process = ClarificationProcess(runID: request.runID, mode: .questions(4))
        let invocations = InvocationCounter()
        let supervisor = ToolBuildSupervisor(
            store: store,
            runtimeVersion: "3.12.11",
            policyVersion: "validation-v1",
            makeProcess: { _ in process.client() },
            model: { _ in .error(.workerFailure) },
            validation: { _ in throw ToolAgentFailureCodeV1.workerFailure },
            clarification: { _ in
                let count = await invocations.increment()
                return try .init(answer: "answer-\(count)")
            }
        )

        await assertBuildFails(supervisor, request: request, with: .invalidProtocol)
        let record = try await store.record(runID: request.runID)
        let result = await process.result
        let count = await invocations.value
        XCTAssertEqual(record.counters.toolCalls, 4)
        XCTAssertEqual(count, 3)
        XCTAssertEqual(result.answers, ["answer-1", "answer-2", "answer-3"])
    }

    func testCancellationHandshakeStopsNonCooperativeClarificationHandler() async throws {
        let store = try temporaryStore()
        let request = ToolBuildRequestV1(description: "send selected text")
        let process = ClarificationProcess(runID: request.runID, mode: .questions(1))
        let suspension = NonCooperativeClarification()
        let supervisor = ToolBuildSupervisor(
            store: store,
            runtimeVersion: "3.12.11",
            policyVersion: "validation-v1",
            makeProcess: { _ in process.client() },
            model: { _ in .error(.workerFailure) },
            validation: { _ in throw ToolAgentFailureCodeV1.workerFailure },
            clarification: { request in
                try await suspension.handle(request)
            },
            clarificationCancellation: {
                await suspension.cancel()
            }
        )
        let build = Task { try await supervisor.build(request) }
        await suspension.waitUntilStarted()

        let didCancel = await supervisor.cancel(runID: request.runID)
        let result = await build.result
        guard case .failure(let error) = result else {
            return XCTFail("Expected cancellation")
        }
        XCTAssertEqual(error as? ToolAgentFailureCodeV1, .cancelled)
        let handlerWasCancelled = await suspension.wasCancelled
        let pending = await supervisor.pendingClarification
        let processWasCancelled = await process.wasCancelled
        let handlerDidFinish = await suspension.didFinish
        XCTAssertTrue(didCancel)
        XCTAssertTrue(handlerWasCancelled)
        XCTAssertTrue(handlerDidFinish)
        XCTAssertNil(pending)
        XCTAssertTrue(processWasCancelled)
    }

    func testDeadlineHandshakeStopsNonCooperativeClarificationHandler() async throws {
        let store = try temporaryStore()
        let request = ToolBuildRequestV1(description: "send selected text")
        let process = ClarificationProcess(runID: request.runID, mode: .questions(1))
        let suspension = NonCooperativeClarification()
        let deadline = ManualDeadline()
        let supervisor = ToolBuildSupervisor(
            store: store,
            runtimeVersion: "3.12.11",
            policyVersion: "validation-v1",
            makeProcess: { _ in process.client() },
            model: { _ in .error(.workerFailure) },
            validation: { _ in throw ToolAgentFailureCodeV1.workerFailure },
            clarification: { request in
                try await suspension.handle(request)
            },
            clarificationCancellation: {
                await suspension.cancel()
            },
            sleep: { _ in await deadline.wait() }
        )
        let build = Task { try await supervisor.build(request) }
        await suspension.waitUntilStarted()

        await deadline.fire()
        let result = await build.result
        guard case .failure(let error) = result else {
            return XCTFail("Expected deadline failure")
        }
        XCTAssertEqual(error as? ToolAgentFailureCodeV1, .timedOut)
        let record = try await store.record(runID: request.runID)
        let pending = await supervisor.pendingClarification
        let handlerWasCancelled = await suspension.wasCancelled
        let handlerDidFinish = await suspension.didFinish
        let processWasCancelled = await process.wasCancelled
        XCTAssertEqual(record.failure, .timedOut)
        XCTAssertTrue(handlerWasCancelled)
        XCTAssertTrue(handlerDidFinish)
        XCTAssertNil(pending)
        XCTAssertTrue(processWasCancelled)
    }

    func testOldCancellationCannotClearNextRunsPendingClarification() async throws {
        let store = try temporaryStore()
        let first = ToolBuildRequestV1(description: "first tool")
        let second = ToolBuildRequestV1(description: "second tool")
        let firstProcess = ClarificationProcess(runID: first.runID, mode: .questions(1))
        let secondProcess = ClarificationProcess(runID: second.runID, mode: .questions(1))
        let harness = ReentrantClarificationHarness()
        let supervisor = ToolBuildSupervisor(
            store: store,
            runtimeVersion: "3.12.11",
            policyVersion: "validation-v1",
            makeProcess: { request in
                request.runID == first.runID
                    ? firstProcess.client()
                    : secondProcess.client()
            },
            model: { _ in .error(.workerFailure) },
            validation: { _ in throw ToolAgentFailureCodeV1.workerFailure },
            clarification: { request in
                try await harness.handle(request)
            },
            clarificationCancellation: {
                await harness.cancelCurrent()
            }
        )
        let firstBuild = Task { try await supervisor.build(first) }
        await harness.waitUntilStarted(index: 0)
        let firstCancel = Task { await supervisor.cancel(runID: first.runID) }
        await harness.waitUntilFirstCancellationPauses()
        _ = await firstBuild.result

        let secondBuild = Task { try await supervisor.build(second) }
        await harness.waitUntilStarted(index: 1)
        let secondPendingBeforeRelease = await supervisor.pendingClarification
        XCTAssertNotNil(secondPendingBeforeRelease)
        XCTAssertEqual(secondPendingBeforeRelease?.runID, second.runID)

        await harness.releaseFirstCancellation()
        let didCancelFirst = await firstCancel.value
        XCTAssertTrue(didCancelFirst)
        let secondOwnerAfterRelease = await supervisor.pendingClarification
        guard secondOwnerAfterRelease?.runID == second.runID else {
            await harness.forceResume(index: 1)
            _ = await secondBuild.result
            return XCTFail("Old cancellation cleared the second run's pending owner")
        }

        let didCancelSecond = await supervisor.cancel(runID: second.runID)
        let secondResult = await secondBuild.result
        guard case .failure(let error) = secondResult else {
            return XCTFail("Expected second cancellation")
        }
        XCTAssertTrue(didCancelSecond)
        XCTAssertEqual(error as? ToolAgentFailureCodeV1, .cancelled)
        let pendingAfterSecondCancel = await supervisor.pendingClarification
        XCTAssertNil(pendingAfterSecondCancel)
    }

    private func temporaryStore() throws -> ToolBuildStore {
        try ToolBuildStore(directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
    }

    private func assertBuildFails(
        _ supervisor: ToolBuildSupervisor,
        request: ToolBuildRequestV1,
        with failure: ToolAgentFailureCodeV1
    ) async {
        do {
            _ = try await supervisor.build(request)
            XCTFail("Expected \(failure)")
        } catch {
            XCTAssertEqual(error as? ToolAgentFailureCodeV1, failure)
        }
    }
}

private actor ClarificationProcess {
    enum Mode {
        case askThenWrite
        case questions(Int)
        case writeThenAsk
    }

    private let runID: UUID
    private let mode: Mode
    private var messages: [ToolAgentMessageV1]
    private(set) var answers: [String] = []
    private(set) var didWriteAfterAnswer = false
    private(set) var wasCancelled = false

    init(runID: UUID, mode: Mode) {
        self.runID = runID
        self.mode = mode
        self.messages = [.state(runID: runID, .init(state: .understanding))]
        switch mode {
        case .askThenWrite, .questions:
            self.messages.append(Self.question(runID: runID))
        case .writeThenAsk:
            self.messages.append(Self.write(runID: runID))
        }
    }

    nonisolated func client() -> ToolBuildProcessClientV1 {
        .init(
            send: { [self] in try await accept($0) },
            receive: { [self] in await pop() },
            cancel: { [self] in await cancel() }
        )
    }

    private func accept(_ message: ToolAgentMessageV1) throws {
        guard case .toolResponse(let envelope) = message.payload else { return }
        switch envelope.result {
        case .askUser(let response):
            answers.append(response.answer)
            switch mode {
            case .askThenWrite:
                messages.append(Self.write(runID: runID))
            case .questions(let count) where answers.count < count:
                messages.append(Self.question(runID: runID))
            default:
                break
            }
        case .writeCandidate:
            didWriteAfterAnswer = !answers.isEmpty
            if case .writeThenAsk = mode {
                messages.append(Self.question(runID: runID))
            }
        default:
            break
        }
    }

    private func pop() -> ToolAgentMessageV1? {
        messages.isEmpty ? nil : messages.removeFirst()
    }

    private func cancel() {
        wasCancelled = true
    }

    var result: (answers: [String], didWriteAfterAnswer: Bool) {
        (answers, didWriteAfterAnswer)
    }

    private static func question(runID: UUID) -> ToolAgentMessageV1 {
        .toolRequest(
            runID: runID,
            .init(
                callID: UUID(),
                request: .askUser(
                    try! .init(question: "Which app should receive the text?")
                )
            )
        )
    }

    private static func write(runID: UUID) -> ToolAgentMessageV1 {
        let candidate = try! ToolAgentCandidateV1(
            name: "Send to Notes",
            brief: "Sends selected text",
            symbolName: "note.text",
            source: "print(input())",
            fixtures: [.init(input: "hello", expectedOutput: "hello")]
        )
        return .toolRequest(
            runID: runID,
            .init(
                callID: UUID(),
                request: .writeCandidate(.init(candidate: candidate))
            )
        )
    }
}

private actor InvocationCounter {
    private(set) var value = 0

    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}

private actor NonCooperativeClarification {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<ToolAgentAskUserResponseV1, Error>?
    private(set) var wasCancelled = false
    private(set) var didFinish = false

    func handle(
        _ request: ToolAgentAskUserRequestV1
    ) async throws -> ToolAgentAskUserResponseV1 {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        do {
            let response = try await withCheckedThrowingContinuation {
                continuation = $0
            }
            didFinish = true
            return response
        } catch {
            didFinish = true
            throw error
        }
    }

    func cancel() {
        wasCancelled = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}

private actor ManualDeadline {
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func wait() async {
        if fired { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func fire() {
        fired = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ReentrantClarificationHarness {
    private var nextIndex = 0
    private var continuations: [Int: CheckedContinuation<ToolAgentAskUserResponseV1, Error>] = [:]
    private var started: Set<Int> = []
    private var startWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var cancellationIndex = 0
    private var firstCancellationPaused = false
    private var firstPauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseFirst = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func handle(
        _ request: ToolAgentAskUserRequestV1
    ) async throws -> ToolAgentAskUserResponseV1 {
        let index = nextIndex
        nextIndex += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations[index] = continuation
            started.insert(index)
            startWaiters.removeValue(forKey: index)?.forEach { $0.resume() }
        }
    }

    func cancelCurrent() async {
        let index = cancellationIndex
        cancellationIndex += 1
        continuations.removeValue(forKey: index)?.resume(throwing: CancellationError())
        guard index == 0 else { return }
        firstCancellationPaused = true
        firstPauseWaiters.forEach { $0.resume() }
        firstPauseWaiters.removeAll()
        if releaseFirst { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilStarted(index: Int) async {
        if started.contains(index) { return }
        await withCheckedContinuation {
            startWaiters[index, default: []].append($0)
        }
    }

    func waitUntilFirstCancellationPauses() async {
        if firstCancellationPaused { return }
        await withCheckedContinuation { firstPauseWaiters.append($0) }
    }

    func releaseFirstCancellation() {
        releaseFirst = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func forceResume(index: Int) {
        continuations.removeValue(forKey: index)?.resume(throwing: CancellationError())
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func set(_ value: Bool) {
        lock.withLock { storage = value }
    }
}

private final class UUIDSequence: @unchecked Sendable {
    let values: [UUID]
    private let lock = NSLock()
    private var index = 0

    init(_ values: [UUID]) {
        self.values = values
    }

    func next() -> UUID {
        lock.withLock {
            defer { index += 1 }
            return values[index]
        }
    }
}

private actor ValidationStub {
    private var count = 0

    func validate(_ input: ToolBuildValidationInputV1) throws -> ToolAgentValidationReportV1 {
        defer { count += 1 }
        if count == 0 {
            return try .init(
                candidateID: input.candidateID,
                fingerprint: input.fingerprint,
                outcome: .failed,
                failure: .wrongOutput,
                fixtureIndex: 0,
                expectedOutput: "HELLO",
                actualOutput: "hello",
                stderrDetail: "",
                exitCode: 0,
                durationMilliseconds: 3
            )
        }
        return try .init(
            candidateID: input.candidateID,
            fingerprint: input.fingerprint,
            outcome: .passed,
            exitCode: 0,
            durationMilliseconds: 2,
            passingFingerprint: input.fingerprint
        )
    }
}

private actor QueueProcess {
    private var messages: [ToolAgentMessageV1]
    private(set) var didCancel = false

    init(messages: [ToolAgentMessageV1]) {
        self.messages = messages
    }

    nonisolated func client() -> ToolBuildProcessClientV1 {
        .init(
            send: { _ in },
            receive: { [self] in await self.pop() },
            cancel: { [self] in await self.cancel() }
        )
    }

    private func pop() -> ToolAgentMessageV1? {
        messages.isEmpty ? nil : messages.removeFirst()
    }

    private func cancel() {
        didCancel = true
    }
}

private actor RepairScript {
    private let first: ToolAgentCandidateV1
    private let repaired: ToolAgentCandidateV1
    private var messages: [ToolAgentMessageV1] = []
    private var runID: UUID?
    private var writeCount = 0
    private(set) var didCancel = false
    private(set) var didFinish = false

    init() throws {
        self.first = try Self.candidate(source: "print(input())")
        self.repaired = try Self.candidate(source: "print(input().upper())")
    }

    nonisolated func client() -> ToolBuildProcessClientV1 {
        .init(
            send: { [self] in try await self.accept($0) },
            receive: { [self] in await self.pop() },
            cancel: { [self] in await self.cancel() },
            finish: { [self] in await self.finish() }
        )
    }

    private func accept(_ message: ToolAgentMessageV1) throws {
        runID = message.runID
        switch message.payload {
        case .start:
            messages.append(.state(runID: message.runID, .init(state: .understanding)))
            messages.append(.modelRequest(
                runID: message.runID,
                .init(requestID: UUID(), system: "system", user: "build")
            ))
        case .modelResponse:
            appendWrite(candidate: first)
        case .toolResponse(let envelope):
            try acceptToolResponse(envelope)
        default:
            break
        }
    }

    private func acceptToolResponse(_ envelope: ToolAgentToolResponseEnvelopeV1) throws {
        guard let runID else { return }
        switch envelope.result {
        case .writeCandidate(let write):
            writeCount += 1
            messages.append(.toolRequest(
                runID: runID,
                .init(callID: UUID(), request: .runValidation(.init(candidateID: write.candidateID)))
            ))
        case .runValidation(let report) where report.outcome == .failed:
            appendWrite(candidate: repaired)
        case .runValidation(let report):
            messages.append(.toolRequest(
                runID: runID,
                .init(
                    callID: UUID(),
                    request: .finishCandidate(try .init(
                        candidateID: report.candidateID,
                        fingerprint: report.fingerprint
                    ))
                )
            ))
        case .finishCandidate(let attestation):
            messages.append(.completed(
                runID: runID,
                .init(candidateID: attestation.candidateID, fingerprint: attestation.fingerprint)
            ))
        default:
            break
        }
    }

    private func appendWrite(candidate: ToolAgentCandidateV1) {
        guard let runID else { return }
        messages.append(.toolRequest(
            runID: runID,
            .init(callID: UUID(), request: .writeCandidate(.init(candidate: candidate)))
        ))
    }

    private func pop() -> ToolAgentMessageV1? {
        messages.isEmpty ? nil : messages.removeFirst()
    }

    private func cancel() {
        didCancel = true
    }

    private func finish() {
        didFinish = true
    }

    private static func candidate(source: String) throws -> ToolAgentCandidateV1 {
        try .init(
            name: "Uppercase",
            brief: "Uppercases text",
            symbolName: "textformat",
            source: source,
            fixtures: [.init(input: "hello", expectedOutput: "HELLO")]
        )
    }
}
