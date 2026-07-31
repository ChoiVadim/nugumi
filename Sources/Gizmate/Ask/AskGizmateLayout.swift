import CoreGraphics
import Foundation

struct AskGizmateAnswerBubbleLayout: Equatable {
    let panelSize: CGSize
    let bubbleFrame: CGRect
    let viewportFrame: CGRect
    let documentHeight: CGFloat
    let needsScroll: Bool
}

struct AskGizmatePromptInputLayout: Equatable {
    let panelSize: CGSize
    let bubbleFrame: CGRect
    let textFrame: CGRect
}

struct AskGizmateFloatingPromptLayout: Equatable {
    let panelSize: CGSize
    let pillFrame: CGRect
    let textFrame: CGRect
    let cornerRadius: CGFloat
}

struct AskGizmatePetBubblePresentation: Equatable {
    let promptFrame: CGRect
    let petOrigin: CGPoint
}

enum AskGizmateFloatingPromptMetrics {
    static let pillSize = CGSize(width: 260, height: 46)
    static let shadowMargin: CGFloat = 14
    static let edgeMargin: CGFloat = 12
    static let textHorizontalInset: CGFloat = 22
    static let textFieldHeight: CGFloat = 24
    static let cornerRadius: CGFloat = pillSize.height / 2

    static var layout: AskGizmateFloatingPromptLayout {
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

        return AskGizmateFloatingPromptLayout(
            panelSize: panelSize,
            pillFrame: pillFrame,
            textFrame: textFrame,
            cornerRadius: cornerRadius
        )
    }
}

enum AskGizmateFloatingTargetPresentationPolicy {
    static let buttonSize: CGFloat = 30
    static let shadowPadding: CGFloat = 15
    static let totalSize: CGFloat = buttonSize + shadowPadding * 2
}

enum AskGizmatePromptInputMetrics {
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

    static func layout(forContentHeight contentHeight: CGFloat) -> AskGizmatePromptInputLayout {
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

        return AskGizmatePromptInputLayout(
            panelSize: CGSize(width: panelWidth, height: panelHeight),
            bubbleFrame: CGRect(x: bubbleX, y: bubbleY, width: bubbleWidth, height: bubbleHeight),
            textFrame: CGRect(x: textX, y: textY, width: textWidth, height: textHeight)
        )
    }
}

enum AskGizmateAnswerBubbleMetrics {
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

    static func layout(forContentHeight contentHeight: CGFloat) -> AskGizmateAnswerBubbleLayout {
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

        return AskGizmateAnswerBubbleLayout(
            panelSize: CGSize(width: panelWidth, height: panelHeight),
            bubbleFrame: CGRect(x: bubbleX, y: bubbleY, width: bubbleWidth, height: bubbleHeight),
            viewportFrame: CGRect(x: textX, y: textY, width: textWidth, height: viewportHeight),
            documentHeight: max(sanitizedContentHeight, viewportHeight),
            needsScroll: sanitizedContentHeight > maximumViewportHeight
        )
    }
}

enum AskGizmatePetDismissalPolicy {
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

enum AskGizmatePetBubblePresentationMetrics {
    static let bubbleToPetPanelGap: CGFloat = -6

    static func presentation(
        petOrigin: CGPoint,
        petSize: CGSize,
        promptSize: CGSize,
        bubbleFrame: CGRect,
        visibleFrame: CGRect,
        edgeMargin: CGFloat
    ) -> AskGizmatePetBubblePresentation {
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

        return AskGizmatePetBubblePresentation(
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

enum AskGizmateCoordinateMapper {
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
