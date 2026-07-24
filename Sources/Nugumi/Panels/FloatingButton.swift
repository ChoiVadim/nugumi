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

@MainActor
final class FloatingTranslateButtonController {
    private let panel: NSPanel
    private let selectedText: String
    private let onTranslate: (String) -> Void
    private let onRewrite: (String) -> Void
    private let onSmartReply: (String) -> Void
    private let buttonView: FloatingTranslateButtonView
    private let onAsk: () -> Void
    private let onScreenshot: () -> Void
    private let onLive: () -> Void
    private let onDictate: () -> Void
    private let summarizeOption: RingSummarizeOption?
    private var radialMenu: RadialActionMenuController?
    /// Fired whenever the ring closes for any reason (pick, dismiss, toggle).
    /// The quick menu uses it to fade this button away — for the persistent
    /// selection bar it stays nil and the bar lives on.
    var onMenuClosed: (() -> Void)?

    init(
        screenPoint: NSPoint,
        selectedText: String,
        initialMode: TranslationMode,
        onTranslate: @escaping (String) -> Void,
        onRewrite: @escaping (String) -> Void,
        onSmartReply: @escaping (String) -> Void,
        onAsk: @escaping () -> Void,
        onScreenshot: @escaping () -> Void = {},
        onLive: @escaping () -> Void = {},
        onDictate: @escaping () -> Void = {},
        summarizeOption: RingSummarizeOption? = nil
    ) {
        self.selectedText = selectedText
        self.onTranslate = onTranslate
        self.onRewrite = onRewrite
        self.onSmartReply = onSmartReply
        self.onAsk = onAsk
        self.onScreenshot = onScreenshot
        self.onLive = onLive
        self.onDictate = onDictate
        self.summarizeOption = summarizeOption

        let buttonSize = AskNugumiFloatingTargetPresentationPolicy.buttonSize
        let shadowPadding = AskNugumiFloatingTargetPresentationPolicy.shadowPadding
        let totalSize = AskNugumiFloatingTargetPresentationPolicy.totalSize
        let origin = NSPoint(
            x: screenPoint.x + 5 - shadowPadding,
            y: screenPoint.y - buttonSize - 5 - shadowPadding
        )
        panel = NSPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: totalSize, height: totalSize)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        InvisibilityState.apply(to: panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false

        let container = NSView(frame: NSRect(origin: .zero, size: NSSize(width: totalSize, height: totalSize)))
        buttonView = FloatingTranslateButtonView(initialMode: initialMode)
        buttonView.frame = NSRect(x: shadowPadding, y: shadowPadding, width: buttonSize, height: buttonSize)
        buttonView.wantsLayer = true
        container.addSubview(buttonView)
        panel.contentView = container

        buttonView.onClick = { [weak self] in
            self?.toggleRadialMenu()
        }
    }

    func show() {
        panel.orderFrontRegardless()
        buttonView.enableHoverScaling()
    }

    func close() {
        radialMenu?.close()
        radialMenu = nil
        panel.close()
    }

    func setLoading() {
        panel.ignoresMouseEvents = true
        radialMenu?.close()
        radialMenu = nil
        buttonView.setLoading(true)
    }

