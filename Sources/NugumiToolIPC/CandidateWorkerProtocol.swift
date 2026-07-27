import Foundation
import NugumiToolAgentCore

public struct CandidateValidationRequestV1: Codable, Equatable, Sendable {
    public let runID: UUID
    public let candidateID: UUID
    public let candidate: ToolAgentCandidateV1
    public let fingerprint: ToolAgentFingerprintV1

    public init(
        runID: UUID,
        candidateID: UUID,
        candidate: ToolAgentCandidateV1,
        fingerprint: ToolAgentFingerprintV1
    ) {
        self.runID = runID
        self.candidateID = candidateID
        self.candidate = candidate
        self.fingerprint = fingerprint
    }
}

public struct CandidateValidationReplyV1: Codable, Equatable, Sendable {
    public let runID: UUID
    public let candidateID: UUID
    public let fingerprint: ToolAgentFingerprintV1
    public let fixtureIndex: Int?
    public let outcome: ToolAgentValidationOutcomeV1
    public let failure: ToolAgentFailureCodeV1?
    public let exitCode: Int32?
    public let terminationSignal: Int32?
    public let actualOutput: String?
    public let stderrDetail: String?
    public let stdoutWasTruncated: Bool
    public let stderrWasTruncated: Bool
    public let processGroupTerminated: Bool
    public let durationMilliseconds: Int
    public let passingFingerprint: ToolAgentFingerprintV1?

    public init(
        runID: UUID,
        candidateID: UUID,
        fingerprint: ToolAgentFingerprintV1,
        fixtureIndex: Int?,
        outcome: ToolAgentValidationOutcomeV1,
        failure: ToolAgentFailureCodeV1?,
        exitCode: Int32?,
        terminationSignal: Int32?,
        actualOutput: String?,
        stderrDetail: String?,
        stdoutWasTruncated: Bool,
        stderrWasTruncated: Bool,
        processGroupTerminated: Bool,
        durationMilliseconds: Int,
        passingFingerprint: ToolAgentFingerprintV1?
    ) {
        self.runID = runID
        self.candidateID = candidateID
        self.fingerprint = fingerprint
        self.fixtureIndex = fixtureIndex
        self.outcome = outcome
        self.failure = failure
        self.exitCode = exitCode
        self.terminationSignal = terminationSignal
        self.actualOutput = actualOutput
        self.stderrDetail = stderrDetail
        self.stdoutWasTruncated = stdoutWasTruncated
        self.stderrWasTruncated = stderrWasTruncated
        self.processGroupTerminated = processGroupTerminated
        self.durationMilliseconds = durationMilliseconds
        self.passingFingerprint = passingFingerprint
    }
}

public enum CandidateWorkerProtocolFailureCodeV1:
    String,
    Codable,
    Equatable,
    Sendable
{
    case invalidRequest
}

public struct CandidateWorkerProtocolFailureV1:
    Codable,
    Equatable,
    Sendable
{
    public let schemaVersion: Int
    public let code: CandidateWorkerProtocolFailureCodeV1

    public init(code: CandidateWorkerProtocolFailureCodeV1) {
        schemaVersion = 1
        self.code = code
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            Int.self,
            forKey: .schemaVersion
        )
        guard schemaVersion == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported candidate worker failure version"
            )
        }
        self.schemaVersion = schemaVersion
        code = try container.decode(
            CandidateWorkerProtocolFailureCodeV1.self,
            forKey: .code
        )
    }
}

public enum CandidateWorkerReplyV1: Codable, Equatable, Sendable {
    case validation(CandidateValidationReplyV1)
    case protocolFailure(CandidateWorkerProtocolFailureV1)
}
