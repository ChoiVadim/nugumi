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

/// The translation result panel. Plain borderless `NSPanel` returns
/// `canBecomeKey == false`, so its text field (the follow-up input) could never
/// take focus. Overriding it — while keeping `becomesKeyOnlyIfNeeded` on the
/// instance — lets the field become key on click without the panel stealing key
/// the moment it appears (which would disrupt the source app's selection).
private final class TranslationResultPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command {
            switch event.charactersIgnoringModifiers {
            case "v":
                if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return true }
            case "c":
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
            case "x":
                if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) { return true }
            case "a":
                if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self) { return true }
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Somewhere other than a floating window for a result to appear.
///
/// A struct of closures rather than a protocol, for the same reason `DockItem`
/// is one: there is exactly one thing on the other end (a dock), and `NSView` is
/// all it needs. This is the seam that makes "where does the panel open" a
/// choice instead of a fact.
@MainActor
struct ResultSurfaceHost {
    let present: (NSView) -> Void
    let dismiss: () -> Void
}

final class TranslationPanelController {
    enum Side { case left, right }

    enum Anchor {
        // Click point with explicit side. .right = panel goes right of point
        // (default for LTR drags / unknown direction). .left = panel goes left
        // of point (used when user dragged right-to-left in non-AX apps).
        case point(NSPoint, panelSide: Side)
        case selection(NSRect)      // selection rect, NSScreen coords (bottom-left origin)
    }

    private static let sideGap: CGFloat = 10
    private static let edgeMargin: CGFloat = 16

    private let panel: NSPanel
    private let contentView: TranslationContentView
    private let anchor: Anchor
    private var activeRequestID = UUID()
    private var globalOutsideClickMonitor: Any?
    private var localOutsideClickMonitor: Any?
    /// Esc closes the panel whenever Gizmate receives the keystroke (e.g.
    /// right after an Ask Gizmate answer, when the prompt left Gizmate active).
    private var localEscapeKeyMonitor: Any?
    private var commandCopyInterceptor: CommandCopyInterceptor?
    private var returnKeyInterceptor: ReturnKeyInterceptor?
    private var didClose = false
    private var wasDismissedByUser = false
    private let onClose: (() -> Void)?
    /// Fires after `onClose` only when the user dismissed the panel (Esc, ✕,
    /// copy, outside click) — never on programmatic closes (panel replaced,
    /// Replace action, screenshot capture starting).
    var onUserDismiss: (() -> Void)?
    private let replaceShortcutSourcePID: pid_t?
    /// When false, a click outside the panel does NOT dismiss it — only the ✕
    /// button or Esc. The Ask Gizmate answer uses this so reading it isn't a
    /// one-misclick-away-from-gone affair.
    private let dismissesOnOutsideClick: Bool
    /// Non-nil when this result was routed to a dock. The panel is still built —
    /// it owns the content view, the interceptors and the request bookkeeping —
    /// but it is never ordered in, and the content lives on an edge instead.
    private let dockHost: ResultSurfaceHost?
    private var isDocked: Bool { dockHost != nil }

    var panelFrame: NSRect { panel.frame }
    var isVisible: Bool { panel.isVisible }
    var displayedResultText: String { contentView.currentResultText }
    var currentSourceText: String { contentView.currentSourceText }
    var currentTargetLanguageValue: TranslationLanguage { contentView.currentTargetLanguageValue }

    private let loadingPlaceholder: String

