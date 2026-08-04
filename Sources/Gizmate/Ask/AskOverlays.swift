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

/// What a drawn-on-screen shape can be coloured.
///
/// Named colours rather than free-form hex: these shapes land on whatever the
/// user happens to have open, and a model given a hex field will sooner or later
/// pick one that vanishes into the background it is drawn over. Every entry here
/// is a system colour that reads in both appearances, and an unrecognised name
/// falls back to the default rather than rendering something invisible.
enum AskAnnotationPalette {
    /// Bright and unambiguous. The former default was the app's own accent —
    /// `NSColor(white: 0.788)` — which is a light grey over a screenshot, i.e.
    /// exactly the shade a marker must not be.
    static let `default` = NSColor.systemGreen

    private static let named: [String: NSColor] = [
        "green": .systemGreen,
        "red": .systemRed,
        "blue": .systemBlue,
        "yellow": .systemYellow,
        "orange": .systemOrange,
        "purple": .systemPurple,
        "pink": .systemPink,
        "cyan": .systemTeal,
    ]

    static func color(named name: String?) -> NSColor {
        guard let name else { return `default` }
        return named[name.trimmingCharacters(in: .whitespaces).lowercased()] ?? `default`
    }

    /// Text drawn *on* a filled shape — the label pill. White on systemYellow is
    /// unreadable, so the ink follows the fill rather than being fixed.
    static func ink(on fill: NSColor) -> NSColor {
        guard let rgb = fill.usingColorSpace(.sRGB) else { return .white }
        let luma = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luma > 0.6 ? .black : .white
    }
}

/// Click-through overlay that renders the model's explanation shapes
/// (`annotations` in the Ask response) over the captured screen. Purely
/// visual: it never takes mouse or keyboard input, so the user keeps
/// working "through" it. Every answer replaces the whole layer.
@MainActor
final class AskAnnotationOverlayController {
    private final class AnnotationPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class AnnotationCanvasView: NSView {
        var screenFrame: NSRect = .zero
        var annotations: [AskGizmateAnnotation] = [] {
            didSet { needsDisplay = true }
        }

        private static let strokeWidth: CGFloat = 3
        private static let haloWidth: CGFloat = 5.5
        private static let haloColor = NSColor.white.withAlphaComponent(0.9)

