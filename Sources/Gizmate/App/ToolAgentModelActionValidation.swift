import Foundation
import GizmateToolAgentCore

enum ToolAgentModelActionValidator {
    static func isValid(_ text: String) -> Bool {
        normalized(text) != nil
    }

    /// Models occasionally wrap an otherwise exact action in a single JSON code
    /// fence. Keep the wire protocol strict, but remove that presentation-only
    /// wrapper before the response crosses into the sidecar.
    static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isStrictlyValid(trimmed) {
            return trimmed
        }
        guard trimmed.hasPrefix("```"),
              trimmed.hasSuffix("```"),
              let firstLineEnd = trimmed.firstIndex(of: "\n") else {
            return nil
        }
        let opening = trimmed[..<firstLineEnd]
        guard opening == "```" || opening.lowercased() == "```json" else {
            return nil
        }
        let bodyStart = trimmed.index(after: firstLineEnd)
        let closingStart = trimmed.index(trimmed.endIndex, offsetBy: -3)
        let body = trimmed[bodyStart..<closingStart]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.contains("```"), isStrictlyValid(body) else {
            return nil
        }
        return body
    }

    private static func isStrictlyValid(_ text: String) -> Bool {
        guard let action = try? ModelActionV1.parse(text) else { return false }
        switch action {
        case .finalText:
            return true
        case .toolCall(let name, let arguments):
            guard case .object(let object) = arguments else { return false }
            switch name {
            case .readBuildContext:
                return object.isEmpty
            case .writeCandidate:
                // The candidate schema lives in exactly one place: the Codable
                // model. Decoding applies every structural rule it knows, and
                // comparing the canonical re-encoding against what the model
                // actually sent rejects extra, missing, or kind-irrelevant keys
                // — without a hand-maintained second copy of the field list
                // that has to be edited every time the schema grows.
                guard Set(object.keys) == Set(["candidate"]),
                      let sent = object["candidate"],
                      let data = try? ToolAgentCanonicalJSONV1.encode(sent),
                      let candidate = try? JSONDecoder().decode(
                          ToolAgentCandidateV1.self,
                          from: data
                      ),
                      let roundTripped = try? ToolAgentCanonicalJSONV1
                          .encode(candidate),
                      roundTripped == data else {
                    return false
                }
                return true
            case .runValidation:
                guard Set(object.keys) == Set(["candidateID"]),
                      case .string(let rawID)? = object["candidateID"],
                      UUID(uuidString: rawID) != nil else {
                    return false
                }
                return true
            case .finishCandidate:
                guard Set(object.keys) == Set(["candidateID", "fingerprint"]),
                      case .string(let rawID)? = object["candidateID"],
                      UUID(uuidString: rawID) != nil,
                      case .object(let fingerprint)? = object["fingerprint"],
                      Set(fingerprint.keys) == Set(["value"]),
                      case .string(let value)? = fingerprint["value"],
                      value.range(
                          of: #"^[a-f0-9]{64}$"#,
                          options: .regularExpression
                      ) != nil else {
                    return false
                }
                return true
            case .askUser:
                guard Set(object.keys) == Set(["question"]) else { return false }
                return decodes(arguments, as: ToolAgentAskUserRequestV1.self)
            }
        }
    }

    private static func decodes<Value: Decodable>(
        _ value: ToolAgentJSONValueV1,
        as type: Value.Type
    ) -> Bool {
        guard let data = try? ToolAgentCanonicalJSONV1.encode(value) else {
            return false
        }
        return (try? JSONDecoder().decode(type, from: data)) != nil
    }
}

enum ToolAgentModelActionInspector {
    static func unsupportedMessage(in text: String) -> String? {
        guard
            let normalized = ToolAgentModelActionValidator.normalized(text),
            case .finalText(let value) = try? ModelActionV1.parse(normalized)
        else {
            return nil
        }
        let prefix = "UNSUPPORTED:"
        guard value.hasPrefix(prefix) else { return nil }
        let message = value.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }
}
