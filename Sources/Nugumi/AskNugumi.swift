import CoreGraphics
import Foundation

enum AskNugumiEmotion: String, Codable, Equatable {
    case neutral
    case happy
    case surprised
    case confused
    case concerned
}

enum AskNugumiAnnotationType: String, Codable, Equatable {
    case ellipse
    case rect
    case arrow
    case label
}

/// One model-drawn shape over the screenshot, in normalized 0.0–1.0
/// screenshot coordinates (x left-to-right, y top-to-bottom). Flat
/// optional fields instead of a polymorphic decoder; `isValid` enforces
/// the per-type contract.
struct AskNugumiAnnotation: Codable, Equatable {
    let type: AskNugumiAnnotationType
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

struct AskNugumiResponse: Codable, Equatable {
    let message: String
    let annotations: [AskNugumiAnnotation]

    static func parse(_ raw: String) -> AskNugumiResponse {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Preferred protocol: a markdown answer with one trailing fenced
        // annotations block. Human text and machine block never share an
        // encoding, so neither can corrupt the other.
        if let split = splitAnnotationsFence(from: trimmed) {
            return AskNugumiResponse(message: split.message, annotations: split.annotations)
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

        return AskNugumiResponse(message: trimmed)
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
    ) -> (message: String, annotations: [AskNugumiAnnotation])? {
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
    private static func decodeAnnotationsPayload(_ payload: String) -> [AskNugumiAnnotation]? {
        guard let data = payload.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()

        let items: [FailableDecodable<AskNugumiAnnotation>]?
        if let array = try? decoder.decode([FailableDecodable<AskNugumiAnnotation>].self, from: data) {
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
        let annotations: [FailableDecodable<AskNugumiAnnotation>]?
    }

    private static func parseJSONResponse(from json: String) -> AskNugumiResponse? {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AskNugumiResponse.self, from: data)
        else {
            return nil
        }

        guard !decoded.message.isEmpty else {
            return AskNugumiResponse(message: "")
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
        annotations: [AskNugumiAnnotation] = []
    ) {
        self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.annotations = Array(annotations.filter(\.isValid).prefix(Self.maxAnnotations))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let message = try container.decode(String.self, forKey: .message)
        let annotations = (try? container.decode(
            [FailableDecodable<AskNugumiAnnotation>].self,
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

struct AskNugumiTurn: Codable, Equatable {
    let question: String
    let answer: String
}

/// Persists the Ask Nugumi dialog across app launches so follow-up questions
/// keep their context after a restart. The saved-at clock resets on every save,
/// so an actively used conversation never expires; after `maxAge` without a new
/// ask, the next launch starts fresh.
enum AskNugumiHistoryStore {
    static let maxAge: TimeInterval = 24 * 60 * 60
    private static let turnsKey = "askNugumiHistory"
    private static let savedAtKey = "askNugumiHistorySavedAt"

    static func load(defaults: UserDefaults = .standard, now: Date = Date()) -> [AskNugumiTurn] {
        let savedAt = defaults.double(forKey: savedAtKey)
        guard savedAt > 0,
              now.timeIntervalSince1970 - savedAt < maxAge,
              let data = defaults.data(forKey: turnsKey),
              let turns = try? JSONDecoder().decode([AskNugumiTurn].self, from: data)
        else {
            return []
        }
        return turns
    }

    static func save(_ turns: [AskNugumiTurn], defaults: UserDefaults = .standard, now: Date = Date()) {
        guard let data = try? JSONEncoder().encode(turns) else { return }
        defaults.set(data, forKey: turnsKey)
        defaults.set(now.timeIntervalSince1970, forKey: savedAtKey)
    }
}

enum AskNugumiPromptBuilder {
    static let maxHistoryTurns = 20

    static func appending(_ turn: AskNugumiTurn, to history: [AskNugumiTurn]) -> [AskNugumiTurn] {
        let updated = history + [turn]
        guard updated.count > maxHistoryTurns else { return updated }
        return Array(updated.suffix(maxHistoryTurns))
    }

    private static let systemPromptBase = """
You are Nugumi, a concise and helpful desktop assistant. Answer the user's question directly and usefully.

When the user attaches a screenshot, you can see what is currently on their screen and answer about it. When no screenshot is attached, answer from general knowledge.

Write the answer as plain text, not JSON. Markdown is welcome when structure genuinely helps: "-" bullets or numbered lists for steps, **bold** for the key term or the direct answer, a small table for comparisons. Keep it concise and scannable — plain prose for one-sentence answers, never headings.

When a screenshot is attached AND drawing on top of it explains better than words alone, append exactly one fenced block at the very end of the answer, after a blank line:

```annotations
[{"type":"ellipse","cx":0.42,"cy":0.31,"w":0.10,"h":0.05},
 {"type":"rect","cx":0.60,"cy":0.20,"w":0.20,"h":0.10},
 {"type":"arrow","fromX":0.42,"fromY":0.45,"toX":0.55,"toY":0.32},
 {"type":"label","x":0.42,"y":0.50,"text":"click here"}]
```

Annotation rules:
- The block contains ONLY a JSON array — double quotes, no comments, nothing after the closing fence. It is machine-read and never shown to the user; the answer text must stand on its own without it.
- Coordinates are normalized 0.0–1.0 over the screenshot: x left-to-right, y top-to-bottom.
- "ellipse" and "rect" take the CENTER ("cx", "cy") plus width/height fractions ("w", "h"). "arrow" goes from ("fromX", "fromY") to ("toX", "toY"). "label" anchors its "text" (five words or fewer) at ("x", "y").
- A few precise shapes beat many: circle one element, draw one arrow per direction or relationship, box one region. Never more than 12 shapes.
- If uncertain about a location, skip the shape and describe it in words instead.
- Your previous annotations are erased with every new answer. To keep pointing at something across a follow-up, include its shapes again.
- Never add the block when no screenshot is attached.

Do not click, automate, or claim you took an action.
"""

    /// Base prompt, plus the Gen Z styling suffix when the global toggle is on,
    /// plus the user's "About you" background when present.
    static func systemPrompt(genZ: Bool, aboutUser: String? = nil) -> String {
        let base = genZ ? systemPromptBase + "\n\n" + genZSuffix : systemPromptBase
        return UserAboutContext.appending(to: base, about: aboutUser)
    }

    /// Gen Z overlay for Ask answers. Ask replies in the question's own language
    /// (unknown at prompt-build time), so this stays language-agnostic and leans
    /// on the model's multilingual slang — and must not break the answer format.
    private static let genZSuffix = """
Gen Z mode is ON. Write the answer text the way a Gen Z native (born ~1997–2012) would actually text it — casual, all-lowercase, ironic and a little deadpan, using the native youth slang of whatever language you are answering in (never switch languages to do it). Keep it short. The #1 rule is restraint: at most 1–2 slang markers — piling it on is the dead giveaway of an adult faking it; when unsure, drop the slang. Write laughter as 💀 or 😭, never 😂. This restyles ONLY the answer wording — keep the annotations block format and its rules above exactly as specified.
"""

    static func prompt(question: String, hasImage: Bool) -> String {
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)

        guard hasImage else {
            return cleanQuestion
        }

        return """
User question:
\(cleanQuestion)

Coordinate guide for annotations:
- All coordinates (`cx`/`cy`, `fromX`/`fromY`/`toX`/`toY`, `x`/`y`) are normalized from 0.0 to 1.0 over the attached screenshot. x is the horizontal fraction from the left edge; y is the vertical fraction from the top edge.
- Aim shapes at the geometric center of the target element's visible bounding box (button, icon, control, or input). Never anchor to the top-left of a text label — in a vertical list of buttons or menu items, a label's top-left sits inside the previous row.
- For small menu bar or status icons, aim at the icon glyph's visual center, not the surrounding hit area.
- Before choosing coordinates, identify the target's row/column context in `message` (for example: "the third item in the left sidebar, below New chat and above Artifacts") so you anchor to the correct sibling among visually similar elements.
"""
    }
}

struct AskNugumiAnswerBubbleLayout: Equatable {
    let panelSize: CGSize
    let bubbleFrame: CGRect
    let viewportFrame: CGRect
    let documentHeight: CGFloat
    let needsScroll: Bool
}

struct AskNugumiPromptInputLayout: Equatable {
    let panelSize: CGSize
    let bubbleFrame: CGRect
    let textFrame: CGRect
}

struct AskNugumiFloatingPromptLayout: Equatable {
    let panelSize: CGSize
    let pillFrame: CGRect
    let textFrame: CGRect
    let cornerRadius: CGFloat
}

struct AskNugumiPetBubblePresentation: Equatable {
    let promptFrame: CGRect
    let petOrigin: CGPoint
}

enum AskNugumiFloatingPromptMetrics {
    static let pillSize = CGSize(width: 260, height: 46)
    /// Ceiling for multi-line growth (~4 lines). Past it the field clips,
    /// same trade-off as the pet prompt's maximumPanelHeight.
    static let maximumPillHeight: CGFloat = 130
    static let shadowMargin: CGFloat = 14
    static let edgeMargin: CGFloat = 12
    static let textHorizontalInset: CGFloat = 22
    static let textFieldHeight: CGFloat = 24
    static let cornerRadius: CGFloat = pillSize.height / 2

    static var layout: AskNugumiFloatingPromptLayout {
        layout(forContentHeight: 0)
    }

    /// Shift+Enter makes the input multi-line; the pill grows to fit while
    /// keeping the single-line capsule's padding above and below the text.
    static func layout(forContentHeight contentHeight: CGFloat) -> AskNugumiFloatingPromptLayout {
        let verticalPadding = pillSize.height - textFieldHeight
        let sanitizedContentHeight = contentHeight.isFinite
            ? max(1, ceil(contentHeight))
            : textFieldHeight
        let textHeight = min(
            max(textFieldHeight, sanitizedContentHeight),
            maximumPillHeight - verticalPadding
        )
        let pillHeight = textHeight + verticalPadding

        let panelSize = CGSize(
            width: pillSize.width + shadowMargin * 2,
            height: pillHeight + shadowMargin * 2
        )
        let pillFrame = CGRect(
            x: shadowMargin,
            y: shadowMargin,
            width: pillSize.width,
            height: pillHeight
        )
        let textFrame = CGRect(
            x: pillFrame.minX + textHorizontalInset,
            y: pillFrame.minY + verticalPadding / 2,
            width: pillFrame.width - textHorizontalInset * 2,
            height: textHeight
        )

        return AskNugumiFloatingPromptLayout(
            panelSize: panelSize,
            pillFrame: pillFrame,
            textFrame: textFrame,
            cornerRadius: cornerRadius
        )
    }
}

enum AskNugumiFloatingTargetPresentationPolicy {
    static let buttonSize: CGFloat = 30
    static let shadowPadding: CGFloat = 15
    static let totalSize: CGFloat = buttonSize + shadowPadding * 2
}

enum AskNugumiPromptInputMetrics {
    static let panelWidth: CGFloat = 182
    static let minimumPanelHeight: CGFloat = 98
    static let maximumPanelHeight: CGFloat = 210
    static let fontSize: CGFloat = 13
    static let textMeasurementWidth: CGFloat = 104
    static let textMeasurementBottomInset: CGFloat = 6

    private static let bubbleX: CGFloat = 0
    private static let bubbleY: CGFloat = 34
    private static let bubbleWidth: CGFloat = 176
    private static let textX: CGFloat = 30
    private static let textY: CGFloat = 52
    private static let textWidth: CGFloat = 116
    private static let minimumTextHeight: CGFloat = 22
    private static let topTextInset: CGFloat = 30
    private static let bubbleBottomInset: CGFloat = 38

    static func layout(forContentHeight contentHeight: CGFloat) -> AskNugumiPromptInputLayout {
        let sanitizedContentHeight = contentHeight.isFinite
            ? max(1, ceil(contentHeight))
            : minimumTextHeight
        let maximumTextHeight = maximumPanelHeight - textY - topTextInset
        let textHeight = min(
            max(minimumTextHeight, sanitizedContentHeight),
            maximumTextHeight
        )
        let panelHeight = textHeight + textY + topTextInset
        let bubbleHeight = panelHeight - bubbleBottomInset

        return AskNugumiPromptInputLayout(
            panelSize: CGSize(width: panelWidth, height: panelHeight),
            bubbleFrame: CGRect(x: bubbleX, y: bubbleY, width: bubbleWidth, height: bubbleHeight),
            textFrame: CGRect(x: textX, y: textY, width: textWidth, height: textHeight)
        )
    }
}

enum AskNugumiAnswerBubbleMetrics {
    static let panelWidth: CGFloat = 300
    static let minimumPanelHeight: CGFloat = 136
    static let maximumPanelHeight: CGFloat = 254

    private static let bubbleX: CGFloat = 0
    private static let bubbleY: CGFloat = 34
    private static let bubbleWidth: CGFloat = 294
    private static let textX: CGFloat = 30
    // textY clears the bottom-right continue button (~bubble.minY+9+8+16).
    // The scroller lane is applied at the text-container level only while a
    // scrollbar is present (see configureAnswerTextView), so the bubble keeps
    // full-width symmetric text the rest of the time.
    private static let textY: CGFloat = 70
    private static let textWidth: CGFloat = 234
    private static let minimumViewportHeight: CGFloat = 54
    private static let topTextInset: CGFloat = 26
    private static let bubbleBottomInset: CGFloat = 38

    static func layout(forContentHeight contentHeight: CGFloat) -> AskNugumiAnswerBubbleLayout {
        let sanitizedContentHeight = contentHeight.isFinite
            ? max(1, ceil(contentHeight))
            : minimumViewportHeight
        let maximumViewportHeight = maximumPanelHeight - textY - topTextInset
        let viewportHeight = min(
            max(minimumViewportHeight, sanitizedContentHeight),
            maximumViewportHeight
        )
        let panelHeight = viewportHeight + textY + topTextInset
        let bubbleHeight = panelHeight - bubbleBottomInset

        return AskNugumiAnswerBubbleLayout(
            panelSize: CGSize(width: panelWidth, height: panelHeight),
            bubbleFrame: CGRect(x: bubbleX, y: bubbleY, width: bubbleWidth, height: bubbleHeight),
            viewportFrame: CGRect(x: textX, y: textY, width: textWidth, height: viewportHeight),
            documentHeight: max(sanitizedContentHeight, viewportHeight),
            needsScroll: sanitizedContentHeight > maximumViewportHeight
        )
    }
}

enum AskNugumiPetDismissalPolicy {
    static let hitTolerance: CGFloat = 4

    static func shouldDismissPrompt(clickPoint: CGPoint, petFrame: CGRect) -> Bool {
        petFrame.insetBy(dx: -hitTolerance, dy: -hitTolerance).contains(clickPoint)
    }
}

enum PetSelectionStatusPolicy {
    static func shouldPreserveCurrentStatus(isThinking: Bool, isPromptVisible: Bool) -> Bool {
        isThinking || isPromptVisible
    }
}

enum AskNugumiPetBubblePresentationMetrics {
    static let bubbleToPetPanelGap: CGFloat = -6

    static func presentation(
        petOrigin: CGPoint,
        petSize: CGSize,
        promptSize: CGSize,
        bubbleFrame: CGRect,
        visibleFrame: CGRect,
        edgeMargin: CGFloat
    ) -> AskNugumiPetBubblePresentation {
        let desiredPromptOrigin = CGPoint(
            x: petOrigin.x,
            y: petOrigin.y + petSize.height - bubbleFrame.minY + bubbleToPetPanelGap
        )
        let promptOrigin = clampedOrigin(
            desiredPromptOrigin,
            size: promptSize,
            visibleFrame: visibleFrame,
            edgeMargin: edgeMargin
        )
        var adjustedPetOrigin = petOrigin

        let bubbleOriginY = promptOrigin.y + bubbleFrame.minY
        let targetPetMaxY = bubbleOriginY - bubbleToPetPanelGap
        if petOrigin.y + petSize.height > targetPetMaxY {
            adjustedPetOrigin.y = targetPetMaxY - petSize.height
        }
        adjustedPetOrigin = clampedOrigin(
            adjustedPetOrigin,
            size: petSize,
            visibleFrame: visibleFrame,
            edgeMargin: edgeMargin
        )

        return AskNugumiPetBubblePresentation(
            promptFrame: CGRect(origin: promptOrigin, size: promptSize),
            petOrigin: adjustedPetOrigin
        )
    }

    private static func clampedOrigin(
        _ origin: CGPoint,
        size: CGSize,
        visibleFrame: CGRect,
        edgeMargin: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: min(
                max(origin.x, visibleFrame.minX + edgeMargin),
                visibleFrame.maxX - size.width - edgeMargin
            ),
            y: min(
                max(origin.y, visibleFrame.minY + edgeMargin),
                visibleFrame.maxY - size.height - edgeMargin
            )
        )
    }
}

enum AskNugumiCoordinateMapper {
    /// Normalized screenshot coordinates (x left-to-right, y top-to-bottom)
    /// to AppKit screen points (y bottom-up), clamped into the frame.
    static func exactScreenPoint(
        normalizedX: Double,
        normalizedY: Double,
        screenFrame: CGRect
    ) -> CGPoint {
        let mappedX = screenFrame.minX + CGFloat(normalizedX) * screenFrame.width
        let mappedY = screenFrame.maxY - CGFloat(normalizedY) * screenFrame.height

        return CGPoint(
            x: min(max(mappedX, screenFrame.minX), screenFrame.maxX),
            y: min(max(mappedY, screenFrame.minY), screenFrame.maxY)
        )
    }

    /// Center-based normalized rect (as emitted in `annotations`) to an
    /// AppKit screen rect. The center is clamped into the frame; the size
    /// is a direct fraction of the frame.
    static func screenRect(
        centerX: Double,
        centerY: Double,
        normalizedWidth: Double,
        normalizedHeight: Double,
        screenFrame: CGRect
    ) -> CGRect {
        let center = exactScreenPoint(
            normalizedX: centerX,
            normalizedY: centerY,
            screenFrame: screenFrame
        )
        let size = CGSize(
            width: CGFloat(normalizedWidth) * screenFrame.width,
            height: CGFloat(normalizedHeight) * screenFrame.height
        )
        return CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
