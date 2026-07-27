import Foundation

public struct ToolAgentWriteCandidateResponseV1: Codable, Equatable, Sendable {
    public let candidateID: UUID
    public let fingerprint: ToolAgentFingerprintV1

    public init(candidateID: UUID, fingerprint: ToolAgentFingerprintV1) throws {
        guard ToolAgentFingerprintV1.isValid(fingerprint) else { throw ToolAgentFailureCodeV1.attestationFailed }
        self.candidateID = candidateID
        self.fingerprint = fingerprint
    }
}

public struct ToolAgentRunValidationRequestV1: Codable, Equatable, Sendable {
    public let candidateID: UUID

    public init(candidateID: UUID) {
        self.candidateID = candidateID
    }
}

public enum ToolAgentValidationOutcomeV1: String, Codable, Equatable, Sendable {
    case passed
    case failed
}

public struct ToolAgentValidationReportV1: Codable, Equatable, Sendable {
    public let candidateID: UUID
    public let fingerprint: ToolAgentFingerprintV1
    public let outcome: ToolAgentValidationOutcomeV1
    public let failure: ToolAgentFailureCodeV1?
    public let fixtureIndex: Int?
    public let expectedOutput: String?
    public let actualOutput: String?
    public let stderrDetail: String?
    public let exitCode: Int32?
    public let terminationSignal: Int32?
    public let stdoutWasTruncated: Bool
    public let stderrWasTruncated: Bool
    public let durationMilliseconds: Int?
    public let passingFingerprint: ToolAgentFingerprintV1?

    public init(
        candidateID: UUID,
        fingerprint: ToolAgentFingerprintV1,
        outcome: ToolAgentValidationOutcomeV1,
        failure: ToolAgentFailureCodeV1? = nil,
        fixtureIndex: Int? = nil,
        expectedOutput: String? = nil,
        actualOutput: String? = nil,
        stderrDetail: String? = nil,
        exitCode: Int32? = nil,
        terminationSignal: Int32? = nil,
        stdoutWasTruncated: Bool = false,
        stderrWasTruncated: Bool = false,
        durationMilliseconds: Int? = nil,
        passingFingerprint: ToolAgentFingerprintV1? = nil
    ) throws {
        guard ToolAgentFingerprintV1.isValid(fingerprint),
              Self.valid(
                  outcome: outcome,
                  failure: failure,
                  fingerprint: fingerprint,
                  passingFingerprint: passingFingerprint
              ),
              fixtureIndex.map({
                  (0..<ToolAgentProtocolLimitsV1.maximumFixtureCount).contains($0)
              }) ?? true,
              durationMilliseconds.map({ (0...600_000).contains($0) }) ?? true,
              Self.withinDiagnosticLimit(expectedOutput),
              Self.withinDiagnosticLimit(actualOutput),
              Self.withinDiagnosticLimit(stderrDetail) else {
            throw ToolAgentFailureCodeV1.attestationFailed
        }
        self.candidateID = candidateID
        self.fingerprint = fingerprint
        self.outcome = outcome
        self.failure = failure
        self.fixtureIndex = fixtureIndex
        self.expectedOutput = expectedOutput
        self.actualOutput = actualOutput
        self.stderrDetail = stderrDetail
        self.exitCode = exitCode
        self.terminationSignal = terminationSignal
        self.stdoutWasTruncated = stdoutWasTruncated
        self.stderrWasTruncated = stderrWasTruncated
        self.durationMilliseconds = durationMilliseconds
        self.passingFingerprint = passingFingerprint
    }

    private static func valid(
        outcome: ToolAgentValidationOutcomeV1,
        failure: ToolAgentFailureCodeV1?,
        fingerprint: ToolAgentFingerprintV1,
        passingFingerprint: ToolAgentFingerprintV1?
    ) -> Bool {
        switch outcome {
        case .passed:
            return failure == nil && passingFingerprint == fingerprint
        case .failed:
            return failure != nil && passingFingerprint == nil
        }
    }

    private static func withinDiagnosticLimit(_ value: String?) -> Bool {
        value.map {
            $0.utf8.count <= ToolAgentProtocolLimitsV1.maximumDiagnosticBytes
        } ?? true
    }
}

public struct ToolAgentFinishCandidateRequestV1: Codable, Equatable, Sendable {
    public let candidateID: UUID
    public let fingerprint: ToolAgentFingerprintV1

    public init(candidateID: UUID, fingerprint: ToolAgentFingerprintV1) throws {
        guard ToolAgentFingerprintV1.isValid(fingerprint) else { throw ToolAgentFailureCodeV1.attestationFailed }
        self.candidateID = candidateID
        self.fingerprint = fingerprint
    }
}

public struct ToolAgentAttestationV1: Codable, Equatable, Sendable {
    public let candidateID: UUID
    public let fingerprint: ToolAgentFingerprintV1

    public init(write: ToolAgentWriteCandidateResponseV1, validation: ToolAgentValidationReportV1, finish: ToolAgentFinishCandidateRequestV1) throws {
        guard validation.outcome == .passed,
              write.candidateID == validation.candidateID,
              validation.candidateID == finish.candidateID,
              write.fingerprint == validation.fingerprint,
              validation.fingerprint == finish.fingerprint else {
            throw ToolAgentFailureCodeV1.attestationFailed
        }
        self.candidateID = write.candidateID
        self.fingerprint = write.fingerprint
    }
}

public struct ToolAgentUsageCountersV1: Codable, Equatable, Sendable {
    public let modelTurns: Int
    public let toolCalls: Int
    public let repairs: Int

    public init(modelTurns: Int, toolCalls: Int, repairs: Int) {
        self.modelTurns = modelTurns
        self.toolCalls = toolCalls
        self.repairs = repairs
    }
}

public struct ToolAgentSafeEventMetadataV1: Codable, Equatable, Sendable {
    public let runID: UUID
    public let state: ToolAgentBuildStateV1
    public let counters: ToolAgentUsageCountersV1
    public let durationMilliseconds: Int
    public let failure: ToolAgentFailureCodeV1?

    public init(runID: UUID, state: ToolAgentBuildStateV1, counters: ToolAgentUsageCountersV1, durationMilliseconds: Int, failure: ToolAgentFailureCodeV1?) {
        self.runID = runID
        self.state = state
        self.counters = counters
        self.durationMilliseconds = durationMilliseconds
        self.failure = failure
    }
}

extension ToolAgentFingerprintV1 {
    static func isValid(_ fingerprint: ToolAgentFingerprintV1) -> Bool {
        fingerprint.value.count == 64
            && fingerprint.value.allSatisfy { $0.isASCII && ($0.isNumber || ($0 >= "a" && $0 <= "f")) }
    }
}