    init(
        anchor: Anchor,
        sourceText: String,
        targetLanguage: TranslationLanguage,
        resultLabel: String? = nil,
        loadingPlaceholder: String = "Thinking",
        showsSource: Bool = true,
        showsFollowUp: Bool = false,
        onTargetLanguageSelected: ((TranslationLanguage) -> Void)? = nil,
        onReplace: ((String) -> Void)? = nil,
        onFollowUp: ((String) -> Void)? = nil,
        replaceShortcutSourcePID: pid_t? = nil,
        dismissesOnOutsideClick: Bool = true,
        dockHost: ResultSurfaceHost? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.dockHost = dockHost
        self.loadingPlaceholder = loadingPlaceholder
        self.anchor = anchor
        self.onClose = onClose
        self.replaceShortcutSourcePID = replaceShortcutSourcePID
        self.dismissesOnOutsideClick = dismissesOnOutsideClick
        let referencePoint = Self.anchorReferencePoint(for: anchor)
        let visibleFrame = NSScreen.visibleFrame(containing: referencePoint)
        let panelHeight = min(
            TranslationContentView.preferredHeight(sourceText: sourceText, resultText: "\(loadingPlaceholder)...", showsSource: showsSource, showsFollowUp: showsFollowUp),
            visibleFrame.height - 32
        )
        let panelSize = NSSize(width: TranslationContentView.preferredWidth, height: panelHeight)
        let origin = Self.panelOrigin(anchor: anchor, panelSize: panelSize, visibleFrame: visibleFrame)
        let anchorY = TranslationContentView.anchorY(
            for: Self.anchorY(for: anchor),
            panelOriginY: origin.y,
            panelHeight: panelHeight
        )

        contentView = TranslationContentView(
            sourceText: sourceText,
            targetLanguage: targetLanguage,
            resultLabel: resultLabel,
            anchorY: anchorY,
            showsSource: showsSource,
            showsFollowUp: showsFollowUp,
            // On an edge the dock supplies the glass, the corners and the
            // width, so the content must not bring its own — see DESIGN.md,
            // "No glass inside glass".
            chromeless: dockHost != nil,
            onTargetLanguageSelected: onTargetLanguageSelected,
            onReplace: onReplace
        )
        contentView.onFollowUp = onFollowUp
        panel = TranslationResultPanel(
            contentRect: NSRect(origin: origin, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .gizmateOverlay
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        InvisibilityState.apply(to: panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        // Keeps the source app's text view key so the action buttons fire on
        // the first click. Without this, the panel grabs key on initial click
        // and the button-tap is swallowed by the activation.
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = contentView
        contentView.onClose = { [weak self] in self?.dismissByUser() }
        contentView.onNeedsResize = { [weak self] in
            self?.resizeToFitContent(animated: true)
        }
        // Resize only when a result actually renders (throttled), so streaming
        // doesn't shake the panel on every chunk.
        contentView.onResultRendered = { [weak self] in
            self?.resizeToFitContent(animated: false)
        }
        contentView.onFollowUpFocusChange = { [weak self] focused in
            // Only the rewrite panel installs an interceptor; nil elsewhere = no-op.
            focused ? self?.returnKeyInterceptor?.disable() : self?.returnKeyInterceptor?.enable()
        }
    }

    deinit {
        removeOutsideClickMonitors()
        removeCommandCopyInterceptor()
        removeReturnKeyInterceptor()
    }

    @discardableResult
    func showLoading(targetLanguage: TranslationLanguage? = nil, placeholder: String? = nil) -> UUID {
        activeRequestID = UUID()
        if let targetLanguage {
            contentView.setTargetLanguage(targetLanguage)
        }
        contentView.startLoadingAnimation(baseText: placeholder ?? loadingPlaceholder)
        if let dockHost {
            // The dock sizes and dismisses its own panel, so neither the
            // fit-to-content pass nor the outside-click monitors apply: an edge
            // that vanished on the first click elsewhere would be unusable.
            contentView.removeFromSuperview()
            dockHost.present(contentView)
        } else {
            resizeToFitContent(animated: false)
            panel.orderFrontRegardless()
            installOutsideClickMonitors()
        }
        installCommandCopyInterceptor()
        installReturnKeyInterceptor()
        return activeRequestID
    }

    func showTranslation(_ text: String, requestID: UUID? = nil, isFinal: Bool = false) {
        guard requestIsCurrent(requestID) else {
            return
        }

        // Partials render inline (stable while streaming); the final chunk
        // (isFinal) re-renders as block markdown — tables/headers/lists.
        contentView.setResult(text, isFinal: isFinal)
    }

    func showError(_ message: String, requestID: UUID? = nil) {
        guard requestIsCurrent(requestID) else {
            return
        }

        contentView.setError(message)
    }

    func close() {
        guard !didClose else {
            return
        }

        didClose = true
        contentView.stopLoadingAnimation()
        removeOutsideClickMonitors()
        removeCommandCopyInterceptor()
        removeReturnKeyInterceptor()
        if let dockHost {
            dockHost.dismiss()
        } else {
            panel.close()
        }
        onClose?()
        if wasDismissedByUser {
            onUserDismiss?()
        }
    }

    private func dismissByUser() {
        wasDismissedByUser = true
        close()
    }

    private func installOutsideClickMonitors() {
        if dismissesOnOutsideClick, globalOutsideClickMonitor == nil, localOutsideClickMonitor == nil {
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                self?.closeIfClickIsOutside(event)
            }

            localOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.closeIfClickIsOutside(event)
                return event
            }
        }

        guard localEscapeKeyMonitor == nil else { return }
        localEscapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.keyCode == UInt16(kVK_Escape),
                  self.panel.isVisible,
                  !self.contentView.isTargetLanguageMenuOpen
            else {
                return event
            }
            self.dismissByUser()
            return nil
        }
    }

