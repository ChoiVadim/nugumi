import Foundation

public enum ToolAgentJSONLCodecV1 {
    public static func encode(_ message: ToolAgentMessageV1) throws -> Data {
        var line = try ToolAgentCanonicalJSONV1.encode(message)
        line.append(0x0A)
        guard line.count <= ToolAgentProtocolLimitsV1.maximumFrameBytes else {
            throw ToolAgentProtocolErrorV1.frameTooLarge
        }
        return line
    }

    public static func decode(_ line: Data) throws -> ToolAgentMessageV1 {
        guard line.count <= ToolAgentProtocolLimitsV1.maximumFrameBytes else {
            throw ToolAgentProtocolErrorV1.frameTooLarge
        }
        let json = Data(line.last == 0x0A ? line.dropLast() : line[...])
        try ToolAgentStrictJSONV1.validate(json)
        guard let header = try? JSONDecoder().decode(ToolAgentVersionEnvelopeV1.self, from: json) else {
            throw ToolAgentProtocolErrorV1.malformedMessage
        }
        guard header.version == 1 else {
            throw ToolAgentProtocolErrorV1.unsupportedVersion
        }
        do {
            return try JSONDecoder().decode(ToolAgentMessageV1.self, from: json)
        } catch {
            throw ToolAgentProtocolErrorV1.malformedMessage
        }
    }
}

private struct ToolAgentVersionEnvelopeV1: Decodable {
    let version: Int
}

struct ToolAgentStrictJSONV1 {
    private let bytes: [UInt8]
    private var index = 0

    private init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    static func validate(_ data: Data) throws {
        var parser = Self(bytes: Array(data))
        try parser.parseDocument()
    }

    private mutating func parseDocument() throws {
        try skipWhitespace()
        try parseValue()
        try skipWhitespace()
        guard index == bytes.count else { throw ToolAgentProtocolErrorV1.malformedMessage }
    }

    private mutating func parseValue() throws {
        guard let byte = currentByte else { throw ToolAgentProtocolErrorV1.malformedMessage }
        switch byte {
        case 0x7B:
            try parseObject()
        case 0x5B:
            try parseArray()
        case 0x22:
            _ = try parseString()
        case 0x74:
            try parseLiteral([0x74, 0x72, 0x75, 0x65])
        case 0x66:
            try parseLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
        case 0x6E:
            try parseLiteral([0x6E, 0x75, 0x6C, 0x6C])
        case 0x2D, 0x30...0x39:
            _ = try parseNumber()
        default:
            throw ToolAgentProtocolErrorV1.malformedMessage
        }
    }

    private mutating func parseObject() throws {
        try consume(0x7B)
        try skipWhitespace()
        if currentByte == 0x7D {
            index += 1
            return
        }
        var keys = Set<String>()
        while true {
            let key = try parseKey()
            guard keys.insert(key).inserted else { throw ToolAgentProtocolErrorV1.malformedMessage }
            try skipWhitespace()
            try consume(0x3A)
            try skipWhitespace()
            try parseValue()
            try skipWhitespace()
            guard let delimiter = currentByte else { throw ToolAgentProtocolErrorV1.malformedMessage }
            if delimiter == 0x7D {
                index += 1
                return
            }
            try consume(0x2C)
            try skipWhitespace()
        }
    }

    private mutating func parseArray() throws {
        try consume(0x5B)
        try skipWhitespace()
        if currentByte == 0x5D {
            index += 1
            return
        }
        while true {
            try parseValue()
            try skipWhitespace()
            guard let delimiter = currentByte else { throw ToolAgentProtocolErrorV1.malformedMessage }
            if delimiter == 0x5D {
                index += 1
                return
            }
            try consume(0x2C)
            try skipWhitespace()
        }
    }

    private mutating func parseKey() throws -> String {
        let string = try parseString()
        guard !string.hadEscape else { throw ToolAgentProtocolErrorV1.malformedMessage }
        return String(decoding: string.bytes, as: UTF8.self)
    }

    private mutating func parseString() throws -> (bytes: [UInt8], hadEscape: Bool) {
        try consume(0x22)
        var stringBytes: [UInt8] = []
        var hadEscape = false
        while let byte = currentByte {
            index += 1
            if byte == 0x22 { return (stringBytes, hadEscape) }
            guard byte >= 0x20 else { throw ToolAgentProtocolErrorV1.malformedMessage }
            if byte == 0x5C {
                hadEscape = true
                guard let escaped = currentByte else { throw ToolAgentProtocolErrorV1.malformedMessage }
                index += 1
                switch escaped {
                case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                    continue
                case 0x75:
                    try consumeHexDigits(count: 4)
                    continue
                default:
                    throw ToolAgentProtocolErrorV1.malformedMessage
                }
            }
            stringBytes.append(byte)
        }
        throw ToolAgentProtocolErrorV1.malformedMessage
    }

    private mutating func parseNumber() throws -> String {
        let start = index
        if currentByte == 0x2D { index += 1 }
        guard let first = currentByte else { throw ToolAgentProtocolErrorV1.malformedMessage }
        if first == 0x30 {
            index += 1
        } else {
            try consumeDigits(minimum: 1)
        }
        if currentByte == 0x2E {
            index += 1
            try consumeDigits(minimum: 1)
        }
        if currentByte == 0x45 || currentByte == 0x65 {
            index += 1
            if currentByte == 0x2B || currentByte == 0x2D { index += 1 }
            try consumeDigits(minimum: 1)
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func parseLiteral(_ literal: [UInt8]) throws {
        for byte in literal { try consume(byte) }
    }

    private mutating func consumeDigits(minimum: Int) throws {
        let start = index
        while let byte = currentByte, (0x30...0x39).contains(byte) { index += 1 }
        guard index - start >= minimum else { throw ToolAgentProtocolErrorV1.malformedMessage }
    }

    private mutating func consumeHexDigits(count: Int) throws {
        for _ in 0..<count {
            guard let byte = currentByte,
                  (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte) else {
                throw ToolAgentProtocolErrorV1.malformedMessage
            }
            index += 1
        }
    }

    private mutating func skipWhitespace() throws {
        while let byte = currentByte, byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { index += 1 }
    }

    private mutating func consume(_ expected: UInt8) throws {
        guard currentByte == expected else { throw ToolAgentProtocolErrorV1.malformedMessage }
        index += 1
    }

    private var currentByte: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }
}
