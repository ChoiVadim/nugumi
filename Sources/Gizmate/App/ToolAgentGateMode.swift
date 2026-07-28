import Foundation
import GizmateToolAgentCore
import GizmateToolIPC

struct ToolAgentGateMode: Equatable {
    let reportPath: String

    var reportURL: URL {
        URL(fileURLWithPath: reportPath)
    }

    static func parse(arguments: [String]) -> Self? {
        guard
            arguments.count == 4,
            arguments[1] == "--pi-tool-agent-gate",
            arguments[2] == "--report",
            !arguments[3].isEmpty
        else {
            return nil
        }
        return Self(reportPath: arguments[3])
    }

    func run(bundleURL: URL = Bundle.main.bundleURL) async -> Int32 {
        await ToolAgentGateRunner.runAndWriteReport(to: reportURL) {
            try await ToolAgentGateRunner.runPackagedGate(bundleURL: bundleURL)
        }
    }
}

enum ToolAgentGateFailureCodeV1: String, Codable, Error, Equatable {
    case helperUnavailable
    case invalidResult
    case invalidProtocol
    case invalidModelAction
    case invalidCandidate
    case syntaxError
    case runtimeError
    case invalidOutput
    case wrongOutput
    case timedOut
    case outputLimit
    case cancelled
    case sandboxUnavailable
    case workerFailure
    case budgetExhausted
    case attestationFailed
}

struct ToolAgentGateFailedAttemptV1: Codable, Equatable {
    let candidateID: UUID
    let fingerprint: String
    let outcome: ToolAgentValidationOutcomeV1
    let failure: ToolAgentFailureCodeV1
}

struct ToolAgentGatePassingAttemptV1: Codable, Equatable {
    let candidateID: UUID
    let fingerprint: String
    let outcome: ToolAgentValidationOutcomeV1
    let passingFingerprint: String
}

struct ToolAgentGateReportV1: Codable, Equatable {
    let schemaVersion: Int
    let gatePassed: Bool
    let runID: UUID
    let entrypoint: String
    let modelRequestCount: Int
    let attemptCount: Int
    let firstAttempt: ToolAgentGateFailedAttemptV1
    let secondAttempt: ToolAgentGatePassingAttemptV1
    let finalState: ToolAgentBuildStateV1
    let finalCandidateID: UUID
    let finalFingerprint: String
    let counters: ToolAgentUsageCountersV1

    init(
        record: ToolBuildRecordV1,
        result: ToolBuildResultV1,
        modelRequestCount: Int
    ) throws {
        guard
            record.attempts.count == 2,
            record.validations.count == 2,
            let firstAttempt = record.attempts.first,
            let secondAttempt = record.attempts.last,
            let firstValidation = record.validations.first?.report,
            let secondValidation = record.validations.last?.report,
            firstAttempt.candidateID != secondAttempt.candidateID,
            firstAttempt.candidateID == firstValidation.candidateID,
            firstAttempt.fingerprint == firstValidation.fingerprint,
            firstValidation.outcome == .failed,
            firstValidation.failure == .wrongOutput,
            firstValidation.passingFingerprint == nil,
            secondAttempt.candidateID == secondValidation.candidateID,
            secondAttempt.fingerprint == secondValidation.fingerprint,
            secondValidation.outcome == .passed,
            secondValidation.failure == nil,
            secondValidation.passingFingerprint == secondAttempt.fingerprint,
            record.state == .candidateReady,
            record.result == result,
            result.candidateID == secondAttempt.candidateID,
            result.fingerprint == secondAttempt.fingerprint,
            modelRequestCount == 0,
            record.counters == ToolAgentUsageCountersV1(
                modelTurns: 0,
                toolCalls: 6,
                repairs: 1
            )
        else {
            throw ToolAgentGateFailureCodeV1.invalidResult
        }

        schemaVersion = 1
        gatePassed = true
        runID = record.request.runID
        entrypoint = "gate.mjs"
        self.modelRequestCount = modelRequestCount
        attemptCount = record.attempts.count
        self.firstAttempt = ToolAgentGateFailedAttemptV1(
            candidateID: firstAttempt.candidateID,
            fingerprint: firstAttempt.fingerprint.value,
            outcome: firstValidation.outcome,
            failure: firstValidation.failure!
        )
        self.secondAttempt = ToolAgentGatePassingAttemptV1(
            candidateID: secondAttempt.candidateID,
            fingerprint: secondAttempt.fingerprint.value,
            outcome: secondValidation.outcome,
            passingFingerprint: secondValidation.passingFingerprint!.value
        )
        finalState = record.state
        finalCandidateID = result.candidateID
        finalFingerprint = result.fingerprint.value
        counters = record.counters
    }
}

