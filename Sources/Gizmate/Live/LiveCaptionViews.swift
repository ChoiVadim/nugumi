import AppKit

/// Floating, draggable, always-on-top captions window. Pure view layer — the
/// controller pushes transcript + status updates in.
/// Collapsed indicator pill — a native recreation of the VoiceInput component:
/// a continuously rotating rounded-square "rec" glyph, a 12-bar animated
/// equalizer, and an elapsed timer. Drag to move the window; click (without
/// dragging) to expand back to the captions.
final class RecordIndicatorView: NSView {
    var onClick: (() -> Void)?
    var onToggleRecord: (() -> Void)?

    private let recGlyph = CAShapeLayer()
    private var bars: [CALayer] = []
    private let timeLayer = CATextLayer()
    private var isPausedState = false

    private static let barCount = 12
    private static let squareSize: CGFloat = 14
    private static let barWidth: CGFloat = 2
    private static let barGap: CGFloat = 2
    private static let timerWidth: CGFloat = 40
    private static let leadingInset: CGFloat = 14

    private var initialMouseLocation: NSPoint?
    private var initialWindowOrigin: NSPoint?
    private var didDrag = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        recGlyph.bounds = CGRect(x: 0, y: 0, width: Self.squareSize, height: Self.squareSize)
        layer?.addSublayer(recGlyph)
        updateGlyph()

        let barColor = NSColor(calibratedWhite: 1.0, alpha: 0.78).cgColor
        for _ in 0..<Self.barCount {
            let bar = CALayer()
            bar.backgroundColor = barColor
            bar.cornerRadius = Self.barWidth / 2
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: 3)
            layer?.addSublayer(bar)
            bars.append(bar)
        }

        timeLayer.string = "00:00"
        timeLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        timeLayer.fontSize = 11
        timeLayer.foregroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.55).cgColor
        timeLayer.alignmentMode = .left
        timeLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(timeLayer)
    }

    required init?(coder: NSCoder) { nil }

    func setTime(_ text: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        timeLayer.string = text
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let cy = bounds.midY
        recGlyph.position = CGPoint(x: Self.leadingInset + Self.squareSize / 2, y: cy)
        if !isPausedState && recGlyph.animation(forKey: "spin") == nil { addSpin() }

        let startX = Self.leadingInset + Self.squareSize + 10
        for (i, bar) in bars.enumerated() {
            bar.position = CGPoint(x: startX + CGFloat(i) * (Self.barWidth + Self.barGap) + Self.barWidth / 2, y: cy)
            if !isPausedState && bar.animation(forKey: "eq") == nil { addEqualizer(to: bar, index: i) }
        }

        let barsEnd = startX + CGFloat(Self.barCount) * Self.barWidth
            + CGFloat(Self.barCount - 1) * Self.barGap
        timeLayer.frame = CGRect(x: barsEnd + 10, y: cy - 7, width: Self.timerWidth, height: 14)
        CATransaction.commit()
    }

    private func addSpin() {
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = Double.pi * 2
        spin.duration = 2
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        recGlyph.add(spin, forKey: "spin")
    }

    /// Reflects paused state: the rec square becomes a play ▶ glyph and the
    /// spin/equalizer animations freeze.
    func setPaused(_ paused: Bool) {
        guard paused != isPausedState else { return }
        isPausedState = paused
        updateGlyph()
        if paused {
            recGlyph.removeAnimation(forKey: "spin")
            recGlyph.transform = CATransform3DIdentity
            bars.forEach { bar in
                bar.removeAnimation(forKey: "eq")
                bar.transform = CATransform3DIdentity
            }
        } else {
            addSpin()
            for (i, bar) in bars.enumerated() { addEqualizer(to: bar, index: i) }
        }
    }

    private func updateGlyph() {
        let size = Self.squareSize
        let path = CGMutablePath()
        if isPausedState {
            // Play ▶ triangle — "tap to continue".
            path.move(to: CGPoint(x: 2, y: 1))
            path.addLine(to: CGPoint(x: 2, y: size - 1))
            path.addLine(to: CGPoint(x: size - 1, y: size / 2))
            path.closeSubpath()
            recGlyph.fillColor = NSColor(calibratedWhite: 1.0, alpha: 0.92).cgColor
        } else {
            path.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
                                cornerWidth: 3, cornerHeight: 3, transform: nil))
            recGlyph.fillColor = NSColor.systemRed.cgColor
        }
        recGlyph.path = path
    }

    private func addEqualizer(to bar: CALayer, index: Int) {
        let anim = CAKeyframeAnimation(keyPath: "transform.scale.y")
        let peak = 2.5 + Double.random(in: 1.0...4.0)
        anim.values = [1.0, peak, 1.8, peak * 0.7, 1.0]
        anim.keyTimes = [0, 0.25, 0.5, 0.75, 1.0]
        anim.duration = 0.9 + Double.random(in: 0...0.4)
        anim.beginTime = CACurrentMediaTime() + Double(index) * 0.05
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bar.add(anim, forKey: "eq")
    }

    override func mouseDown(with event: NSEvent) {
        initialMouseLocation = NSEvent.mouseLocation
        initialWindowOrigin = window?.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startMouse = initialMouseLocation,
              let startOrigin = initialWindowOrigin,
              let window else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - startMouse.x
        let dy = current.y - startMouse.y
        if abs(dx) > 2 || abs(dy) > 2 { didDrag = true }
        window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag {
            // Clicking the rec glyph toggles pause/resume; anywhere else expands.
            let point = convert(event.locationInWindow, from: nil)
            let glyphZone = Self.leadingInset + Self.squareSize + 8
            if point.x <= glyphZone {
                onToggleRecord?()
            } else {
                onClick?()
            }
        }
        initialMouseLocation = nil
        initialWindowOrigin = nil
    }
}

