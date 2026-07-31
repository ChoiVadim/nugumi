import CryptoKit
import Foundation

public enum ToolAgentRequestContractV1 {
    public static func validate(
        operation: ToolAgentOperationV1,
        currentTool: ToolAgentInstalledToolV1?,
        failure: String?
    ) throws {
        guard failure.map({ !$0.isEmpty && $0.utf8.count <= ToolAgentProtocolLimitsV1.maximumDiagnosticBytes }) ?? true else {
            throw ToolAgentFailureCodeV1.invalidProtocol
        }

        switch operation {
        case .create:
            guard currentTool == nil, failure == nil else {
                throw ToolAgentFailureCodeV1.invalidProtocol
            }
        case .edit:
            guard currentTool != nil, failure == nil else {
                throw ToolAgentFailureCodeV1.invalidProtocol
            }
        case .fix:
            guard currentTool != nil, failure != nil else {
                throw ToolAgentFailureCodeV1.invalidProtocol
            }
        }
    }
}

public struct ToolAgentFingerprintV1: Codable, Equatable, Hashable, Sendable {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }
}

public enum ToolAgentCanonicalJSONV1 {
    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

public enum ToolAgentCandidateFingerprintV1 {
    public static func make(
        candidate: ToolAgentCandidateV1,
        runtimeVersion: String,
        policyVersion: String
    ) throws -> ToolAgentFingerprintV1 {
        guard !runtimeVersion.isEmpty, !policyVersion.isEmpty else {
            throw ToolAgentFailureCodeV1.invalidCandidate
        }
        let canonical = try ToolAgentCanonicalJSONV1.encode(
            FingerprintInput(candidate: candidate, runtimeVersion: runtimeVersion, policyVersion: policyVersion)
        )
        let digest = SHA256.hash(data: canonical)
        return ToolAgentFingerprintV1(digest.map { String(format: "%02x", $0) }.joined())
    }

    private struct FingerprintInput: Codable {
        let candidate: ToolAgentCandidateV1
        let runtimeVersion: String
        let policyVersion: String
    }
}

public struct ToolAgentWriteCandidateRequestV1: Codable, Equatable, Sendable {
    public let candidate: ToolAgentCandidateV1

    public init(candidate: ToolAgentCandidateV1) {
        self.candidate = candidate
    }
}