struct ToolAgentGateFailureReportV1: Codable, Equatable {
    let schemaVersion: Int
    let gatePassed: Bool
    let failure: ToolAgentGateFailureCodeV1

    init(failure: ToolAgentGateFailureCodeV1) {
        schemaVersion = 1
        gatePassed = false
        self.failure = failure
    }
}

enum ToolAgentGateRunner {
    typealias GateOperation = @Sendable () async throws -> ToolAgentGateReportV1

    static let runtimeVersion = "3.12.11"
    static let policyVersion = "validation-v2"
    static let requestDescription = "make copied text uppercase."

    static func runAndWriteReport(
        to reportURL: URL,
        runGate: GateOperation
    ) async -> Int32 {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            let report = try await runGate()
            let data = try encoder.encode(report)
            try data.write(to: reportURL, options: .atomic)
            return report.gatePassed ? 0 : 1
        } catch {
            let report = ToolAgentGateFailureReportV1(
                failure: failureCode(for: error)
            )
            if let data = try? encoder.encode(report) {
                try? data.write(to: reportURL, options: .atomic)
            }
            return 1
        }
    }

    static func runPackagedGate(bundleURL: URL) async throws -> ToolAgentGateReportV1 {
        let contentsURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
        let nodeURL = contentsURL
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("ToolAgentNode", isDirectory: false)
        let gateURL = contentsURL
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("ToolAgent", isDirectory: true)
            .appendingPathComponent("dist", isDirectory: true)
            .appendingPathComponent("gate.mjs", isDirectory: false)
            .standardizedFileURL
        guard
            FileManager.default.isExecutableFile(atPath: nodeURL.path),
            gateURL.path.hasPrefix("/"),
            FileManager.default.isReadableFile(atPath: gateURL.path)
        else {
            throw ToolAgentGateFailureCodeV1.helperUnavailable
        }

        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GizmatePiToolAgentGate-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = try ToolBuildStore(directoryURL: storeURL)
        let modelRequests = ToolAgentGateModelRequestCounter()
        let supervisor = ToolBuildSupervisor(
            store: store,
            runtimeVersion: runtimeVersion,
            policyVersion: policyVersion,
            makeProcess: { _ in
                let process = try JSONLProcess.launch(
                    executableURL: nodeURL,
                    arguments: [gateURL.path],
                    environment: ["TMPDIR": storeURL.path]
                )
                return process.client()
            },
            model: { _ in
                await modelRequests.record()
                return .error(.workerFailure)
            },
            // Unreachable: the gate's model handler errors on the first turn,
            // so the sidecar never gets far enough to ask for a validation. The
            // gate proves the packaged app can launch the agent and complete
            // the protocol, not that a candidate runs.
            validation: { _ in
                throw ToolAgentGateFailureCodeV1.sandboxUnavailable
            }
        )
        let request = ToolBuildRequestV1(
            description: requestDescription,
            budgets: .preview
        )
        let result = try await supervisor.build(request)
        let record = try await store.record(runID: request.runID)
        return try ToolAgentGateReportV1(
            record: record,
            result: result,
            modelRequestCount: await modelRequests.value
        )
    }

    static func failureCode(for error: Error) -> ToolAgentGateFailureCodeV1 {
        if let failure = error as? ToolAgentGateFailureCodeV1 {
            return failure
        }
        if let failure = error as? ToolAgentFailureCodeV1 {
            return ToolAgentGateFailureCodeV1(rawValue: failure.rawValue)
                ?? .workerFailure
        }
        return .workerFailure
    }
}

private actor ToolAgentGateModelRequestCounter {
    private(set) var value = 0

    func record() {
        value += 1
    }
}
