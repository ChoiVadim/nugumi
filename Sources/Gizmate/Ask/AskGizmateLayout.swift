import CoreGraphics
import Foundation

struct AskGizmateFloatingPromptLayout: Equatable {
    let panelSize: CGSize
    let pillFrame: CGRect
    let textFrame: CGRect
    let cornerRadius: CGFloat
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
