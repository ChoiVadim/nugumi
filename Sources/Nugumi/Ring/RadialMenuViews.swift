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

/// Transparent backdrop behind the ring buttons. A click that lands on it —
/// rather than on a button — dismisses the menu. It also tracks hover over
/// the ring's center: the panel occludes the presenter's own tracking area,
/// so the bar underneath cannot see those hovers itself.
final class RadialMenuBackdropView: NSView {
    var onEmptyClick: (() -> Void)?
    var onCenterHoverChange: ((Bool) -> Void)?
    private var centerTrackingArea: NSTrackingArea?

    func trackCenterHover(in rect: NSRect) {
        if let centerTrackingArea {
            removeTrackingArea(centerTrackingArea)
        }
        let area = NSTrackingArea(
            rect: rect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
        centerTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onCenterHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onCenterHoverChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        onEmptyClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onEmptyClick?()
    }
}

/// One circular glass button on the ring: SF Symbol icon, hover tint, and a
/// small label that fades in under the circle on hover.
final class RadialMenuButtonView: NSView {
    private let onPick: () -> Void
    private let circleView = NSVisualEffectView()
    /// Liquid Glass backing (NSGlassEffectView) when the OS has it; the class
    /// is resolved by name at runtime because the release SDK predates the
    /// symbol (same constraint as GlassHostView). nil → circleView fallback.
    private var liquidGlassView: NSView?
    private let iconView = NSImageView()
    private var trackingArea: NSTrackingArea?

    /// Runtime-only NSGlassEffectView factory. KVC keys are guarded by
    /// responds checks so a future rename degrades to the fallback glass
    /// instead of throwing.
    private static func makeLiquidGlass(diameter: CGFloat) -> (glass: NSView, content: NSView)? {
        guard let cls = NSClassFromString("NSGlassEffectView") as? NSView.Type else { return nil }
        let glass = cls.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        guard glass.responds(to: NSSelectorFromString("setCornerRadius:")),
              glass.responds(to: NSSelectorFromString("setContentView:"))
        else { return nil }
        glass.setValue(NSNumber(value: Double(diameter / 2)), forKey: "cornerRadius")
        let content = NSView(frame: glass.bounds)
        content.autoresizingMask = [.width, .height]
        glass.setValue(content, forKey: "contentView")
        return (glass, content)
    }

    /// Fired on hover in/out — the controller shows the label bubble, which
    /// lives outside this view so the ring hit-areas stay circle-sized.
    var onHoverChange: ((Bool) -> Void)?

    /// When true, hover does NOT toggle the glass tint itself — the controller
    /// drives it via `setHighlighted` instead (for the sticky second layer,
    /// where the highlight is decoupled from the raw cursor position).
    var suppressHoverTint = false

