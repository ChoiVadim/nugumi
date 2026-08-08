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
        let body = unfenced(text)
        guard body != trimmed, isStrictlyValid(body) else { return nil }
        return body
    }

    /// The response with a single surrounding JSON code fence taken off, or
    /// simply trimmed when there is no fence to take off. Separate from
    /// `normalized` because a diagnosis has to look inside a response that is
    /// *not* valid, and a fenced invalid action must be read rather than
    /// dismissed as "not JSON".
    static func unfenced(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"),
              trimmed.hasSuffix("```"),
              trimmed.count > 6,
              let firstLineEnd = trimmed.firstIndex(of: "\n") else {
            return trimmed
        }
        let opening = trimmed[..<firstLineEnd]
        guard opening == "```" || opening.lowercased() == "```json" else {
            return trimmed
        }
        let bodyStart = trimmed.index(after: firstLineEnd)
        let closingStart = trimmed.index(trimmed.endIndex, offsetBy: -3)
        let body = trimmed[bodyStart..<closingStart]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.contains("```") ? trimmed : body
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

/// Why the host refused a response, in words the model can act on.
///
/// The validator is a bare `Bool`, and that is correct for a gate: the wire
/// protocol is exact, the candidate schema is checked by re-encoding it and
/// comparing byte for byte, and neither is a judgement call. But a gate that
/// only ever says "no" is a terrible teacher. A model that omitted `hosts`, or
/// wrote `"layout": null` instead of leaving the key out, or sent
/// `appliesTargetLanguage` on a Python candidate where it does not belong, was
/// told exactly nothing — it got one blind repair attempt with the same
/// instructions that had just failed, and then the user got "The model returned
/// an invalid agent action", which names no action and no problem.
///
/// This is the diagnostic half. It runs only on the failure path, so it costs
/// nothing when things work, and everything it says is derived from the schema
/// itself rather than from a hand-written list that would drift from it.
enum ToolAgentModelActionDiagnosis {
    /// The one sentence to hand back. `nil` when the response is a valid action.
    static func problem(with text: String) -> String? {
        guard ToolAgentModelActionValidator.normalized(text) == nil else { return nil }
        let body = ToolAgentModelActionValidator.unfenced(text)
        guard
            let parsed = try? JSONSerialization.jsonObject(with: Data(body.utf8)),
            let object = parsed as? [String: Any]
        else {
            return "That was not a single JSON object. Send the action object on "
                + "its own, with no prose before or after it."
        }
        guard (object["version"] as? Int) == 1 else {
            return "\"version\" must be the number 1."
        }
        guard let action = object["action"] as? String else {
            return "\"action\" is missing. It is either \"toolCall\" or \"finalText\"."
        }
        switch action {
        case "finalText":
            guard object["text"] is String else {
                return "A finalText action needs a \"text\" string."
            }
            return "A finalText action carries exactly \"version\", \"action\" and "
                + "\"text\", and nothing else."
        case "toolCall":
            return toolCallProblem(object)
        default:
            return "\"action\" must be \"toolCall\" or \"finalText\", not \"\(action)\"."
        }
    }

    private static func toolCallProblem(_ object: [String: Any]) -> String {
        guard let name = object["name"] as? String else {
            return "A toolCall needs a \"name\"."
        }
        guard let tool = ToolAgentToolNameV1(rawValue: name) else {
            let names = ToolAgentToolNameV1.allCases
                .map { "\"\($0.rawValue)\"" }
                .joined(separator: ", ")
            return "There is no tool called \"\(name)\". The tools are \(names)."
        }
        guard let arguments = object["arguments"] as? [String: Any] else {
            return "\"arguments\" must be an object."
        }
        guard Set(object.keys) == ["version", "action", "name", "arguments"] else {
            return "A toolCall carries exactly \"version\", \"action\", \"name\" and "
                + "\"arguments\". Anything else, including a field for your "
                + "reasoning, is refused."
        }
        switch tool {
        case .readBuildContext:
            return "read_build_context takes no arguments: send \"arguments\": {}."
        case .runValidation:
            return "run_validation takes exactly {\"candidateID\": \"<the id you "
                + "were given>\"}."
        case .finishCandidate:
            return "finish_candidate takes exactly {\"candidateID\": \"<id>\", "
                + "\"fingerprint\": {\"value\": \"<the 64 hex characters validation "
                + "returned>\"}}."
        case .askUser:
            return "ask_user takes exactly {\"question\": \"...\"}."
        case .writeCandidate:
            return candidateProblem(arguments)
        }
    }

    /// The one that actually costs builds.
    ///
    /// A candidate is accepted only if re-encoding it reproduces what was sent,
    /// byte for byte, and the encoder writes exactly the keys of the candidate's
    /// own kind. So a Python candidate must carry `source` and must *not* carry
    /// `prompt`, while the decoder happily defaults both. That asymmetry is what
    /// makes the difference invisible from the model's side, and naming it is
    /// the whole job here.
    private static func candidateProblem(_ arguments: [String: Any]) -> String {
        guard Set(arguments.keys) == ["candidate"],
              let sent = arguments["candidate"] as? [String: Any] else {
            return "write_candidate takes exactly {\"candidate\": { ... }}."
        }
        guard let data = try? JSONSerialization.data(withJSONObject: sent) else {
            return "The candidate was not a JSON object."
        }
        let decoded: ToolAgentCandidateV1
        var culprit: String?
        do {
            decoded = try JSONDecoder().decode(ToolAgentCandidateV1.self, from: data)
        } catch let error as DecodingError {
            return "The candidate was refused: \(reason(for: error))"
        } catch {
            // Everything that is not a `DecodingError` is `validate` refusing
            // the candidate, and it throws one bare `invalidCandidate` for
            // around thirty different rules — so the error itself says nothing.
            // Dropping one key at a time finds the field the rules objected to:
            // a couple of dozen cheap decodes, on a path that has already
            // failed, in exchange for naming the field instead of the file.
            guard let found = offendingKey(in: sent) else {
                return "The candidate was refused: \(reason(for: error))"
            }
            decoded = found.candidate
            culprit = found.key
        }
        guard let canonical = try? ToolAgentCanonicalJSONV1.encode(decoded),
              let expected = try? JSONSerialization.jsonObject(with: canonical),
              let wanted = expected as? [String: Any] else {
            return "The candidate could not be read back."
        }
        // Two branches because the answer is genuinely sharper in one of them.
        // A key that survives into the re-encoding is one this kind takes, so
        // the value is what was wrong. A key that does not could be either an
        // alien key or an optional one carrying a bad value, and claiming to
        // know which would send the model after the wrong fix.
        if let culprit {
            let kind = decoded.kind.rawValue
            return wanted.keys.contains(culprit)
                ? "\"\(culprit)\" is what the candidate was refused for. A \(kind) "
                    + "candidate takes it, but not with that value: check its "
                    + "length, its count, and that it is not empty."
                : "\"\(culprit)\" is what the candidate was refused for. Either a "
                    + "\(kind) candidate does not take it at all, or its value "
                    + "breaks a rule about length, count, or emptiness."
        }
        let missing = Set(wanted.keys).subtracting(sent.keys).sorted()
        let extra = Set(sent.keys).subtracting(wanted.keys).sorted()
        guard missing.isEmpty, extra.isEmpty else {
            var parts: [String] = []
            if !missing.isEmpty {
                parts.append("it is missing \(list(missing))")
            }
            if !extra.isEmpty {
                parts.append(
                    "it carries \(list(extra)), which a \(decoded.kind.rawValue) "
                        + "candidate does not have"
                )
            }
            return "A candidate carries exactly the keys of its own kind, and "
                + parts.joined(separator: ", and ")
                + ". A key that does not apply is left out rather than sent as null."
        }
        return "The candidate has the right keys, but one of its values did not "
            + "survive being read back. Write whole numbers with no decimal point, "
            + "and send no nulls."
    }

    /// The one field whose value the rules objected to, found by neutralising
    /// one key at a time until the candidate decodes.
    ///
    /// Two probes per key, and both are needed. Replacing the value with a
    /// harmless one of the same type finds a field that is required but wrong
    /// (`brief` too long, `name` empty) — dropping those would only produce a
    /// missing-key error and prove nothing. Dropping the key finds a field that
    /// should not have been sent at all (`prompt` on a Python candidate) or
    /// whose emptiness is itself the problem (`options: []`), which no
    /// substitute value can rescue.
    ///
    /// Keys are tried in sorted order so the answer does not depend on
    /// dictionary layout, and the first one that works is reported: a candidate
    /// with two broken fields gets told about one of them, then the other.
    private static func offendingKey(
        in sent: [String: Any]
    ) -> (candidate: ToolAgentCandidateV1, key: String)? {
        for key in sent.keys.sorted() {
            for probe in probes(replacing: sent[key]) {
                var altered = sent
                if let probe {
                    altered[key] = probe
                } else {
                    altered.removeValue(forKey: key)
                }
                guard let data = try? JSONSerialization.data(withJSONObject: altered),
                      let candidate = try? JSONDecoder().decode(
                          ToolAgentCandidateV1.self, from: data
                      ) else {
                    continue
                }
                return (candidate, key)
            }
        }
        return nil
    }

    /// What to try in a key's place, in order. `nil` means remove the key.
    private static func probes(replacing value: Any?) -> [Any?] {
        switch value {
        case is String: return ["x", nil]
        case is Bool: return [false, nil]
        case is NSNumber: return [30, nil]
        case is [Any]: return [[], nil]
        default: return [nil]
        }
    }

    private static func reason(for error: Error) -> String {
        guard let decoding = error as? DecodingError else {
            // `ToolAgentCandidateV1.init(from:)` runs the structural rules and
            // throws a bare `invalidCandidate` for all of them, so this is as
            // specific as the schema can currently be.
            return "it broke one of the rules for its kind, such as a field that "
                + "must be empty for this kind, a name or brief that is empty, or a "
                + "limit on length or count."
        }
        switch decoding {
        case .keyNotFound(let key, _):
            return "\"\(key.stringValue)\" is missing."
        case .typeMismatch(_, let context):
            return "\"\(path(context))\" has the wrong type."
        case .valueNotFound(_, let context):
            return "\"\(path(context))\" is null but needs a value."
        case .dataCorrupted(let context):
            let where_ = path(context)
            return where_.isEmpty
                ? context.debugDescription
                : "\"\(where_)\": \(context.debugDescription)"
        @unknown default:
            return "it could not be read."
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        context.codingPath.map(\.stringValue).joined(separator: ".")
    }

    private static func list(_ keys: [String]) -> String {
        keys.map { "\"\($0)\"" }.joined(separator: ", ")
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
