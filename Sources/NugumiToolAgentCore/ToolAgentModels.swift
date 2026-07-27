import CryptoKit
import Foundation

public enum ToolAgentProtocolLimitsV1 {
    public static let maximumFrameBytes = 1_024 * 1_024
    public static let maximumCandidateEncodedBytes = 900 * 1_024
    public static let maximumNameBytes = 128
    public static let maximumBriefBytes = 1_024
    public static let maximumSymbolNameBytes = 128
    public static let maximumSourceBytes = 64 * 1_024
    public static let maximumFixtureInputBytes = 8 * 1_024
    public static let maximumFixtureOutputBytes = 16 * 1_024
    public static let maximumDiagnosticBytes = 16 * 1_024
    public static let maximumFixtureCount = 3
    public static let maximumSafeMessageBytes = 1_024
}

public enum ToolAgentFailureCodeV1: String, Codable, CaseIterable, Equatable, Error, Sendable {
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
    case workerFailure
    case budgetExhausted
    case attestationFailed
}

public enum ToolAgentBuildStateV1: String, Codable, CaseIterable, Equatable, Sendable {
    case created
    case understanding
    case writing
    case testing
    case diagnosing
    case repairing
    case verifying
    case candidateReady
    case failed
    case cancelled
    case budgetExhausted
}

public struct ToolAgentFixtureV1: Codable, Equatable, Sendable {
    public let input: String
    public let expectedOutput: String

    public init(input: String, expectedOutput: String) {
        self.input = input
        self.expectedOutput = expectedOutput
    }
}

public struct ToolAgentCandidateV1: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let name: String
    public let brief: String
    public let symbolName: String
    public let source: String
    public let fixtures: [ToolAgentFixtureV1]

    public init(
        name: String,
        brief: String,
        symbolName: String,
        source: String,
        fixtures: [ToolAgentFixtureV1]
    ) throws {
        try Self.validate(name: name, brief: brief, symbolName: symbolName, source: source, fixtures: fixtures)
        self.schemaVersion = 1
        self.name = name
        self.brief = brief
        self.symbolName = symbolName
        self.source = source
        self.fixtures = fixtures
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let name = try container.decode(String.self, forKey: .name)
        let brief = try container.decode(String.self, forKey: .brief)
        let symbolName = try container.decode(String.self, forKey: .symbolName)
        let source = try container.decode(String.self, forKey: .source)
        let fixtures = try container.decode([ToolAgentFixtureV1].self, forKey: .fixtures)
        guard schemaVersion == 1 else {
            throw ToolAgentFailureCodeV1.invalidCandidate
        }
        try Self.validate(name: name, brief: brief, symbolName: symbolName, source: source, fixtures: fixtures)
        self.schemaVersion = schemaVersion
        self.name = name
        self.brief = brief
        self.symbolName = symbolName
        self.source = source
        self.fixtures = fixtures
    }

    private static func validate(
        name: String,
        brief: String,
        symbolName: String,
        source: String,
        fixtures: [ToolAgentFixtureV1]
    ) throws {
        guard !name.isEmpty,
              !brief.isEmpty,
              !symbolName.isEmpty,
              !source.isEmpty,
              name.utf8.count <= ToolAgentProtocolLimitsV1.maximumNameBytes,
              brief.utf8.count <= ToolAgentProtocolLimitsV1.maximumBriefBytes,
              symbolName.utf8.count <= ToolAgentProtocolLimitsV1.maximumSymbolNameBytes,
              source.utf8.count <= ToolAgentProtocolLimitsV1.maximumSourceBytes,
              (1...ToolAgentProtocolLimitsV1.maximumFixtureCount).contains(fixtures.count),
              fixtures.allSatisfy({
                  !$0.input.isEmpty
                      && $0.input.utf8.count <= ToolAgentProtocolLimitsV1.maximumFixtureInputBytes
                      && $0.expectedOutput.utf8.count <= ToolAgentProtocolLimitsV1.maximumFixtureOutputBytes
              }) else {
            throw ToolAgentFailureCodeV1.invalidCandidate
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
