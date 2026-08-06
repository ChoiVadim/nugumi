import CoreGraphics
import Foundation

enum AskGizmateEmotion: String, Codable, Equatable {
    case neutral
    case happy
    case surprised
    case confused
    case concerned
}

enum AskGizmateAnnotationType: String, Codable, Equatable {
    case ellipse
    case rect
    case arrow
    case label
}

/// One model-drawn shape over the screenshot, in normalized 0.0–1.0
/// screenshot coordinates (x left-to-right, y top-to-bottom). Flat
/// optional fields instead of a polymorphic decoder; `isValid` enforces
/// the per-type contract.
struct AskGizmateAnnotation: Codable, Equatable {
    let type: AskGizmateAnnotationType
    // ellipse/rect: center + normalized size
    let cx: Double?
    let cy: Double?
    let w: Double?
    let h: Double?
    // arrow
    let fromX: Double?
    let fromY: Double?
    let toX: Double?
    let toY: Double?
    // label
    let x: Double?
    let y: Double?
    let text: String?
    /// What to draw this shape in, as one of `AskAnnotationPalette`'s names.
    /// `nil` is the palette's default.
    ///
    /// A loose `String` rather than an enum on purpose: an unknown name has to
    /// cost the shape its colour, not its existence. As an enum, `"cyan"` from a
    /// model that never read the list would fail the whole shape's decode and
    /// `FailableDecodable` would drop it — the user would lose the circle, not
    /// just the tint. `isValid` deliberately ignores it for the same reason.
    let color: String?

    var isValid: Bool {
        switch type {
        case .ellipse, .rect:
            guard let cx, let cy, let w, let h else { return false }
            return [cx, cy, w, h].allSatisfy(\.isFinite)
                && (0...1).contains(cx) && (0...1).contains(cy)
                && w > 0 && w <= 1 && h > 0 && h <= 1
        case .arrow:
            guard let fromX, let fromY, let toX, let toY else { return false }
            let inRange = [fromX, fromY, toX, toY].allSatisfy { $0.isFinite && (0...1).contains($0) }
            // A zero-length arrow has no direction; atan2(0,0) would render a
            // meaningless right-pointing stub. ~0.001 normalized ≈ a few px.
            return inRange && hypot(toX - fromX, toY - fromY) > 0.001
        case .label:
            guard let x, let y, let text else { return false }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return x.isFinite && y.isFinite
                && (0...1).contains(x) && (0...1).contains(y)
                && !trimmed.isEmpty && trimmed.count <= 60
        }
    }
}

/// Wrapper that turns a per-element decode failure into `nil` instead of
/// failing the whole array — weak local models emit partially-broken shapes.
private struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) {
        value = try? T(from: decoder)
    }
}

struct AskGizmateResponse: Codable, Equatable {
    let message: String
    let annotations: [AskGizmateAnnotation]

    static func parse(_ raw: String) -> AskGizmateResponse {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Preferred protocol: a markdown answer with one trailing fenced
        // annotations block. Human text and machine block never share an
        // encoding, so neither can corrupt the other.
        if let split = splitAnnotationsFence(from: trimmed) {
            return AskGizmateResponse(message: split.message, annotations: split.annotations)
        }

        // Legacy fallbacks: a whole-string or embedded {"message": ...}
        // object, for models that still answer in the retired JSON shape.
        if let decoded = parseJSONResponse(from: trimmed) {
            return decoded
        }

        if let jsonObject = firstBalancedJSONObject(in: trimmed),
           let decoded = parseJSONResponse(from: jsonObject) {
            return decoded
        }

        return AskGizmateResponse(message: trimmed)
    }

    /// The visible part of a half-arrived answer.
    ///
    /// `parse` finds the machine block by its *closing* fence, and a stream
    /// reaches the opening one first. Without this the raw ```annotations JSON
    /// types itself across the chat for a second before the final parse takes
    /// it away. Matching the whole opening fence rather than any ``` is what
    /// keeps an ordinary code fence in the answer from truncating it.
    static func streamingMessage(_ raw: String) -> String {
        guard let fence = raw.range(of: "```annotations") else { return raw }
        return String(raw[..<fence.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Detects the trailing machine block. A fenced block qualifies when its
    /// info string is `annotations`, or when its payload actually decodes to
    /// shapes (models sometimes label the block ```json — or wrap the array
    /// in an {"annotations": ...} object). An `annotations`-labeled block is
    /// stripped from the visible message even when its JSON is broken: the
    /// machine block must never be shown to the user. Ordinary user-facing
    /// code fences don't qualify and stay in the message untouched.
    private static func splitAnnotationsFence(
        from text: String
    ) -> (message: String, annotations: [AskGizmateAnnotation])? {
        let pattern = "```([A-Za-z]*)[ \\t]*\\n([\\s\\S]*?)\\n?```"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let match = matches.last else { return nil }

        let info = ns.substring(with: match.range(at: 1)).lowercased()
        let payload = ns.substring(with: match.range(at: 2))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = decodeAnnotationsPayload(payload)

        guard info == "annotations" || decoded?.isEmpty == false else {
            return nil
        }

        let message = ns.replacingCharacters(in: match.range, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (message, decoded ?? [])
    }

    /// Lenient decode of the fence payload: a bare shape array, or an object
    /// wrapping one under an "annotations" key (stray keys ignored). Returns
    /// nil when the payload isn't annotations-shaped at all, so unrelated
    /// JSON in a user-facing code example never gets swallowed.
    private static func decodeAnnotationsPayload(_ payload: String) -> [AskGizmateAnnotation]? {
        guard let data = payload.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()

        let items: [FailableDecodable<AskGizmateAnnotation>]?
        if let array = try? decoder.decode([FailableDecodable<AskGizmateAnnotation>].self, from: data) {
            items = array
        } else if let wrapper = try? decoder.decode(AnnotationsWrapper.self, from: data) {
            items = wrapper.annotations
        } else {
            items = nil
        }

        guard let items else { return nil }
        let valid = items.compactMap(\.value).filter(\.isValid)
        return valid.isEmpty ? nil : valid
    }

    private struct AnnotationsWrapper: Decodable {
        let annotations: [FailableDecodable<AskGizmateAnnotation>]?
    }

    private static func parseJSONResponse(from json: String) -> AskGizmateResponse? {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AskGizmateResponse.self, from: data)
        else {
            return nil
        }

        guard !decoded.message.isEmpty else {
            return AskGizmateResponse(message: "")
        }

        return decoded
    }

    private static func firstBalancedJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else {
            return nil
        }

        var depth = 0
        var isInsideString = false
        var isEscaped = false
        var index = start

        while index < text.endIndex {
            let character = text[index]

            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else {
                if character == "\"" {
                    isInsideString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1

                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }

            index = text.index(after: index)
        }

        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case message
        case annotations
    }

    static let maxAnnotations = 12

    init(
        message: String,
        annotations: [AskGizmateAnnotation] = []
    ) {
        self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.annotations = Array(annotations.filter(\.isValid).prefix(Self.maxAnnotations))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let message = try container.decode(String.self, forKey: .message)
        let annotations = (try? container.decode(
            [FailableDecodable<AskGizmateAnnotation>].self,
            forKey: .annotations
        ))?.compactMap(\.value) ?? []

        self.init(message: message, annotations: annotations)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(message, forKey: .message)
        if !annotations.isEmpty {
            try container.encode(annotations, forKey: .annotations)
        }
    }
}
