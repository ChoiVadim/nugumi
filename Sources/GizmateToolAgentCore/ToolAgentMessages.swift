import Foundation

public struct ToolAgentBudgetsV1: Codable, Equatable, Sendable {
    public let modelTurns: Int
    public let toolCalls: Int
    public let repairs: Int
    public let durationSeconds: Int

    public init(modelTurns: Int, toolCalls: Int, repairs: Int, durationSeconds: Int) {
        self.modelTurns = modelTurns
        self.toolCalls = toolCalls
        self.repairs = repairs
        self.durationSeconds = durationSeconds
    }

    /// A build costs the model five turns before any repair: read the context,
    /// write, validate, finish, and say it finished. Each repair adds a write
    /// and a validation, so a usable repair budget needs `5 + 2 * repairs`
    /// turns — anything less and the agent runs out of turns holding a
    /// candidate that already passed, which is the worst possible failure: the
    /// work is done and gets thrown away. `minimumModelTurns` states that, and
    /// the extra turn is slack for a wasted call.
    public static let preview = Self(modelTurns: 12, toolCalls: 32, repairs: 3, durationSeconds: 900)

    /// Turns needed before any repair: read_build_context, write_candidate,
    /// run_validation, finish_candidate, finalText.
    public static let turnsBeforeRepairs = 5

    /// Turns one repair costs: another write_candidate and run_validation.
    public static let turnsPerRepair = 2

    public var minimumModelTurns: Int {
        Self.turnsBeforeRepairs + Self.turnsPerRepair * repairs
    }
}

public struct ToolAgentStartV1: Codable, Equatable, Sendable {
    public let description: String
    public let budgets: ToolAgentBudgetsV1
    public let operation: ToolAgentOperationV1
    public let currentTool: ToolAgentInstalledToolV1?
    public let failure: String?

    public init(description: String, budgets: ToolAgentBudgetsV1) {
        self.description = description
        self.budgets = budgets
        self.operation = .create
        self.currentTool = nil
        self.failure = nil
    }

    public init(
        description: String,
        budgets: ToolAgentBudgetsV1,
        operation: ToolAgentOperationV1,
        currentTool: ToolAgentInstalledToolV1? = nil,
        failure: String? = nil
    ) throws {
        try ToolAgentRequestContractV1.validate(
            operation: operation,
            currentTool: currentTool,
            failure: failure
        )
        self.description = description
        self.budgets = budgets
        self.operation = operation
        self.currentTool = currentTool
        self.failure = failure
    }

    private enum CodingKeys: String, CodingKey {
        case description
        case budgets
        case operation
        case currentTool
        case failure
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            description: container.decode(String.self, forKey: .description),
            budgets: container.decode(ToolAgentBudgetsV1.self, forKey: .budgets),
            operation: container.decodeIfPresent(ToolAgentOperationV1.self, forKey: .operation) ?? .create,
            currentTool: container.decodeIfPresent(ToolAgentInstalledToolV1.self, forKey: .currentTool),
            failure: container.decodeIfPresent(String.self, forKey: .failure)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(description, forKey: .description)
        try container.encode(budgets, forKey: .budgets)
        try container.encode(operation, forKey: .operation)
        try container.encodeIfPresent(currentTool, forKey: .currentTool)
        try container.encodeIfPresent(failure, forKey: .failure)
    }
}

public enum ToolAgentModelResponseResultV1: Codable, Equatable, Sendable {
    case text(String)
    case error(ToolAgentFailureCodeV1)

    private enum CodingKeys: String, CodingKey { case kind, text, error }
    private enum Kind: String, Codable { case text, error }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .text: self = .text(try container.decode(String.self, forKey: .text))
        case .error: self = .error(try container.decode(ToolAgentFailureCodeV1.self, forKey: .error))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(text, forKey: .text)
        case .error(let error):
            try container.encode(Kind.error, forKey: .kind)
            try container.encode(error, forKey: .error)
        }
    }
}

public struct ToolAgentModelResponseV1: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let result: ToolAgentModelResponseResultV1

    public init(requestID: UUID, result: ToolAgentModelResponseResultV1) {
        self.requestID = requestID
        self.result = result
    }
}

public enum ToolAgentCancelReasonV1: String, Codable, Equatable, Sendable {
    case userRequested
    case deadlineExceeded
}

public struct ToolAgentCancelV1: Codable, Equatable, Sendable {
    public let reason: ToolAgentCancelReasonV1

    public init(reason: ToolAgentCancelReasonV1) {
        self.reason = reason
    }
}

public struct ToolAgentStateUpdateV1: Codable, Equatable, Sendable {
    public let state: ToolAgentBuildStateV1

    public init(state: ToolAgentBuildStateV1) {
        self.state = state
    }
}

public struct ToolAgentModelRequestV1: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let system: String
    public let user: String

    public init(requestID: UUID, system: String, user: String) {
        self.requestID = requestID
        self.system = system
        self.user = user
    }
}

public struct ToolAgentCompletedV1: Codable, Equatable, Sendable {
    public let candidateID: UUID
    public let fingerprint: ToolAgentFingerprintV1

    public init(candidateID: UUID, fingerprint: ToolAgentFingerprintV1) {
        self.candidateID = candidateID
        self.fingerprint = fingerprint
    }
}