        override func draw(_ dirtyRect: NSRect) {
            guard !annotations.isEmpty,
                  let context = NSGraphicsContext.current?.cgContext
            else { return }
            // A soft drop shadow lifts the shapes off busy or light
            // backgrounds. The transparency layer makes the halo+stroke
            // composite cast one shadow as a unit instead of every stroke
            // shadowing its neighbors.
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -2),
                blur: 8,
                color: NSColor.black.withAlphaComponent(0.6).cgColor
            )
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            for annotation in annotations {
                let tint = AskAnnotationPalette.color(named: annotation.color)
                switch annotation.type {
                case .ellipse:
                    if let rect = localRect(for: annotation) {
                        strokeWithHalo(NSBezierPath(ovalIn: rect), tint)
                    }
                case .rect:
                    if let rect = localRect(for: annotation) {
                        strokeWithHalo(NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6), tint)
                    }
                case .arrow:
                    drawArrow(annotation, tint)
                case .label:
                    drawLabel(annotation, tint)
                }
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }

        // Window covers `screenFrame`, so view-local = screen − frame origin.
        private func localPoint(_ screenPoint: CGPoint) -> CGPoint {
            CGPoint(x: screenPoint.x - screenFrame.minX, y: screenPoint.y - screenFrame.minY)
        }

        private func localRect(for annotation: AskGizmateAnnotation) -> CGRect? {
            guard let cx = annotation.cx, let cy = annotation.cy,
                  let w = annotation.w, let h = annotation.h
            else { return nil }
            let screenRect = AskGizmateCoordinateMapper.screenRect(
                centerX: cx,
                centerY: cy,
                normalizedWidth: w,
                normalizedHeight: h,
                screenFrame: screenFrame
            )
            return CGRect(
                origin: localPoint(screenRect.origin),
                size: screenRect.size
            )
        }

        private func strokeWithHalo(_ path: NSBezierPath, _ tint: NSColor) {
            path.lineWidth = Self.haloWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            Self.haloColor.setStroke()
            path.stroke()
            path.lineWidth = Self.strokeWidth
            tint.setStroke()
            path.stroke()
        }

        private func drawArrow(_ annotation: AskGizmateAnnotation, _ tint: NSColor) {
            guard let fromX = annotation.fromX, let fromY = annotation.fromY,
                  let toX = annotation.toX, let toY = annotation.toY
            else { return }
            let from = localPoint(AskGizmateCoordinateMapper.exactScreenPoint(
                normalizedX: fromX, normalizedY: fromY, screenFrame: screenFrame
            ))
            let to = localPoint(AskGizmateCoordinateMapper.exactScreenPoint(
                normalizedX: toX, normalizedY: toY, screenFrame: screenFrame
            ))

            let angle = atan2(to.y - from.y, to.x - from.x)
            let headLength: CGFloat = 14
            let headWidth: CGFloat = 11
            let shaftEnd = CGPoint(
                x: to.x - cos(angle) * headLength,
                y: to.y - sin(angle) * headLength
            )

            let shaft = NSBezierPath()
            shaft.move(to: from)
            shaft.line(to: shaftEnd)
            strokeWithHalo(shaft, tint)

            let perpendicular = CGPoint(x: -sin(angle), y: cos(angle))
            let head = NSBezierPath()
            head.move(to: to)
            head.line(to: CGPoint(
                x: shaftEnd.x + perpendicular.x * headWidth / 2,
                y: shaftEnd.y + perpendicular.y * headWidth / 2
            ))
            head.line(to: CGPoint(
                x: shaftEnd.x - perpendicular.x * headWidth / 2,
                y: shaftEnd.y - perpendicular.y * headWidth / 2
            ))
            head.close()
            head.lineWidth = 2.5
            Self.haloColor.setStroke()
            head.stroke()
            tint.setFill()
            head.fill()
        }

        private func drawLabel(_ annotation: AskGizmateAnnotation, _ tint: NSColor) {
            guard let x = annotation.x, let y = annotation.y,
                  let text = annotation.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return }
            let anchor = localPoint(AskGizmateCoordinateMapper.exactScreenPoint(
                normalizedX: x, normalizedY: y, screenFrame: screenFrame
            ))

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: AskAnnotationPalette.ink(on: tint)
            ]
            let string = NSAttributedString(string: text, attributes: attributes)
            let textSize = string.size()
            let paddingX: CGFloat = 8
            let paddingY: CGFloat = 4
            var pill = CGRect(
                x: anchor.x - textSize.width / 2 - paddingX,
                y: anchor.y - textSize.height / 2 - paddingY,
                width: textSize.width + paddingX * 2,
                height: textSize.height + paddingY * 2
            )
            // Keep the pill on screen even for edge anchors.
            pill.origin.x = min(max(pill.origin.x, 2), bounds.maxX - pill.width - 2)
            pill.origin.y = min(max(pill.origin.y, 2), bounds.maxY - pill.height - 2)

            let background = NSBezierPath(
                roundedRect: pill,
                xRadius: pill.height / 2,
                yRadius: pill.height / 2
            )
            background.lineWidth = 2
            Self.haloColor.setStroke()
            background.stroke()
            tint.setFill()
            background.fill()
            string.draw(at: CGPoint(
                x: pill.midX - textSize.width / 2,
                y: pill.midY - textSize.height / 2
            ))
        }
    }

    private let panel: AnnotationPanel
    private let canvas: AnnotationCanvasView
    private var didClose = false

    let screenFrame: NSRect

    init(screenFrame: NSRect) {
        self.screenFrame = screenFrame
        canvas = AnnotationCanvasView(frame: NSRect(origin: .zero, size: screenFrame.size))
        canvas.screenFrame = screenFrame
        panel = AnnotationPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Same shelf as the drawing canvas: below the .floating Ask panels.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Capturable on purpose: annotations should survive into the user's
        // own screenshots. Gizmate's own follow-up captures still exclude this
        // layer via the capture-time sharing snapshot (which force-sets .none
        // and restores), and invisibility mode applies like any other window.
        InvisibilityState.apply(to: panel)
        // Purely visual layer: the user clicks straight through it.
        panel.ignoresMouseEvents = true
        panel.contentView = canvas
        panel.orderFrontRegardless()
    }

    /// Replaces the whole layer with this answer's shapes. Re-ordering front
    /// keeps replace semantics robust if another same-level window appeared
    /// since init.
    func show(_ annotations: [AskGizmateAnnotation]) {
        canvas.annotations = annotations
        panel.orderFrontRegardless()
    }

    /// Idempotent: teardown paths overlap.
    func close() {
        guard !didClose else { return }
        didClose = true
        panel.close()
    }
}

