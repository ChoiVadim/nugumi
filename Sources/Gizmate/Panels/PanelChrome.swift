import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreServices
import CoreText
import CryptoKit
import Darwin
import Foundation
import ServiceManagement
import Sparkle
import SwiftUI
import UserNotifications
import Vision

/// The translation panel's "Revise or ask a follow-up" field. A plain
/// `NSTextField` is editable by default; we only add Esc-to-close.
/// A non-bezeled `NSTextField` draws its text near the top of its frame, not
/// centered — so the leading icon (centered in the row) sat below the text.
/// This cell vertically centers the text in both draw and edit states.
private final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    private func centered(_ rect: NSRect) -> NSRect {
        let textHeight = cellSize(forBounds: rect).height
        guard textHeight < rect.height else { return rect }
        let dy = (rect.height - textHeight) / 2
        return NSRect(x: rect.minX, y: rect.minY + dy, width: rect.width, height: textHeight)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: centered(rect))
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centered(rect), in: controlView, editor: editor, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: centered(rect), in: controlView, editor: editor, delegate: delegate, start: start, length: length)
    }
}

final class FollowUpTextField: NSTextField {
    var onEscape: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // NSCell(textCell:) yields a label-style cell (not editable), so
        // re-enable editing/selection or the field can't take focus.
        cell = VerticallyCenteredTextFieldCell(textCell: "")
        isEditable = true
        isSelectable = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    // The panel uses `becomesKeyOnlyIfNeeded`, so it won't grab key until a view
    // asks for it. Force key + first responder on click so typing works even
    // while the source app is frontmost.
    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

extension NSScreen {
    static func visibleFrame(containing point: NSPoint) -> NSRect {
        NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
    }
}

enum GlassHostStyle {
    case regular
    case clear
}

/// NSVisualEffectView that re-clamps its corner radius on every resize tick.
/// AppKit's `animator().frame` machinery animates subview sizes with its own
/// timer, so a radius set once (or at pin time) goes stale mid-animation and a
/// radius above half the side pinches the mask into a squircle — the floating
/// button rendered non-circular below full size.
final class ClampedCornerEffectView: NSVisualEffectView {
    var desiredCornerRadius: CGFloat = 0

    /// Replaces the plain corner radius with an arbitrary shape, re-derived on
    /// every resize like the radius is. `cornerRadius` can only round corners
    /// outward; a concave corner is a curve that lives outside the rectangle,
    /// so shapes like the edge docks' bezel flare need a mask instead.
    var cornerPath: ((CGRect) -> CGPath)? {
        didSet { applyShape(size: bounds.size) }
    }

    private let shapeMask = CAShapeLayer()

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyShape(size: newSize)
    }

    private func applyShape(size: NSSize) {
        guard let cornerPath else {
            layer?.mask = nil
            layer?.cornerRadius = min(
                desiredCornerRadius,
                min(size.width, size.height) / 2
            )
            return
        }
        layer?.cornerRadius = 0
        shapeMask.path = cornerPath(CGRect(origin: .zero, size: size))
        layer?.mask = shapeMask
    }
}

final class GlassHostView: NSView {
    let contentView = NSView()
    private let material = ClampedCornerEffectView()

    /// `cornerPath` replaces the plain radius with a shape — the edge docks use
    /// it for the concave flare where the panel meets the bezel. nil keeps the
    /// uniform rounded rectangle every other caller expects.
    init(
        frame: NSRect,
        cornerRadius: CGFloat,
        tintColor: NSColor?,
        style: GlassHostStyle,
        cornerPath: ((CGRect) -> CGPath)? = nil
    ) {
        super.init(frame: frame)
        wantsLayer = true
        contentView.frame = bounds
        contentView.autoresizingMask = [.width, .height]

        // Keep this compatible with the current public macOS SDK used by CI/release builds.
        // Referencing NSGlassEffectView directly breaks compilation on Xcode versions whose
        // SDK does not yet define that symbol, even inside an #available(macOS 26.0, *) block.
        material.desiredCornerRadius = cornerRadius
        material.frame = bounds
        material.autoresizingMask = [.width, .height]
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = cornerRadius
        material.layer?.masksToBounds = true
        // After the radius, so the setter's `applyShape` wins over it.
        material.cornerPath = cornerPath
        addSubview(material)
        material.addSubview(contentView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    // Absolute layout instead of mask-based autoresizing: interrupting an
    // in-flight `animator().frame` animation drops autoresizing deltas, so
    // full-bleed subviews drift smaller with every interrupted hover cycle
    // (the floating button's glass visibly shrank). Pinning to bounds on every
    // resize is self-healing — any later resize restores exact geometry.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        material.frame = bounds
        contentView.frame = material.bounds
    }
}

final class GlassChromeOverlayView: NSView {
    var cornerRadius: CGFloat = 22

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor(calibratedWhite: 1.0, alpha: 0.16).setStroke()
        path.lineWidth = 1
        path.stroke()

