import Foundation

/// The wire protocol for an **agent tool's run**, as opposed to a tool build.
///
/// Same transport, same framing, same model bridge; a different vocabulary. The
/// two are separate types rather than one union because their terminal states
/// genuinely differ: a build completes with an attested candidate fingerprint,
/// while a run completes with an answer. Folding both into
/// `ToolAgentMessageV1.completed` would mean loosening the type that carries the
/// build's attestation, which is the one place least worth loosening.
public struct AgentRunStartV1: Codable, Equatable, Sendable {
    /// The tool's frozen instruction — its `prompt` field.
    public let instruction: String
    /// What the ring handed the tool: the selection, the typed text, the
    /// clipboard. Empty for a `.none` input.
    public let input: String
    public let budgets: ToolAgentBudgetsV1
    /// Names only. The values are already in the environment of every script the
    /// host runs for this tool, so they never travel over this protocol.
    public let secretNames: [String]

    public init(
        instruction: String,
        input: String,
        budgets: ToolAgentBudgetsV1,
        secretNames: [String] = []
    ) {
        self.instruction = instruction
        self.input = input
        self.budgets = budgets
        self.secretNames = secretNames
    }
}

public enum AgentRunToolNameV1: String, Codable, CaseIterable, Equatable, Sendable {
    case runPython = "run_python"
    case finish
}

public struct AgentRunPythonRequestV1: Codable, Equatable, Sendable {
    public let source: String
    /// One line on what this step is for. Never executed — it exists so a run
    /// that goes wrong can be read afterwards without reverse-engineering five
    /// Python scripts.
    public let purpose: String

    public init(source: String, purpose: String) {
        self.source = source
        self.purpose = purpose
    }
}

public struct AgentRunFinishRequestV1: Codable, Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public enum AgentRunToolRequestV1: Codable, Equatable, Sendable {
    case runPython(AgentRunPythonRequestV1)
    case finish(AgentRunFinishRequestV1)

    private enum CodingKeys: String, CodingKey { case name, payload }

