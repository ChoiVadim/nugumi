import CoreGraphics
import Foundation

enum AskNugumiCoordinateSpace: String, Codable, Equatable {
    case screenshotNormalized = "screenshot_normalized"
}

struct AskNugumiPetTarget: Codable, Equatable {
    let x: Double
    let y: Double
    let coordinateSpace: AskNugumiCoordinateSpace

    var isValid: Bool {
        x.isFinite
            && y.isFinite
            && (0...1).contains(x)
            && (0...1).contains(y)
            && coordinateSpace == .screenshotNormalized
    }
}

enum AskNugumiEmotion: String, Codable, Equatable {
    case neutral
    case happy
    case surprised
    case confused
    case concerned
}

struct AskNugumiResponse: Codable, Equatable {
    let message: String
    let petTarget: AskNugumiPetTarget?
    let emotion: AskNugumiEmotion?

    static func parse(_ raw: String) -> AskNugumiResponse {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let decoded = parseJSONResponse(from: trimmed) {
            return decoded
        }

        if let jsonObject = firstBalancedJSONObject(in: trimmed),
           let decoded = parseJSONResponse(from: jsonObject) {
            return decoded
        }

        return AskNugumiResponse(message: trimmed, petTarget: nil, emotion: nil)
    }

    private static func parseJSONResponse(from json: String) -> AskNugumiResponse? {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AskNugumiResponse.self, from: data)
        else {
            return nil
        }

        guard !decoded.message.isEmpty else {
            return AskNugumiResponse(message: "", petTarget: nil, emotion: nil)
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
        case petTarget
        case emotion
    }