        let innerRect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let innerPath = NSBezierPath(roundedRect: innerRect, xRadius: max(0, cornerRadius - 1), yRadius: max(0, cornerRadius - 1))
        NSColor(calibratedWhite: 1.0, alpha: 0.06).setStroke()
        innerPath.lineWidth = 1
        innerPath.stroke()
    }
}

final class HairlineSeparatorView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 1.0, alpha: 0.14).setFill()
        bounds.fill()
    }
}

enum TranslationPanelPalette {
    static let targetTitle = NSColor(calibratedWhite: 1.0, alpha: 0.5)
    static let resultText = NSColor(calibratedWhite: 0.94, alpha: 0.96)
    static let resultLink = NSColor(calibratedWhite: 1.0, alpha: 0.82)
    static let actionIconEnabled = NSColor(calibratedWhite: 1.0, alpha: 0.68)
    static let actionIconDisabled = NSColor(calibratedWhite: 1.0, alpha: 0.30)
    static let sourceAction = NSColor(calibratedWhite: 1.0, alpha: 0.70)
}

final class LanguagePickerButton: NSButton {
    static let titleLeadingInset: CGFloat = 8

    private static let horizontalPadding: CGFloat = 8
    private static let chevronGap: CGFloat = 6
    private static let pickerIndicatorWidth: CGFloat = 12

    private let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    private let titleColor = TranslationPanelPalette.targetTitle

    private var hoverTrackingArea: NSTrackingArea?
    private var displayTitle = ""
    private var isHovered = false
    private var isMenuOpen = false
    private var pickerEnabled = true

    var preferredWidth: CGFloat {
        let titleWidth = ceil((displayTitle as NSString).size(withAttributes: [.font: titleFont]).width)
        let affordanceWidth = pickerEnabled ? Self.chevronGap + Self.pickerIndicatorWidth : 0
        let paddedWidth = titleWidth + Self.horizontalPadding * 2 + affordanceWidth
        return min(max(paddedWidth, 64), 220)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isBordered = false
        alignment = .left
        focusRingType = .none
        title = ""
        setButtonType(.momentaryChange)
        applyStyle()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        guard pickerEnabled else {
            return
        }

        isHovered = true
        applyStyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyStyle()
    }

    override func draw(_ dirtyRect: NSRect) {
        let title = NSAttributedString(string: displayTitle, attributes: [
            .font: titleFont,
            .foregroundColor: titleColor,
            .kern: 0
        ])
        let titleSize = title.size()
        let titleOrigin = NSPoint(
            x: Self.horizontalPadding,
            y: floor((bounds.height - titleSize.height) / 2) - 1
        )
        title.draw(at: titleOrigin)

        guard pickerEnabled && (isHovered || isMenuOpen || isHighlighted),
              bounds.width > Self.horizontalPadding * 2 + Self.pickerIndicatorWidth
        else {
            return
        }

        drawPickerIndicator(titleHeight: titleSize.height)
    }

    private func drawPickerIndicator(titleHeight: CGFloat) {
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        guard let base = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
            return
        }

        let size = base.size
        let tinted = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            self.titleColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }

        // Center on the title's vertical center, mirroring the title's -1 nudge.
        let textCenterY = floor((bounds.height - titleHeight) / 2) - 1 + titleHeight / 2
        let x = bounds.maxX - Self.horizontalPadding - size.width
        let y = textCenterY - size.height / 2
        tinted.draw(at: NSPoint(x: floor(x), y: floor(y)), from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    func setTitle(_ title: String, pickerEnabled: Bool) {
        displayTitle = title
        self.pickerEnabled = pickerEnabled
        toolTip = pickerEnabled ? "Choose translation language" : nil
        isEnabled = true
        applyStyle()
        needsLayout = true
    }

    func setMenuOpen(_ isMenuOpen: Bool) {
        self.isMenuOpen = isMenuOpen
        applyStyle()
    }

    private func applyStyle() {
        layer?.cornerRadius = 0
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        layer?.borderColor = NSColor.clear.cgColor
        needsDisplay = true
    }
}