/// Pins thin, auto-hiding overlay scrollers. In a borderless floating panel
/// (mouse attached), a plain NSScrollView reverts a manually-set `.overlay`
/// back to the system's wide legacy scroller, whose track never disappears —
/// overriding the getter stops that revert so it matches the translate window.
final class OverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set {}
    }
}

/// Borderless live panel that can still become key — needed so the summary's
/// follow-up field can take text focus (and Cmd+C fires). `.nonactivatingPanel`
/// keeps the translated app frontmost while we hold key, so nothing is stolen.
final class KeyableLivePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Borderless icon button with a soft rounded hover highlight — used for the
/// captions header controls (pause/minimize/close).
/// Two modes:
/// - tint mode (default, no background): hover/selection are shown by changing
///   the icon tint only — nothing to clip against the glass corners.
/// - background mode (the round white play button): a persistent `restingBG`
///   that brightens to `hoverBG` on hover.
final class HoverIconButton: NSButton {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        CursorTrackingView.attach(.pointingHand, to: self)
    }

    var roundedFull = false
    var corner: CGFloat = 6
    var baseTint: NSColor = NSColor(calibratedWhite: 1.0, alpha: 0.6)
    var hoverTint: NSColor = NSColor(calibratedWhite: 1.0, alpha: 0.9)
    var restingBG: NSColor = .clear
    var hoverBG: NSColor?
    private var tracking: NSTrackingArea?
    private var isHovering = false
    private let circleMask = CAShapeLayer()

    private var usesBackground: Bool { hoverBG != nil || restingBG != .clear }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true   // re-inscribe the disc against the final frame
    }

    override func layout() {
        super.layout()
        guard usesBackground else { return }
        wantsLayer = true
        if roundedFull {
            // Clip the disc to a circle inscribed in the SHORT side, so a frame
            // that isn't perfectly square still renders a true circle — never the
            // pill that `cornerRadius = min/2` produces on a non-square rect.
            let d = min(bounds.width, bounds.height)
            let inset = CGRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
            circleMask.fillColor = NSColor.black.cgColor
            circleMask.frame = bounds
            circleMask.path = CGPath(ellipseIn: inset, transform: nil)
            layer?.mask = circleMask
            layer?.cornerRadius = 0
        } else {
            layer?.mask = nil
            layer?.cornerRadius = corner
        }
        layer?.backgroundColor = (isHovering ? (hoverBG ?? restingBG) : restingBG).cgColor
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        if usesBackground {
            layer?.backgroundColor = (hoverBG ?? restingBG).cgColor
        } else {
            contentTintColor = hoverTint
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        if usesBackground {
            layer?.backgroundColor = restingBG.cgColor
        } else {
            contentTintColor = baseTint
        }
    }
}

/// Shows the open-hand "grab to move" cursor on hover, hinting the card is a drag
/// handle (the window is movable by dragging its background).
final class DragHandleView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        CursorTrackingView.attach(.openHand, to: self)
    }
}