    private func toggleRadialMenu() {
        if let radialMenu {
            radialMenu.close()
            menuDidClose()
            return
        }
        var items: [RingItem] = [
            .phosphor("magnifying-glass", label: "Explain") { [weak self] in
                guard let self else { return }
                self.menuDidClose()
                self.onTranslate(self.selectedText)
            },
            .phosphor("pencil-line", label: "Rewrite") { [weak self] in
                guard let self else { return }
                self.menuDidClose()
                self.onRewrite(self.selectedText)
            },
            .phosphor("arrow-bend-up-left", label: "Reply") { [weak self] in
                guard let self else { return }
                self.menuDidClose()
                self.onSmartReply(self.selectedText)
            },
            .phosphor("question", label: "Ask") { [weak self] in
                guard let self else { return }
                self.menuDidClose()
                self.onAsk()
            },
            .phosphor("scan", label: "Capture") { [weak self] in
                guard let self else { return }
                self.menuDidClose()
                self.onScreenshot()
            },
            .symbol("mic", label: "Dictate") { [weak self] in
                guard let self else { return }
                self.menuDidClose()
                self.onDictate()
            },
            .symbol("waveform", label: "Live") { [weak self] in
                guard let self else { return }
                self.menuDidClose()
                self.onLive()
            },
        ]
        if let opt = summarizeOption {
            items.insert(summarizeRingItem(opt, dismiss: { [weak self] in
                guard let self else { return }
                self.menuDidClose()
            }), at: 5)
        }
        let menu = RadialActionMenuController(
            centeredOn: buttonCenterInScreen(),
            ignoring: panel,
            items: items,
            onDismiss: { [weak self] in
                guard let self else { return }
                self.menuDidClose()
            }
        )
        menu.onCenterHoverChange = { [weak self] hovered in
            self?.buttonView.setCloseHovered(hovered)
        }
        radialMenu = menu
        menu.show()
        buttonView.setMenuOpen(true)
    }

    /// Bookkeeping shared by every ring-teardown path (pick, dismiss, toggle).
    private func menuDidClose() {
        radialMenu = nil
        if let onMenuClosed {
            // Transient quick-menu hub: it dies with the ring, so keep the
            // ✕ glyph while everything fades instead of flashing the mascot
            // for a beat first.
            onMenuClosed()
        } else {
            buttonView.setMenuOpen(false)
        }
    }

    /// Programmatic ring control for the quick menu, which presents this
    /// button as a transient hub at the cursor instead of a persistent bar.
    func openMenu() {
        guard radialMenu == nil else { return }
        toggleRadialMenu()
    }

    func closeMenu() {
        guard let radialMenu else { return }
        radialMenu.close()
        menuDidClose()
    }

    /// Quick-menu teardown: fade out in lockstep with the ring's own
    /// dissolve — same duration, same curve, one synchronized exit.
    func fadeOutAndClose() {
        // The ring panel occluded this button's tracking area; when it
        // closes, the cursor (parked dead-center) re-enters and the hover
        // scale would balloon the fading button back to full size.
        buttonView.disableHoverScaling()
        panel.ignoresMouseEvents = true
        let panel = self.panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.close()
        })
    }

    private func buttonCenterInScreen() -> NSPoint {
        let frameInWindow = buttonView.convert(buttonView.bounds, to: nil)
        let screenRect = panel.convertToScreen(frameInWindow)
        return NSPoint(x: screenRect.midX, y: screenRect.midY)
    }
}

final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
final class FloatingTranslateButtonView: NSView {
    var onClick: (() -> Void)?

    private let actionButton = FirstMouseButton()
    private let progressIndicator = NSProgressIndicator()
    private var glassView: GlassHostView!
    private var currentMode: TranslationMode
    private var isLoading = false
    private var isMenuOpen = false
    private var isCloseHovered = false

    private var hoverTrackingArea: NSTrackingArea?
    private var hoverScalingEnabled = false
    /// The full-size frame the controller laid out; rest/hover scale around it.
    private var fullFrame: NSRect = .zero
    /// Resting scale for the idle floating button; springs up to 1.0 on hover.
    private static let restScale: CGFloat = 0.84