public struct ToolAgentFailedV1: Codable, Equatable, Sendable {
    public let code: ToolAgentFailureCodeV1
    public let message: String

    public init(code: ToolAgentFailureCodeV1, message: String) {
        self.code = code
        self.message = message
    }
}

public struct ToolAgentMessageV1: Codable, Equatable, Sendable {
    public let version: Int
    public let runID: UUID
    public let type: ToolAgentMessageTypeV1
    public let payload: ToolAgentMessagePayloadV1

    private init(runID: UUID, type: ToolAgentMessageTypeV1, payload: ToolAgentMessagePayloadV1) {
        self.version = 1
        self.runID = runID
        self.type = type
        self.payload = payload
    }

    public static func start(runID: UUID, _ value: ToolAgentStartV1) -> Self { Self(runID: runID, type: .start, payload: .start(value)) }
    public static func modelResponse(runID: UUID, _ value: ToolAgentModelResponseV1) -> Self { Self(runID: runID, type: .modelResponse, payload: .modelResponse(value)) }
    public static func toolResponse(runID: UUID, _ value: ToolAgentToolResponseEnvelopeV1) -> Self { Self(runID: runID, type: .toolResponse, payload: .toolResponse(value)) }
    public static func cancel(runID: UUID, _ value: ToolAgentCancelV1) -> Self { Self(runID: runID, type: .cancel, payload: .cancel(value)) }
    public static func state(runID: UUID, _ value: ToolAgentStateUpdateV1) -> Self { Self(runID: runID, type: .state, payload: .state(value)) }
    public static func modelRequest(runID: UUID, _ value: ToolAgentModelRequestV1) -> Self { Self(runID: runID, type: .modelRequest, payload: .modelRequest(value)) }
    public static func toolRequest(runID: UUID, _ value: ToolAgentToolRequestEnvelopeV1) -> Self { Self(runID: runID, type: .toolRequest, payload: .toolRequest(value)) }
    public static func completed(runID: UUID, _ value: ToolAgentCompletedV1) -> Self { Self(runID: runID, type: .completed, payload: .completed(value)) }
    public static func failed(runID: UUID, _ value: ToolAgentFailedV1) -> Self { Self(runID: runID, type: .failed, payload: .failed(value)) }

    private enum CodingKeys: String, CodingKey { case version, type, runID, payload }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == 1 else { throw ToolAgentProtocolErrorV1.unsupportedVersion }
        let type = try container.decode(ToolAgentMessageTypeV1.self, forKey: .type)
        let runID = try container.decode(UUID.self, forKey: .runID)
        let payload = try ToolAgentMessagePayloadV1.decode(type: type, from: container.superDecoder(forKey: .payload))
        self.version = version
        self.type = type
        self.runID = runID
        self.payload = payload
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(type, forKey: .type)
        try container.encode(runID, forKey: .runID)
        try payload.encode(to: container.superEncoder(forKey: .payload))
    }
}

public enum ToolAgentMessageTypeV1: String, Codable, CaseIterable, Equatable, Sendable {
    case start
    case modelResponse
    case toolResponse
    case cancel
    case state
    case modelRequest
    case toolRequest
    case completed
    case failed
}

public enum ToolAgentMessagePayloadV1: Equatable, Sendable {
    case start(ToolAgentStartV1)
    case modelResponse(ToolAgentModelResponseV1)
    case toolResponse(ToolAgentToolResponseEnvelopeV1)
    case cancel(ToolAgentCancelV1)
    case state(ToolAgentStateUpdateV1)
    case modelRequest(ToolAgentModelRequestV1)
    case toolRequest(ToolAgentToolRequestEnvelopeV1)
    case completed(ToolAgentCompletedV1)
    case failed(ToolAgentFailedV1)

    fileprivate static func decode(type: ToolAgentMessageTypeV1, from decoder: Decoder) throws -> Self {
        switch type {
        case .start: return .start(try ToolAgentStartV1(from: decoder))
        case .modelResponse: return .modelResponse(try ToolAgentModelResponseV1(from: decoder))
        case .toolResponse: return .toolResponse(try ToolAgentToolResponseEnvelopeV1(from: decoder))
        case .cancel: return .cancel(try ToolAgentCancelV1(from: decoder))
        case .state: return .state(try ToolAgentStateUpdateV1(from: decoder))
        case .modelRequest: return .modelRequest(try ToolAgentModelRequestV1(from: decoder))
        case .toolRequest: return .toolRequest(try ToolAgentToolRequestEnvelopeV1(from: decoder))
        case .completed: return .completed(try ToolAgentCompletedV1(from: decoder))
        case .failed: return .failed(try ToolAgentFailedV1(from: decoder))
        }
    }

    fileprivate func encode(to encoder: Encoder) throws {
        switch self {
        case .start(let value): try value.encode(to: encoder)
        case .modelResponse(let value): try value.encode(to: encoder)
        case .toolResponse(let value): try value.encode(to: encoder)
        case .cancel(let value): try value.encode(to: encoder)
        case .state(let value): try value.encode(to: encoder)
        case .modelRequest(let value): try value.encode(to: encoder)
        case .toolRequest(let value): try value.encode(to: encoder)
        case .completed(let value): try value.encode(to: encoder)
        case .failed(let value): try value.encode(to: encoder)
        }
    }
}