    private func removeOutsideClickMonitors() {
        if let globalOutsideClickMonitor {
            NSEvent.removeMonitor(globalOutsideClickMonitor)
            self.globalOutsideClickMonitor = nil
        }

        if let localOutsideClickMonitor {
            NSEvent.removeMonitor(localOutsideClickMonitor)
            self.localOutsideClickMonitor = nil
        }

        if let localEscapeKeyMonitor {
            NSEvent.removeMonitor(localEscapeKeyMonitor)
            self.localEscapeKeyMonitor = nil
        }
    }

    private func installCommandCopyInterceptor() {
        guard commandCopyInterceptor == nil else {
            return
        }

        let interceptor = CommandCopyInterceptor { [weak self] in
            self?.copyResultAndClose()
        }
        commandCopyInterceptor = interceptor
        interceptor.enable()
    }

    private func removeCommandCopyInterceptor() {
        commandCopyInterceptor?.disable()
        commandCopyInterceptor = nil
    }

    private func installReturnKeyInterceptor() {
        guard returnKeyInterceptor == nil, let pid = replaceShortcutSourcePID else {
            return
        }

        let interceptor = ReturnKeyInterceptor(sourcePID: pid) { [weak self] in
            self?.triggerReplaceFromShortcut()
        }
        returnKeyInterceptor = interceptor
        interceptor.enable()
    }

    private func removeReturnKeyInterceptor() {
        returnKeyInterceptor?.disable()
        returnKeyInterceptor = nil
    }

    private func triggerReplaceFromShortcut() {
        guard panel.isVisible else { return }
        contentView.triggerReplaceProgrammatically()
    }

    private func copyResultAndClose() {
        guard panel.isVisible else {
            return
        }

        contentView.copyResultToPasteboard()
        dismissByUser()
    }

    private func closeIfClickIsOutside(_ event: NSEvent) {
        guard panel.isVisible else {
            return
        }

        guard !contentView.isTargetLanguageMenuOpen else {
            return
        }

        let screenPoint = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        guard !panel.frame.insetBy(dx: -4, dy: -4).contains(screenPoint) else {
            return
        }

        dismissByUser()
    }

    private func requestIsCurrent(_ requestID: UUID?) -> Bool {
        guard let requestID else {
            return true
        }

        return requestID == activeRequestID
    }