    init(initialMode: TranslationMode) {
        self.currentMode = initialMode
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        wantsLayer = true
        buildUI()
        apply(mode: initialMode)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer = self.layer else { return }
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: -1)
        layer.shadowPath = CGPath(ellipseIn: bounds, transform: nil)
        layer.masksToBounds = false
    }

    /// Shrinks the idle button and starts tracking hover. Called only for the
    /// persistent floating button; the loading/target variants stay full-size.
    func enableHoverScaling() {
        hoverScalingEnabled = true
        fullFrame = frame
        // Let the glyph image ride the frame: it rescales with the button bounds.
        actionButton.imageScaling = .scaleProportionallyUpOrDown
        applyScale(Self.restScale, animated: false)
        updateTrackingAreas()
    }

    /// Teardown freeze: stops hover from resizing the button while it fades.
    func disableHoverScaling() {
        hoverScalingEnabled = false
    }

    // Same rationale as GlassHostView.resizeSubviews: the rapid hover in/out
    // retargeting of `animator().frame` loses autoresizing deltas and the
    // inner glass/glyph shrink cumulatively. Lay the chain out absolutely.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        glassView.frame = bounds
        let content = glassView.contentView
        actionButton.frame = content.bounds
        let indicatorSize = progressIndicator.frame.size
        progressIndicator.frame = NSRect(
            x: (content.bounds.width - indicatorSize.width) / 2,
            y: (content.bounds.height - indicatorSize.height) / 2,
            width: indicatorSize.width,
            height: indicatorSize.height
        )
        // Re-run updateLayer so the shadow ellipse follows the new bounds.
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }
        guard hoverScalingEnabled else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard hoverScalingEnabled, !isLoading else { return }
        applyScale(1.0, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        // The ring panel covering the bar fires a synthetic exit the moment
        // it opens; keep the close button full-size while the ring is up.
        guard hoverScalingEnabled, !isLoading, !isMenuOpen else { return }
        applyScale(Self.restScale, animated: true)
    }

    /// Resizes the whole button via its frame — the only resize an
    /// `NSVisualEffectView` honors. The glyph is an `imageScaling` image, so it
    /// stretches with the animating button bounds: bar and icon scale as one.
    private func applyScale(_ scale: CGFloat, animated: Bool) {
        guard hoverScalingEnabled, fullFrame.width > 0 else { return }

        let targetFrame = NSRect(
            x: fullFrame.midX - fullFrame.width * scale / 2,
            y: fullFrame.midY - fullFrame.height * scale / 2,
            width: fullFrame.width * scale,
            height: fullFrame.height * scale
        )

        guard animated else {
            frame = targetFrame
            return
        }

        // Springy overshoot makes the grow feel lively rather than mechanical.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.26
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.45, 0.5, 1)
            animator().frame = targetFrame
        }
    }

    private func buildUI() {
        let glass = GlassHostView(
            frame: bounds,
            cornerRadius: bounds.width / 2,
            tintColor: NSColor(srgbRed: 0.06, green: 0.12, blue: 0.22, alpha: 0.55),
            style: .regular
        )
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        glassView = glass

        actionButton.target = self
        actionButton.action = #selector(buttonTapped)
        actionButton.frame = bounds
        actionButton.autoresizingMask = [.width, .height]
        actionButton.isBordered = false
        actionButton.contentTintColor = .white
        actionButton.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        actionButton.imageScaling = .scaleNone
        glass.contentView.addSubview(actionButton)

        let indicatorSize: CGFloat = 16
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true
        progressIndicator.appearance = NSAppearance(named: .darkAqua)
        progressIndicator.frame = NSRect(
            x: (bounds.width - indicatorSize) / 2,
            y: (bounds.height - indicatorSize) / 2,
            width: indicatorSize,
            height: indicatorSize
        )
        progressIndicator.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        progressIndicator.isHidden = true
        glass.contentView.addSubview(progressIndicator)
    }

    func apply(mode: TranslationMode) {
        currentMode = mode
        guard !isLoading else { return }
        applyModeVisuals()
    }

    func setLoading(_ loading: Bool) {
        guard isLoading != loading else { return }
        isLoading = loading
        if loading {
            // The spinner reads best at full size — drop any resting shrink.
            applyScale(1.0, animated: true)
            actionButton.isHidden = true
            actionButton.toolTip = nil
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
            actionButton.isHidden = false
            applyModeVisuals()
        }
    }

    private func applyModeVisuals() {
        // Render every glyph as an image (not a title/fixed-point symbol) so the
        // hover frame animation can scale it — `imageScaling` stretches it to the
        // animating button bounds.
        actionButton.image = Self.glyphImage(for: currentMode)
        actionButton.title = ""
        actionButton.imagePosition = .imageOnly
        actionButton.toolTip = "Choose an action"
    }

    /// While the radial menu is open the bar is its close affordance — the
    /// glyph flips to an ✕ so the second click reads as "close", not "act",
    /// and hovering it turns the whole button red (destructive affordance).
    func setMenuOpen(_ open: Bool) {
        guard !isLoading else { return }
        isMenuOpen = open
        if open {
            // The click that opened the menu happened on this button, so
            // the cursor starts on the ✕ — red right away. Full size while
            // the ring is up: the quick-menu hub opens with no preceding
            // hover, still at rest scale (a no-op for the hovered bar).
            isCloseHovered = true
            applyScale(1.0, animated: true)
            actionButton.image = Self.closeGlyphImage(hovered: true)
            actionButton.toolTip = "Close"
        } else {
            isCloseHovered = false
            applyScale(Self.restScale, animated: true)
            applyModeVisuals()
        }
    }

    /// Hover over the ring's center, reported by the menu overlay — its
    /// panel occludes this view's own tracking area while the ring is open,
    /// so the bar cannot see these hovers itself.
    func setCloseHovered(_ hovered: Bool) {
        guard isMenuOpen, isCloseHovered != hovered else { return }
        isCloseHovered = hovered
        actionButton.image = Self.closeGlyphImage(hovered: hovered)
    }

    /// Plain white ✕ at rest; a solid red disc with a dark ✕ on hover. The
    /// disc is drawn opaque, so the ✕ is tinted via a palette symbol config —
    /// the sourceAtop trick in `glyphImage(symbolName:)` only works on a
    /// transparent canvas.
    private static func closeGlyphImage(hovered: Bool) -> NSImage {
        guard hovered else { return glyphImage(symbolName: "xmark") }
        let side = AskNugumiFloatingTargetPresentationPolicy.buttonSize
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            // Translucent so the glass underneath shows through — a solid
            // red disc read too loud.
            NSColor.systemRed.withAlphaComponent(0.55).setFill()
            NSBezierPath(ovalIn: rect).fill()
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)
                .applying(.init(paletteColors: [NSColor.black.withAlphaComponent(0.8)]))
            guard let symbol = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return false }
            symbol.draw(in: NSRect(
                x: rect.midX - symbol.size.width / 2,
                y: rect.midY - symbol.size.height / 2,
                width: symbol.size.width,
                height: symbol.size.height
            ))
            return true
        }
    }

    /// A mode's glyph centered in a button-sized canvas with baked-in padding, so
    /// `imageScaling` shrinks/grows it proportionally as the button frame animates.
    private static func glyphImage(for mode: TranslationMode) -> NSImage {
        let name: String
        switch mode {
        case .selection, .revise, .reviseMessage, .summarizeChat, .summarizePage:
            // The mascot, not a generic sparkles glyph: the button that
            // opens the radial menu wears the app's own mark.
            return mascotGlyphImage()
        case .draftMessage:
            name = "text.insert"
        case .smartReply:
            name = "bubble.left.fill"
        }
        return glyphImage(symbolName: name)
    }

    /// The mascot centered in a button-sized canvas, same baked-in padding
    /// contract as `glyphImage(symbolName:)` so frame animations scale it.
    /// The mascot renders once up front — the drawing handler can re-run at
    /// draw time and must not build views.
    private static func mascotGlyphImage() -> NSImage {
        guard let mark = PetMascotView.markImage(height: 18) else {
            return glyphImage(symbolName: "sparkles")
        }
        let side = AskNugumiFloatingTargetPresentationPolicy.buttonSize
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            mark.draw(in: NSRect(
                x: rect.midX - mark.size.width / 2,
                y: rect.midY - mark.size.height / 2,
                width: mark.size.width,
                height: mark.size.height
            ))
            return true
        }
    }

    private static func glyphImage(symbolName: String) -> NSImage {
        let side = AskNugumiFloatingTargetPresentationPolicy.buttonSize
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return false }
            let target = NSRect(
                x: rect.midX - symbol.size.width / 2,
                y: rect.midY - symbol.size.height / 2,
                width: symbol.size.width,
                height: symbol.size.height
            )
            symbol.draw(in: target)
            // Template symbols draw as black; tint the drawn glyph white.
            NSColor.white.set()
            target.fill(using: .sourceAtop)
            return true
        }
    }

    @objc private func buttonTapped() {
        onClick?()
    }
}

