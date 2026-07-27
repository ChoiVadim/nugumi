import Foundation

public indirect enum ToolAgentJSONValueV1: Codable, Equatable, Sendable {
    case null
    case boolean(Bool)
    case number(Double)
    case string(String)
    case array([ToolAgentJSONValueV1])
    case object([String: ToolAgentJSONValueV1])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let boolean = try? container.decode(Bool.self) {
            self = .boolean(boolean)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if var array = try? decoder.unkeyedContainer() {
            var values: [ToolAgentJSONValueV1] = []
            while !array.isAtEnd {
                values.append(try array.decode(ToolAgentJSONValueV1.self))
            }
            self = .array(values)
        } else {
            let object = try decoder.container(keyedBy: ToolAgentDynamicCodingKeyV1.self)
            var values: [String: ToolAgentJSONValueV1] = [:]
            for key in object.allKeys {
                values[key.stringValue] = try object.decode(ToolAgentJSONValueV1.self, forKey: key)
            }
            self = .object(values)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .boolean(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .number(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case .object(let values):
            var container = encoder.container(keyedBy: ToolAgentDynamicCodingKeyV1.self)
            for key in values.keys {
                guard let codingKey = ToolAgentDynamicCodingKeyV1(stringValue: key), let value = values[key] else {
                    throw ToolAgentFailureCodeV1.invalidModelAction
                }
                try container.encode(value, forKey: codingKey)
            }
        }
    }
}

public enum ModelActionV1: Equatable, Sendable {
    case toolCall(name: ToolAgentToolNameV1, arguments: ToolAgentJSONValueV1)
    case finalText(String)

    public static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= ToolAgentProtocolLimitsV1.maximumFrameBytes else {
            throw ToolAgentFailureCodeV1.invalidModelAction
        }
        do {
            try ToolAgentStrictJSONV1.validate(Data(text.utf8))
            let wire = try JSONDecoder().decode(ModelActionWire.self, from: Data(text.utf8))
            guard wire.version == 1 else { throw ToolAgentFailureCodeV1.invalidModelAction }
            switch wire.action {
            case .toolCall:
                guard wire.keys == Set(["action", "arguments", "name", "version"]),
                      let name = wire.name,
                      let arguments = wire.arguments,
                      wire.text == nil else {
                    throw ToolAgentFailureCodeV1.invalidModelAction
                }
                return .toolCall(name: name, arguments: arguments)
            case .finalText:
                guard wire.keys == Set(["action", "text", "version"]),
                      let finalText = wire.text,
                      wire.name == nil,
                      wire.arguments == nil,
                      finalText.utf8.count <= ToolAgentProtocolLimitsV1.maximumSafeMessageBytes else {
                    throw ToolAgentFailureCodeV1.invalidModelAction
                }
                return .finalText(finalText)
            }
        } catch {
            throw ToolAgentFailureCodeV1.invalidModelAction
        }
    }
}

private enum ModelActionKindV1: String, Codable {
    case toolCall
    case finalText
}

private struct ModelActionWire: Decodable {
    let version: Int
    let action: ModelActionKindV1
    let name: ToolAgentToolNameV1?
    let arguments: ToolAgentJSONValueV1?
    let text: String?
    let keys: Set<String>

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ToolAgentDynamicCodingKeyV1.self)
        self.version = try container.decode(Int.self, forKey: .required("version"))
        self.action = try container.decode(ModelActionKindV1.self, forKey: .required("action"))
        self.name = try container.decodeIfPresent(ToolAgentToolNameV1.self, forKey: .required("name"))
        self.arguments = try container.decodeIfPresent(ToolAgentJSONValueV1.self, forKey: .required("arguments"))
        self.text = try container.decodeIfPresent(String.self, forKey: .required("text"))
        self.keys = Set(container.allKeys.map(\.stringValue))
    }
}

struct ToolAgentDynamicCodingKeyV1: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }

    init(_ value: String) {
        self.stringValue = value
        self.intValue = nil
    }

    static func required(_ value: String) -> Self {
        Self(value)
    }
}