    init(image: NSImage, onPick: @escaping () -> Void) {
        self.onPick = onPick

        let diameter = RadialMenuLayoutPolicy.buttonDiameter
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true

        // Content (tint overlay + icon) goes inside whichever glass backs the
        // circle: Liquid Glass on macOS 26+, the frosted effect view before.
        let contentHost: NSView
        if let liquid = Self.makeLiquidGlass(diameter: diameter) {
            liquid.glass.frame = bounds
            addSubview(liquid.glass)
            liquidGlassView = liquid.glass
            contentHost = liquid.content
        } else {
            circleView.material = .hudWindow
            circleView.state = .active
            circleView.blendingMode = .behindWindow
            circleView.wantsLayer = true
            circleView.layer?.cornerRadius = diameter / 2
            circleView.layer?.masksToBounds = true
            circleView.frame = bounds
            addSubview(circleView)
            contentHost = circleView
        }

        iconView.image = image
        iconView.contentTintColor = .labelColor
        iconView.imageAlignment = .alignCenter
        // Natural symbol size, dead-center: proportional-down fitting can
        // nudge the glyph a point off-center when the fitted size rounds.
        iconView.imageScaling = .scaleNone
        iconView.frame = contentHost.bounds
        iconView.autoresizingMask = [.width, .height]
        contentHost.addSubview(iconView)

        // Resting look is the inverted glass (colors swapped vs. the old
        // default) — highlight flips it back to plain system glass.
        applyHighlight(false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var wantsUpdateLayer: Bool { true }

    // A smaller cousin of the floating button's halo — enough to lift the
    // discs off the backdrop without a heavy drop shadow.
    override func updateLayer() {
        guard let layer = self.layer else { return }
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: -1)
        layer.shadowPath = CGPath(ellipseIn: bounds, transform: nil)
        layer.masksToBounds = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    // Swallow mouseDown: unhandled it would bubble up the responder chain to
    // the backdrop, whose mouseDown dismisses the menu before mouseUp lands.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location) else { return }
        onPick()
    }

    private func setHovered(_ hovered: Bool) {
        if !suppressHoverTint { applyHighlight(hovered) }
        onHoverChange?(hovered)
    }

    /// Controller-driven highlight (used by the sticky second layer, where the
    /// highlighted button isn't necessarily the one under the cursor).
    func setHighlighted(_ on: Bool) {
        applyHighlight(on)
    }

    private func applyHighlight(_ on: Bool) {
        // Bare glass always — no color wash. Hover/selection is a springy
        // size bump of the glass disc itself. Only the CHILD's frame moves;
        // the root frame belongs to the ring's fan/collapse animations, so
        // the bump can never fight them (bounds stays the fixed diameter).
        let diameter = RadialMenuLayoutPolicy.buttonDiameter
        let scaled = on ? diameter * 1.16 : diameter
        let inset = (diameter - scaled) / 2
        let target = NSRect(x: inset, y: inset, width: scaled, height: scaled)
        let glass = liquidGlassView ?? circleView
        // Keep the disc a true circle: the corner radius doesn't animate with
        // the frame, but a 3-4pt radius jump on a growing circle is invisible.
        if let liquidGlassView {
            if liquidGlassView.responds(to: NSSelectorFromString("setCornerRadius:")) {
                liquidGlassView.setValue(NSNumber(value: Double(scaled / 2)), forKey: "cornerRadius")
            }
        } else {
            circleView.layer?.cornerRadius = scaled / 2
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.45, 0.5, 1)
            glass.animator().frame = target
        }
    }
}

/// Logi-style callout for a ring button's hover label: solid rounded rect
/// plus a small tail pointing back at the circle. Deliberately fixed white
/// with black text — the old translucent in-panel label was unreadable on
/// busy or dark backgrounds, and a solid callout reads on any of them.
final class RadialMenuLabelBubbleView: NSView {
    private static let tailLength: CGFloat = 6
    /// Corner tails read much larger than side ones — their base already spans
    /// the whole rounded corner — so they poke out less to compensate.
    private static let cornerTailLength: CGFloat = 3
    private static let tailHalfWidth: CGFloat = 5
    private static let hPad: CGFloat = 9
    private static let vPad: CGFloat = 5
    private static let corner: CGFloat = 9
    private static let textAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
        .foregroundColor: NSColor.black,
    ]

    private let text: String
    /// The bubble edge carrying the tail — the edge that faces the circle.
    private let tailEdge: RadialMenuLabelPlacement

