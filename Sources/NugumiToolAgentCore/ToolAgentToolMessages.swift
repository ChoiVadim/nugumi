import Foundation

public enum ToolAgentToolNameV1: String, Codable, CaseIterable, Equatable, Sendable {
    case readBuildContext = "read_build_context"
    case writeCandidate = "write_candidate"
    case runValidation = "run_validation"
    case finishCandidate = "finish_candidate"
    case askUser = "ask_user"
}

public struct ToolAgentReadBuildContextRequestV1: Codable, Equatable, Sendable {
    public init() {}
}

public enum ToolAgentToolRequestV1: Codable, Equatable, Sendable {
    case readBuildContext(ToolAgentReadBuildContextRequestV1)
    case writeCandidate(ToolAgentWriteCandidateRequestV1)
    case runValidation(ToolAgentRunValidationRequestV1)
    case finishCandidate(ToolAgentFinishCandidateRequestV1)
    case askUser(ToolAgentAskUserRequestV1)

    private enum CodingKeys: String, CodingKey { case name, payload }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ToolAgentToolNameV1.self, forKey: .name) {
        case .readBuildContext: self = .readBuildContext(try container.decode(ToolAgentReadBuildContextRequestV1.self, forKey: .payload))
        case .writeCandidate: self = .writeCandidate(try container.decode(ToolAgentWriteCandidateRequestV1.self, forKey: .payload))
        case .runValidation: self = .runValidation(try container.decode(ToolAgentRunValidationRequestV1.self, forKey: .payload))
        case .finishCandidate: self = .finishCandidate(try container.decode(ToolAgentFinishCandidateRequestV1.self, forKey: .payload))
        case .askUser: self = .askUser(try container.decode(ToolAgentAskUserRequestV1.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .readBuildContext(let value):
            try container.encode(ToolAgentToolNameV1.readBuildContext, forKey: .name)
            try container.encode(value, forKey: .payload)
        case .writeCandidate(let value):
            try container.encode(ToolAgentToolNameV1.writeCandidate, forKey: .name)
            try container.encode(value, forKey: .payload)
        case .runValidation(let value):
            try container.encode(ToolAgentToolNameV1.runValidation, forKey: .name)
            try container.encode(value, forKey: .payload)
        case .finishCandidate(let value):
            try container.encode(ToolAgentToolNameV1.finishCandidate, forKey: .name)
            try container.encode(value, forKey: .payload)
        case .askUser(let value):
            try container.encode(ToolAgentToolNameV1.askUser, forKey: .name)
            try container.encode(value, forKey: .payload)
        }
    }
}

public struct ToolAgentToolRequestEnvelopeV1: Codable, Equatable, Sendable {
    public let callID: UUID
    public let request: ToolAgentToolRequestV1

    public init(callID: UUID, request: ToolAgentToolRequestV1) {
        self.callID = callID
        self.request = request
    }
}

public struct ToolAgentReadBuildContextResponseV1: Codable, Equatable, Sendable {
    public let remaining: ToolAgentUsageCountersV1

    public init(remaining: ToolAgentUsageCountersV1) {
        self.remaining = remaining
    }
}

public enum ToolAgentToolResponseV1: Codable, Equatable, Sendable {
    case readBuildContext(ToolAgentReadBuildContextResponseV1)
    case writeCandidate(ToolAgentWriteCandidateResponseV1)
    case runValidation(ToolAgentValidationReportV1)
    case finishCandidate(ToolAgentAttestationV1)
    case askUser(ToolAgentAskUserResponseV1)

    private enum CodingKeys: String, CodingKey { case name, payload }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ToolAgentToolNameV1.self, forKey: .name) {
        case .readBuildContext: self = .readBuildContext(try container.decode(ToolAgentReadBuildContextResponseV1.self, forKey: .payload))
        case .writeCandidate: self = .writeCandidate(try container.decode(ToolAgentWriteCandidateResponseV1.self, forKey: .payload))
        case .runValidation: self = .runValidation(try container.decode(ToolAgentValidationReportV1.self, forKey: .payload))
        case .finishCandidate: self = .finishCandidate(try container.decode(ToolAgentAttestationV1.self, forKey: .payload))
        case .askUser: self = .askUser(try container.decode(ToolAgentAskUserResponseV1.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .readBuildContext(let value):
            try container.encode(ToolAgentToolNameV1.readBuildContext, forKey: .name)
            try container.encode(value, forKey: .payload)
        case .writeCandidate(let value):
            try container.encode(ToolAgentToolNameV1.writeCandidate, forKey: .name)
            try container.encode(value, forKey: .payload)
        case .runValidation(let value):
            try container.encode(ToolAgentToolNameV1.runValidation, forKey: .name)
            try container.encode(value, forKey: .payload)
        case .finishCandidate(let value):
            try container.encode(ToolAgentToolNameV1.finishCandidate, forKey: .name)
            try container.encode(value, forKey: .payload)
        case .askUser(let value):
            try container.encode(ToolAgentToolNameV1.askUser, forKey: .name)
            try container.encode(value, forKey: .payload)
        }
    }
}

public struct ToolAgentToolResponseEnvelopeV1: Codable, Equatable, Sendable {
    public let callID: UUID
    public let result: ToolAgentToolResponseV1

    public init(callID: UUID, result: ToolAgentToolResponseV1) {
        self.callID = callID
        self.result = result
    }
}