final class SourcePreviewView: NSView {
    private static let moreButtonWidth: CGFloat = 50
    private static let moreGap: CGFloat = 8
    private static let sourceTextYOffset: CGFloat = 2
    private static let moreButtonYOffset: CGFloat = 1

    private let textLabel = NSTextField(labelWithString: "")
    private let moreButton = NSButton(title: "more", target: nil, action: nil)
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false
    private var canExpand = false

    var onMore: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        textLabel.font = NSFont.systemFont(ofSize: TranslationContentView.sourceFontSize, weight: .semibold)
        textLabel.textColor = NSColor(calibratedWhite: 1.0, alpha: 0.90)
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.maximumNumberOfLines = 1
        textLabel.usesSingleLineMode = true
        addSubview(textLabel)

        moreButton.target = self
        moreButton.action = #selector(moreTapped)
        moreButton.isBordered = false
        moreButton.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        moreButton.contentTintColor = TranslationPanelPalette.sourceAction
        moreButton.isHidden = true
        moreButton.toolTip = "Show full source"
        addSubview(moreButton)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateMoreVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateMoreVisibility()
    }

    override func layout() {
        super.layout()
        let buttonVisible = !moreButton.isHidden
        let labelWidth = buttonVisible
            ? max(0, bounds.width - Self.moreButtonWidth - Self.moreGap)
            : bounds.width
        let sourceTextHeight = ceil(textLabel.intrinsicContentSize.height)
        let moreButtonHeight = ceil(moreButton.intrinsicContentSize.height)
        let rowHeight = max(sourceTextHeight, moreButtonHeight)
        let rowY = floor((bounds.height - rowHeight) / 2)
        textLabel.frame = NSRect(
            x: 0,
            y: rowY + Self.sourceTextYOffset,
            width: labelWidth,
            height: rowHeight
        )
        moreButton.frame = NSRect(
            x: bounds.maxX - Self.moreButtonWidth,
            y: rowY + Self.moreButtonYOffset,
            width: Self.moreButtonWidth,
            height: rowHeight
        )
    }

    func configure(text: String, canExpand: Bool) {
        textLabel.stringValue = text
        self.canExpand = canExpand
        updateMoreVisibility()
    }

    private func updateMoreVisibility() {
        moreButton.isHidden = !(canExpand && isHovered)
        needsLayout = true
    }

    @objc private func moreTapped() {
        onMore?()
    }
}

/// A single line of text with a highlight that sweeps across it — the "AI is
/// working" shimmer. Used as the result panel's loading state instead of
/// cycling dots. The text shape masks an animated gradient.
final class ShimmerTextLabel: NSView {
    private let gradientLayer = CAGradientLayer()
    private let textLayer = CATextLayer()
    private var displayFont = NSFont.systemFont(ofSize: 16, weight: .semibold)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        textLayer.contentsScale = scale
        textLayer.alignmentMode = .left
        textLayer.truncationMode = .end
        textLayer.isWrapped = false
        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        gradientLayer.mask = textLayer
        layer?.addSublayer(gradientLayer)
    }

    required init?(coder: NSCoder) { nil }

    func configure(text: String, font: NSFont, base: NSColor, highlight: NSColor) {
        displayFont = font
        textLayer.string = text
        textLayer.font = font as CTFont
        textLayer.fontSize = font.pointSize
        // Narrow bright band riding on a dim base; animating `locations` sweeps it.
        gradientLayer.colors = [base, base, highlight, base, base].map(\.cgColor)
        gradientLayer.locations = [0, 0.35, 0.5, 0.65, 1]
        needsLayout = true
    }

    override func layout() {
        super.layout()
        gradientLayer.frame = bounds
        let lineHeight = ceil(displayFont.ascender - displayFont.descender + displayFont.leading)
        textLayer.frame = NSRect(x: 0, y: max(0, (bounds.height - lineHeight) / 2), width: bounds.width, height: lineHeight)
    }

    func startAnimating() {
        guard gradientLayer.animation(forKey: "shimmer") == nil else { return }
        let anim = CABasicAnimation(keyPath: "locations")
        anim.fromValue = [-0.6, -0.25, 0.0, 0.25, 0.6]
        anim.toValue = [0.4, 0.75, 1.0, 1.25, 1.6]
        anim.duration = 1.4
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        gradientLayer.add(anim, forKey: "shimmer")
    }

    func stopAnimating() {
        gradientLayer.removeAnimation(forKey: "shimmer")
    }
}