/// Transparent, non-activating overlay that covers the captured screen while
/// the Ask Gizmate prompt is open. Mouse drags become freehand red strokes;
/// at submit they are composited into the pending screen capture. The panel
/// never becomes key, so typing stays in the prompt field the whole time.
@MainActor
final class AskDrawingOverlayController {
    private final class OverlayPanel: NSPanel {
        /// Ask keeps this false so typing stays in its prompt field. A gizmo
        /// has no field, and its Return has to be swallowed rather than land
        /// in whatever app is behind the canvas — which only a key window can
        /// do, since a global monitor cannot consume an event.
        var acceptsKeys = false
        override var canBecomeKey: Bool { acceptsKeys }
        override var canBecomeMain: Bool { false }

        // Blanket updates (InvisibilityState.applyToAllOpenWindows, sharing
        // snapshot/restore) must never make the stroke canvas capturable:
        // clamp every assignment to .none. The super call is load-bearing —
        // an empty setter would never push .none to the window server at all.
        override var sharingType: NSWindow.SharingType {
            get { super.sharingType }
            set { super.sharingType = .none }
        }
    }

    private final class StrokeCanvasView: NSView {
        /// Shown centered near the top while a gizmo is waiting on the drawing.
        /// nil for Ask, whose own pill already says what to do.
        var hint: String? {
            didSet { needsDisplay = true }
        }
        var strokes: [[NSPoint]] = [] {
            didSet { needsDisplay = true }
        }
        private(set) var strokeDates: [Date] = []
        private var activeStroke: [NSPoint] = []

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // Cursor rects only apply to the key window and this panel is never
        // key, so the crosshair needs an always-active tracking area instead.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.cursorUpdate, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.crosshair.set()
        }

        override func mouseDown(with event: NSEvent) {
            activeStroke = [convert(event.locationInWindow, from: nil)]
        }

        override func mouseDragged(with event: NSEvent) {
            activeStroke.append(convert(event.locationInWindow, from: nil))
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) {
            // A plain click (no drag) draws nothing — stray clicks stay
            // harmless and never leave a dot on the screenshot.
            if activeStroke.count > 1 {
                strokes.append(activeStroke)
                strokeDates.append(Date())
            }
            activeStroke = []
            needsDisplay = true
        }

        func removeLastStroke() {
            guard !strokes.isEmpty else { return }
            strokes.removeLast()
            if !strokeDates.isEmpty {
                strokeDates.removeLast()
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.systemRed.setStroke()
            for stroke in strokes + [activeStroke] where stroke.count > 1 {
                let path = NSBezierPath()
                path.lineWidth = 4
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.move(to: stroke[0])
                for point in stroke.dropFirst() {
                    path.line(to: point)
                }
                path.stroke()
            }
            drawHint()
        }

        /// Drawn into the canvas rather than shown as a second panel: the
        /// canvas already covers the screen, and a pill window here would be
        /// one more thing to place, level and tear down. It never reaches the
        /// model either — `annotated(with:)` composites strokes, not this view.
        private func drawHint() {
            guard let hint else { return }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let size = (hint as NSString).size(withAttributes: attributes)
            let padding = NSSize(width: 16, height: 9)
            let pill = NSRect(
                x: (bounds.width - size.width) / 2 - padding.width,
                y: bounds.maxY - size.height - 2 * padding.height - 28,
                width: size.width + 2 * padding.width,
                height: size.height + 2 * padding.height
            )
            NSColor.black.withAlphaComponent(0.78).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            (hint as NSString).draw(
                at: NSPoint(x: pill.minX + padding.width, y: pill.minY + padding.height),
                withAttributes: attributes
            )
        }
    }

    private let panel: OverlayPanel
    private let canvas: StrokeCanvasView
    private let screenFrame: NSRect
    private var undoKeyMonitor: Any?
    private var finishKeyMonitor: Any?
    private let onFinish: ((Bool) -> Void)?
    private var lastTextEditAt: Date?
    private var didClose = false

    var window: NSWindow { panel }

    /// Committed strokes in AppKit global (screen) coordinates — the exact
    /// input `AskGizmateScreenCapture.annotated(with:)` expects.
    var strokes: [[NSPoint]] {
        canvas.strokes.map { stroke in
            stroke.map { NSPoint(x: $0.x + screenFrame.minX, y: $0.y + screenFrame.minY) }
        }
    }

