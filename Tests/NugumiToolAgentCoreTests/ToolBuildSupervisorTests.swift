import Foundation
import XCTest
@testable import NugumiToolAgentCore

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

    func testChargesOnlyEightAcceptedModelRequestsAndPersistsBudgetFailure() async throws {
        let store = try temporaryStore()
        let runID = UUID()
        let requests = (0..<9).map { index in
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
        XCTAssertEqual(record.counters.modelTurns, 8)
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

    private func temporaryStore() throws -> ToolBuildStore {
        try ToolBuildStore(directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
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