    init(text: String, tailEdge: RadialMenuLabelPlacement) {
        self.text = text
        self.tailEdge = tailEdge

        let textSize = (text as NSString).size(withAttributes: Self.textAttributes)
        var size = NSSize(
            width: ceil(textSize.width) + Self.hPad * 2,
            height: ceil(textSize.height) + Self.vPad * 2
        )
        switch tailEdge {
        case .left, .right:
            size.width += Self.tailLength
        case .top, .bottom:
            size.height += Self.tailLength
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            // A corner tail pokes out along both axes.
            size.width += Self.cornerTailLength
            size.height += Self.cornerTailLength
        }
        super.init(frame: NSRect(origin: .zero, size: size))

        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 4
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        // The tail is drawn outside the body but inside the frame — the body
        // rect cedes `tailLength` on the tail edge.
        var body = bounds
        switch tailEdge {
        case .left:
            body.origin.x += Self.tailLength
            body.size.width -= Self.tailLength
        case .right:
            body.size.width -= Self.tailLength
        case .bottom:
            body.origin.y += Self.tailLength
            body.size.height -= Self.tailLength
        case .top:
            body.size.height -= Self.tailLength
        case .bottomLeft:
            body.origin.x += Self.cornerTailLength
            body.size.width -= Self.cornerTailLength
            body.origin.y += Self.cornerTailLength
            body.size.height -= Self.cornerTailLength
        case .bottomRight:
            body.size.width -= Self.cornerTailLength
            body.origin.y += Self.cornerTailLength
            body.size.height -= Self.cornerTailLength
        case .topLeft:
            body.origin.x += Self.cornerTailLength
            body.size.width -= Self.cornerTailLength
            body.size.height -= Self.cornerTailLength
        case .topRight:
            body.size.width -= Self.cornerTailLength
            body.size.height -= Self.cornerTailLength
        }

        let path = NSBezierPath(roundedRect: body, xRadius: Self.corner, yRadius: Self.corner)
        let tail = NSBezierPath()
        let length = Self.tailLength
        let half = Self.tailHalfWidth
        // Corner tails: the base chord spans the rounded corner (radius
        // `corner` along each edge), the tip pokes diagonally outward.
        switch tailEdge {
        case .left:
            tail.move(to: NSPoint(x: body.minX, y: body.midY - half))
            tail.line(to: NSPoint(x: body.minX - length, y: body.midY))
            tail.line(to: NSPoint(x: body.minX, y: body.midY + half))
        case .right:
            tail.move(to: NSPoint(x: body.maxX, y: body.midY - half))
            tail.line(to: NSPoint(x: body.maxX + length, y: body.midY))
            tail.line(to: NSPoint(x: body.maxX, y: body.midY + half))
        case .bottom:
            tail.move(to: NSPoint(x: body.midX - half, y: body.minY))
            tail.line(to: NSPoint(x: body.midX, y: body.minY - length))
            tail.line(to: NSPoint(x: body.midX + half, y: body.minY))
        case .top:
            tail.move(to: NSPoint(x: body.midX - half, y: body.maxY))
            tail.line(to: NSPoint(x: body.midX, y: body.maxY + length))
            tail.line(to: NSPoint(x: body.midX + half, y: body.maxY))
        case .bottomLeft:
            tail.move(to: NSPoint(x: body.minX, y: body.minY + Self.corner))
            tail.line(to: NSPoint(x: body.minX - Self.cornerTailLength, y: body.minY - Self.cornerTailLength))
            tail.line(to: NSPoint(x: body.minX + Self.corner, y: body.minY))
        case .bottomRight:
            tail.move(to: NSPoint(x: body.maxX - Self.corner, y: body.minY))
            tail.line(to: NSPoint(x: body.maxX + Self.cornerTailLength, y: body.minY - Self.cornerTailLength))
            tail.line(to: NSPoint(x: body.maxX, y: body.minY + Self.corner))
        case .topLeft:
            tail.move(to: NSPoint(x: body.minX, y: body.maxY - Self.corner))
            tail.line(to: NSPoint(x: body.minX - Self.cornerTailLength, y: body.maxY + Self.cornerTailLength))
            tail.line(to: NSPoint(x: body.minX + Self.corner, y: body.maxY))
        case .topRight:
            tail.move(to: NSPoint(x: body.maxX - Self.corner, y: body.maxY))
            tail.line(to: NSPoint(x: body.maxX + Self.cornerTailLength, y: body.maxY + Self.cornerTailLength))
            tail.line(to: NSPoint(x: body.maxX, y: body.maxY - Self.corner))
        }
        tail.close()

        // Fill the two shapes separately: a corner tail overlaps the body's
        // rounded-corner bulge, and appending into one path punches an
        // even-odd hole exactly there (the dark sliver bug).
        NSColor.white.setFill()
        path.fill()
        tail.fill()

        (text as NSString).draw(
            at: NSPoint(x: body.minX + Self.hPad, y: body.minY + Self.vPad),
            withAttributes: Self.textAttributes
        )
    }
}