    init(message: String, petTarget: AskNugumiPetTarget?, emotion: AskNugumiEmotion?) {
        self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.petTarget = petTarget?.isValid == true ? petTarget : nil
        self.emotion = emotion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let message = try container.decode(String.self, forKey: .message)
        let petTarget = try? container.decode(AskNugumiPetTarget.self, forKey: .petTarget)
        let emotion = try? container.decode(AskNugumiEmotion.self, forKey: .emotion)

        self.init(message: message, petTarget: petTarget, emotion: emotion)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(petTarget, forKey: .petTarget)
        try container.encodeIfPresent(emotion, forKey: .emotion)
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

Return only JSON. Use this default shape:
{"message":"short helpful answer","emotion":"neutral"}

When a screenshot is attached AND pointing at a specific visible element helps the user, use this shape:
{"message":"short helpful answer","emotion":"neutral","petTarget":{"x":0.0,"y":0.0,"coordinateSpace":"screenshot_normalized"}}

Rules:
- `message` is required and must be useful on its own.
- `emotion` is optional. Use one of: "neutral", "happy", "surprised", "confused", "concerned".
- Include `petTarget` only when a screenshot is attached AND the user benefits from the pet pointing at a specific visible location. Never include `petTarget` without a screenshot.
- When a screenshot is attached, the user message includes a coordinate guide; follow it when computing `petTarget`.
- `petTarget.x` and `petTarget.y` are normalized 0.0–1.0 across the screenshot (x left-to-right, y top-to-bottom).
- Aim at the geometric center of the target element, never the top-left of a text label.
- Use coordinateSpace exactly "screenshot_normalized".
- Do not click, automate, or claim you took an action.
- If uncertain about a location, omit `petTarget` and describe what to look for in `message`.
"""

    /// Base prompt, plus the Gen Z styling suffix when the global toggle is on.
    static func systemPrompt(genZ: Bool) -> String {
        guard genZ else { return systemPromptBase }
        return systemPromptBase + "\n\n" + genZSuffix
    }

    /// Gen Z overlay for Ask answers. Ask replies in the question's own language
    /// (unknown at prompt-build time), so this stays language-agnostic and leans
    /// on the model's multilingual slang — and must not break the JSON shape.
    private static let genZSuffix = """
Gen Z mode is ON. Write the `message` field the way a Gen Z native (born ~1997–2012) would actually text it — casual, all-lowercase, ironic and a little deadpan, using the native youth slang of whatever language you are answering in (never switch languages to do it). Keep it short. The #1 rule is restraint: at most 1–2 slang markers — piling it on is the dead giveaway of an adult faking it; when unsure, drop the slang. Write laughter as 💀 or 😭, never 😂. This restyles ONLY the wording inside `message` — keep the JSON shape, field names, and the emotion/petTarget rules above exactly as specified.
"""

    static func prompt(question: String, hasImage: Bool) -> String {
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)

        guard hasImage else {
            return cleanQuestion
        }

        return """
User question:
\(cleanQuestion)

Coordinate guide for petTarget:
- x and y are normalized from 0.0 to 1.0 over the attached screenshot. x is the horizontal fraction from the left edge; y is the vertical fraction from the top edge.
- Aim at the geometric center of the target element's visible bounding box (button, icon, control, or input). Never anchor to the top-left of a text label — in a vertical list of buttons or menu items, a label's top-left sits inside the previous row.
- For small menu bar or status icons, use the icon glyph's visual center, not the surrounding hit area.
- Before returning coordinates, identify the target's row/column context in `message` (for example: "the third item in the left sidebar, below New chat and above Artifacts") so you anchor to the correct sibling among visually similar elements.
- Use coordinateSpace exactly "screenshot_normalized".
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

struct AskNugumiFloatingTargetPresentation: Equatable {
    let panelFrame: CGRect
    let arrowAngleRadians: CGFloat
}

struct AskNugumiPetBubblePresentation: Equatable {
    let promptFrame: CGRect
    let petOrigin: CGPoint
}

enum AskNugumiFloatingPromptMetrics {
    static let pillSize = CGSize(width: 260, height: 46)
    static let shadowMargin: CGFloat = 14
    static let edgeMargin: CGFloat = 12
    static let textHorizontalInset: CGFloat = 22
    static let textFieldHeight: CGFloat = 24
    static let cornerRadius: CGFloat = pillSize.height / 2

    static var layout: AskNugumiFloatingPromptLayout {
        let panelSize = CGSize(
            width: pillSize.width + shadowMargin * 2,
            height: pillSize.height + shadowMargin * 2
        )
        let pillFrame = CGRect(
            x: shadowMargin,
            y: shadowMargin,
            width: pillSize.width,
            height: pillSize.height
        )
        let textFrame = CGRect(
            x: pillFrame.minX + textHorizontalInset,
            y: pillFrame.minY + (pillFrame.height - textFieldHeight) / 2,
            width: pillFrame.width - textHorizontalInset * 2,
            height: textFieldHeight
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
    static let pointerOffset = CGPoint(x: 20, y: -20)

    static func presentation(
        targetPoint: CGPoint,
        visibleFrame: CGRect
    ) -> AskNugumiFloatingTargetPresentation {
        let desiredCenter = CGPoint(
            x: targetPoint.x + pointerOffset.x,
            y: targetPoint.y + pointerOffset.y
        )
        let desiredOrigin = CGPoint(
            x: desiredCenter.x - totalSize / 2,
            y: desiredCenter.y - totalSize / 2
        )
        let origin = clampedOrigin(
            desiredOrigin,
            size: CGSize(width: totalSize, height: totalSize),
            visibleFrame: visibleFrame,
            edgeMargin: 0
        )
        let center = CGPoint(
            x: origin.x + totalSize / 2,
            y: origin.y + totalSize / 2
        )
        let dx = targetPoint.x - center.x
        let dy = targetPoint.y - center.y
        let angle = hypot(dx, dy) > 0.001 ? atan2(dy, dx) : CGFloat.pi / 2

        return AskNugumiFloatingTargetPresentation(
            panelFrame: CGRect(
                x: origin.x,
                y: origin.y,
                width: totalSize,
                height: totalSize
            ),
            arrowAngleRadians: angle
        )
    }

    private static func clampedOrigin(
        _ origin: CGPoint,
        size: CGSize,
        visibleFrame: CGRect,
        edgeMargin: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: clamped(
                origin.x,
                min: visibleFrame.minX + edgeMargin,
                max: visibleFrame.maxX - size.width - edgeMargin
            ),
            y: clamped(
                origin.y,
                min: visibleFrame.minY + edgeMargin,
                max: visibleFrame.maxY - size.height - edgeMargin
            )
        )
    }

    private static func clamped(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        guard minValue <= maxValue else {
            return (minValue + maxValue) / 2
        }
        return Swift.min(Swift.max(value, minValue), maxValue)
    }
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

enum AskNugumiTargetMarkerMetrics {
    static let size: CGFloat = 15
    static let padding: CGFloat = 6

    static func frame(centeredAt point: CGPoint) -> CGRect {
        CGRect(
            x: point.x - size / 2,
            y: point.y - size / 2,
            width: size,
            height: size
        )
    }

    static func paddedFrame(centeredAt point: CGPoint) -> CGRect {
        frame(centeredAt: point).insetBy(dx: -padding, dy: -padding)
    }
}

struct AskNugumiPetAnswerTargetPanelPresentation: Equatable {
    let bubblePanelFrame: CGRect
    let markerPanelFrame: CGRect?
    let localMarkerTarget: CGPoint?
}

enum AskNugumiPetAnswerTargetPanelMetrics {
    static func presentation(
        bubblePanelFrame: CGRect,
        markerTarget: CGPoint?
    ) -> AskNugumiPetAnswerTargetPanelPresentation {
        guard let markerTarget else {
            return AskNugumiPetAnswerTargetPanelPresentation(
                bubblePanelFrame: bubblePanelFrame,
                markerPanelFrame: nil,
                localMarkerTarget: nil
            )
        }

        let markerPanelFrame = AskNugumiTargetMarkerMetrics
            .paddedFrame(centeredAt: markerTarget)
            .integral
        let localMarkerTarget = CGPoint(
            x: markerTarget.x - markerPanelFrame.minX,
            y: markerTarget.y - markerPanelFrame.minY
        )

        return AskNugumiPetAnswerTargetPanelPresentation(
            bubblePanelFrame: bubblePanelFrame,
            markerPanelFrame: markerPanelFrame,
            localMarkerTarget: localMarkerTarget
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

struct AskNugumiPetAnswerTargetPresentation: Equatable {
    let markerTarget: CGPoint
    let movementTarget: CGPoint?
}

enum AskNugumiPetAnswerTargetPresentationPolicy {
    static func presentation(
        for target: AskNugumiPetTarget,
        screenFrame: CGRect
    ) -> AskNugumiPetAnswerTargetPresentation {
        AskNugumiPetAnswerTargetPresentation(
            markerTarget: AskNugumiCoordinateMapper.exactScreenPoint(
                for: target,
                screenFrame: screenFrame
            ),
            movementTarget: nil
        )
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
    static func exactScreenPoint(
        for target: AskNugumiPetTarget,
        screenFrame: CGRect
    ) -> CGPoint {
        let mappedX = screenFrame.minX + target.x * screenFrame.width
        let mappedY = screenFrame.maxY - target.y * screenFrame.height

        return CGPoint(
            x: min(max(mappedX, screenFrame.minX), screenFrame.maxX),
            y: min(max(mappedY, screenFrame.minY), screenFrame.maxY)
        )
    }

    static func screenPoint(
        for target: AskNugumiPetTarget,
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGPoint {
        let point = exactScreenPoint(for: target, screenFrame: screenFrame)

        return CGPoint(
            x: min(max(point.x, visibleFrame.minX), visibleFrame.maxX),
            y: min(max(point.y, visibleFrame.minY), visibleFrame.maxY)
        )
    }
}