    /// `onFinish` turns the canvas from Ask's silent companion into something
    /// that can end a gizmo's input on its own: `true` for Return, `false` for
    /// Esc. Ask leaves it nil — its pill is what submits, and a Return monitor
    /// here would take the key out of its prompt field.
    init(screenFrame: NSRect, hint: String? = nil, onFinish: ((Bool) -> Void)? = nil) {
        self.screenFrame = screenFrame
        self.onFinish = onFinish
        canvas = StrokeCanvasView(frame: NSRect(origin: .zero, size: screenFrame.size))
        canvas.hint = hint
        panel = OverlayPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // One notch below .floating so the Ask pill (.floating) stays
        // clickable above the canvas.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Strokes must never leak into a screen capture — they are
        // composited into the image at submit instead.
        panel.sharingType = .none
        // Explicit `false` opts out of AppKit's per-pixel transparency hit
        // test: a fully clear window must still receive drawing drags.
        panel.ignoresMouseEvents = false
        panel.contentView = canvas
        if onFinish != nil {
            panel.acceptsKeys = true
            // Same two lines every focus-taking panel here uses; the guard both
            // activates and keeps the settings window from riding along.
            SelfActivationGuard.activate()
            panel.makeKeyAndOrderFront(nil)
            installFinishKeyMonitor()
        } else {
            panel.orderFrontRegardless()
        }
        installUndoKeyMonitor()
    }

    /// Idempotent: every Ask teardown path calls this, some more than once.
    func close() {
        guard !didClose else { return }
        didClose = true
        for monitor in [undoKeyMonitor, finishKeyMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        undoKeyMonitor = nil
        finishKeyMonitor = nil
        panel.close()
        // The canvas held focus so it could swallow Return; a `.replace` gizmo
        // has to type back into the app the user came from.
        if onFinish != nil {
            SelfActivationGuard.relinquish()
        }
    }

    /// Return finishes, Esc cancels. Consumed (`return nil`) rather than passed
    /// on — a Return that also reached the app behind would insert a newline
    /// into whatever the user was just looking at.
    private func installFinishKeyMonitor() {
        finishKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let onFinish = self.onFinish else { return event }
            switch Int(event.keyCode) {
            case kVK_Return, kVK_ANSI_KeypadEnter:
                onFinish(true)
                return nil
            case kVK_Escape:
                onFinish(false)
                return nil
            default:
                return event
            }
        }
    }

    enum UndoTarget: Equatable {
        case textField
        case stroke
    }

    /// Chronological ⌘Z arbitration between the prompt's text field and the
    /// stroke canvas: undo whatever the user touched last, and fall back to
    /// strokes once the field's undo stack is exhausted.
    static func undoTarget(
        lastStrokeAt: Date?,
        lastTextEditAt: Date?,
        textCanUndo: Bool
    ) -> UndoTarget {
        guard let lastStrokeAt else { return .textField }
        if let lastTextEditAt, lastTextEditAt > lastStrokeAt, textCanUndo {
            return .textField
        }
        return .stroke
    }

    /// Keystrokes that plausibly edit the prompt text (typing, delete,
    /// paste/cut) — used only to order text edits against strokes for ⌘Z.
    /// Caret movement also stamps here; that skews arbitration toward the
    /// field the user is actively in, which is the intuitive outcome.
    private static func isTextEditKeystroke(
        _ event: NSEvent,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard NSApp.keyWindow?.firstResponder is NSTextView else { return false }
        if modifiers == .command {
            let key = event.charactersIgnoringModifiers
            return key == "v" || key == "x"
        }
        guard modifiers.subtracting([.shift, .option]).isEmpty else { return false }
        return event.charactersIgnoringModifiers?.isEmpty == false
    }

    // ⌘Z anywhere while the Ask UI is open undoes the user's most recent
    // action: a stroke on the canvas or an edit in the prompt field,
    // whichever came last. A local monitor works for both the pill and the
    // Ask prompt (whichever is key); non-⌘Z keystrokes are only observed to
    // timestamp text edits and always pass through.
    private func installUndoKeyMonitor() {
        undoKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isUndo = modifiers == .command && event.charactersIgnoringModifiers == "z"
            guard isUndo else {
                if Self.isTextEditKeystroke(event, modifiers: modifiers) {
                    self.lastTextEditAt = Date()
                }
                return event
            }
            let textView = NSApp.keyWindow?.firstResponder as? NSTextView
            switch Self.undoTarget(
                lastStrokeAt: self.canvas.strokeDates.last,
                lastTextEditAt: self.lastTextEditAt,
                textCanUndo: textView?.undoManager?.canUndo == true
            ) {
            case .stroke:
                self.canvas.removeLastStroke()
                return nil
            case .textField:
                return event
            }
        }
    }
}