    public var name: AgentRunToolNameV1 {
        switch self {
        case .runPython: return .runPython
        case .finish: return .finish
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(AgentRunToolNameV1.self, forKey: .name) {
        case .runPython:
            self = .runPython(try container.decode(AgentRunPythonRequestV1.self, forKey: .payload))
        case .finish:
            self = .finish(try container.decode(AgentRunFinishRequestV1.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        switch self {
        case .runPython(let value): try container.encode(value, forKey: .payload)
        case .finish(let value): try container.encode(value, forKey: .payload)
        }
    }
}

/// What a script's run looked like, reported the way a shell would rather than
/// as a verdict: the agent is the one deciding what a non-zero exit means.
public struct AgentRunPythonResponseV1: Codable, Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    /// Whether either stream was cut to fit. Told to the model explicitly,
    /// because silently truncated output is how an agent concludes a file is
    /// empty when it is merely long.
    public let truncated: Bool
    public let producedFiles: [String]

    public init(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        truncated: Bool = false,
        producedFiles: [String] = []
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.truncated = truncated
        self.producedFiles = producedFiles
    }
}

public struct AgentRunFinishResponseV1: Codable, Equatable, Sendable {
    public let accepted: Bool

    public init(accepted: Bool = true) {
        self.accepted = accepted
    }
}

public enum AgentRunToolResponseV1: Codable, Equatable, Sendable {
    case runPython(AgentRunPythonResponseV1)
    case finish(AgentRunFinishResponseV1)

    private enum CodingKeys: String, CodingKey { case name, payload }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(AgentRunToolNameV1.self, forKey: .name) {
        case .runPython:
            self = .runPython(try container.decode(AgentRunPythonResponseV1.self, forKey: .payload))
        case .finish:
            self = .finish(try container.decode(AgentRunFinishResponseV1.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .runPython(let value):
            try container.encode(AgentRunToolNameV1.runPython, forKey: .name)
            try container.encode(value, forKey: .payload)
        case .finish(let value):
            try container.encode(AgentRunToolNameV1.finish, forKey: .name)
            try container.encode(value, forKey: .payload)
        }
    }
}

public struct AgentRunToolRequestEnvelopeV1: Codable, Equatable, Sendable {
    public let callID: UUID
    public let request: AgentRunToolRequestV1

    public init(callID: UUID, request: AgentRunToolRequestV1) {
        self.callID = callID
        self.request = request
    }
}

public struct AgentRunToolResponseEnvelopeV1: Codable, Equatable, Sendable {
    public let callID: UUID
    public let result: AgentRunToolResponseV1

    public init(callID: UUID, result: AgentRunToolResponseV1) {
        self.callID = callID
        self.result = result
    }
}

/// The run's answer. Carries the same payload the agent passed to `finish`,
/// because that call *is* the result.
public struct AgentRunCompletedV1: Codable, Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public enum AgentRunMessageTypeV1: String, Codable, CaseIterable, Equatable, Sendable {
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

public enum AgentRunMessagePayloadV1: Equatable, Sendable {
    case start(AgentRunStartV1)
    case modelResponse(ToolAgentModelResponseV1)
    case toolResponse(AgentRunToolResponseEnvelopeV1)
    case cancel(ToolAgentCancelV1)
    case state(ToolAgentStateUpdateV1)
    case modelRequest(ToolAgentModelRequestV1)
    case toolRequest(AgentRunToolRequestEnvelopeV1)
    case completed(AgentRunCompletedV1)
    case failed(ToolAgentFailedV1)

    fileprivate static func decode(
        type: AgentRunMessageTypeV1,
        from decoder: Decoder
    ) throws -> Self {
        switch type {
        case .start: return .start(try AgentRunStartV1(from: decoder))
        case .modelResponse: return .modelResponse(try ToolAgentModelResponseV1(from: decoder))
        case .toolResponse: return .toolResponse(try AgentRunToolResponseEnvelopeV1(from: decoder))
        case .cancel: return .cancel(try ToolAgentCancelV1(from: decoder))
        case .state: return .state(try ToolAgentStateUpdateV1(from: decoder))
        case .modelRequest: return .modelRequest(try ToolAgentModelRequestV1(from: decoder))
        case .toolRequest: return .toolRequest(try AgentRunToolRequestEnvelopeV1(from: decoder))
        case .completed: return .completed(try AgentRunCompletedV1(from: decoder))
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

public struct AgentRunMessageV1: Codable, Equatable, Sendable {
    public let version: Int
    public let runID: UUID
    public let type: AgentRunMessageTypeV1
    public let payload: AgentRunMessagePayloadV1

    private init(runID: UUID, type: AgentRunMessageTypeV1, payload: AgentRunMessagePayloadV1) {
        self.version = 1
        self.runID = runID
        self.type = type
        self.payload = payload
    }

    public static func start(runID: UUID, _ value: AgentRunStartV1) -> Self {
        Self(runID: runID, type: .start, payload: .start(value))
    }

    public static func modelResponse(runID: UUID, _ value: ToolAgentModelResponseV1) -> Self {
        Self(runID: runID, type: .modelResponse, payload: .modelResponse(value))
    }

    public static func toolResponse(runID: UUID, _ value: AgentRunToolResponseEnvelopeV1) -> Self {
        Self(runID: runID, type: .toolResponse, payload: .toolResponse(value))
    }

    public static func cancel(runID: UUID, _ value: ToolAgentCancelV1) -> Self {
        Self(runID: runID, type: .cancel, payload: .cancel(value))
    }

    private enum CodingKeys: String, CodingKey { case version, type, runID, payload }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == 1 else { throw ToolAgentProtocolErrorV1.unsupportedVersion }
        let type = try container.decode(AgentRunMessageTypeV1.self, forKey: .type)
        let runID = try container.decode(UUID.self, forKey: .runID)
        self.version = version
        self.type = type
        self.runID = runID
        self.payload = try AgentRunMessagePayloadV1.decode(
            type: type,
            from: container.superDecoder(forKey: .payload)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(type, forKey: .type)
        try container.encode(runID, forKey: .runID)
        try payload.encode(to: container.superEncoder(forKey: .payload))
    }
}

public enum AgentRunJSONLCodecV1 {
    public static func encode(_ message: AgentRunMessageV1) throws -> Data {
        var line = try ToolAgentCanonicalJSONV1.encode(message)
        line.append(0x0A)
        guard line.count <= ToolAgentProtocolLimitsV1.maximumFrameBytes else {
            throw ToolAgentProtocolErrorV1.frameTooLarge
        }
        return line
    }

    public static func decode(_ line: Data) throws -> AgentRunMessageV1 {
        guard line.count <= ToolAgentProtocolLimitsV1.maximumFrameBytes else {
            throw ToolAgentProtocolErrorV1.frameTooLarge
        }
        let json = Data(line.last == 0x0A ? line.dropLast() : line[...])
        try ToolAgentStrictJSONV1.validate(json)
        do {
            return try JSONDecoder().decode(AgentRunMessageV1.self, from: json)
        } catch {
            throw ToolAgentProtocolErrorV1.malformedMessage
        }
    }
}