    private func resizeToFitContent(animated: Bool) {
        // A docked result is sized by the dock; resizing the hidden panel would
        // fight it and move nothing the user can see.
        guard !isDocked else { return }
        let currentFrame = panel.frame
        if TranslationContentView.streamDebug {
            print(String(format: "[stream] resize curH=%.1f curY=%.1f", currentFrame.height, currentFrame.minY))
        }
        let visibleFrame = NSScreen.visibleFrame(containing: NSPoint(x: currentFrame.midX, y: currentFrame.midY))
        let targetHeight = min(contentView.preferredHeightForCurrentContent(), visibleFrame.height - 32)
        let targetWidth = TranslationContentView.preferredWidth
        let preserveCurrentPosition = panel.isVisible
        let targetSize = NSSize(width: targetWidth, height: targetHeight)

        let targetOrigin: NSPoint
        if preserveCurrentPosition {
            // Resize-in-place: preserve top edge (panel.maxY) and X. Works
            // identically for both .point and .selection anchors.
            let preservedY = min(
                max(currentFrame.maxY - targetHeight, visibleFrame.minY + Self.edgeMargin),
                visibleFrame.maxY - targetHeight - Self.edgeMargin
            )
            let preservedX = min(
                max(currentFrame.minX, visibleFrame.minX + Self.edgeMargin),
                visibleFrame.maxX - targetWidth - Self.edgeMargin
            )
            targetOrigin = NSPoint(x: preservedX, y: preservedY)
        } else {
            targetOrigin = Self.panelOrigin(
                anchor: anchor,
                panelSize: targetSize,
                visibleFrame: visibleFrame
            )
        }

        let targetAnchorY = TranslationContentView.anchorY(
            for: Self.anchorY(for: anchor),
            panelOriginY: targetOrigin.y,
            panelHeight: targetHeight
        )
        contentView.setAnchorY(targetAnchorY)

        let targetFrame = NSRect(
            x: targetOrigin.x,
            y: targetOrigin.y,
            width: targetWidth,
            height: targetHeight
        )

        let frameUnchanged = abs(targetFrame.minX - currentFrame.minX) < 0.5
            && abs(targetFrame.minY - currentFrame.minY) < 0.5
            && abs(targetFrame.width - currentFrame.width) < 0.5
            && abs(targetFrame.height - currentFrame.height) < 0.5
        if frameUnchanged {
            contentView.layoutForCurrentSize()
            return
        }

        let heightDelta = abs(targetFrame.height - currentFrame.height)
        if !animated || heightDelta < 1.5 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            panel.setFrame(targetFrame, display: true)
            CATransaction.commit()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    private static func anchorReferencePoint(for anchor: Anchor) -> NSPoint {
        switch anchor {
        case .point(let p, _):    return p
        case .selection(let r):   return NSPoint(x: r.midX, y: r.midY)
        }
    }

    private static func anchorY(for anchor: Anchor) -> CGFloat {
        switch anchor {
        case .point(let p, _):    return p.y
        case .selection(let r):   return r.midY
        }
    }

    private static func panelOrigin(
        anchor: Anchor,
        panelSize: NSSize,
        visibleFrame: NSRect
    ) -> NSPoint {
        switch anchor {
        case .point(let p, let panelSide):
            // X depends on which side we want the panel relative to the point.
            // .right is the historical default (panel goes right of click point);
            // .left is used when the user dragged RTL so the panel flips to the
            // left to avoid overlapping the selection in non-AX apps.
            let desiredX: CGFloat
            switch panelSide {
            case .right: desiredX = p.x + sideGap
            case .left:  desiredX = p.x - sideGap - panelSize.width
            }
            let desiredY = p.y - panelSize.height * 0.52
            let clampedX = min(max(desiredX, visibleFrame.minX + edgeMargin),
                               visibleFrame.maxX - panelSize.width - edgeMargin)
            let clampedY = min(max(desiredY, visibleFrame.minY + edgeMargin),
                               visibleFrame.maxY - panelSize.height - edgeMargin)
            return NSPoint(x: clampedX, y: clampedY)

        case .selection(let sel):
            // Prefer right of the selection; fall back to left; if neither side
            // fits, gracefully degrade to .point at the selection center.
            let rightX = sel.maxX + sideGap
            let leftX  = sel.minX - sideGap - panelSize.width
            let rightFits = rightX + panelSize.width <= visibleFrame.maxX - edgeMargin
            let leftFits  = leftX >= visibleFrame.minX + edgeMargin

            let chosenX: CGFloat
            if rightFits {
                chosenX = rightX
            } else if leftFits {
                chosenX = leftX
            } else {
                return panelOrigin(
                    anchor: .point(NSPoint(x: sel.midX, y: sel.midY), panelSide: .right),
                    panelSize: panelSize,
                    visibleFrame: visibleFrame
                )
            }

            // Center-align: panel.midY lines up with sel.midY (vertical center of
            // the selection). Clamp inside the visible frame so a tall panel beside
            // a short selection doesn't escape the screen.
            let desiredY = sel.midY - panelSize.height / 2
            let clampedY = min(max(desiredY, visibleFrame.minY + edgeMargin),
                               visibleFrame.maxY - panelSize.height - edgeMargin)
            let clampedX = min(max(chosenX, visibleFrame.minX + edgeMargin),
                               visibleFrame.maxX - panelSize.width - edgeMargin)
            return NSPoint(x: clampedX, y: clampedY)
        }
    }
}

