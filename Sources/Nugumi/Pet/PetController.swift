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

private final class PetPanel: NSPanel {
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

enum NugumiFont {
    private static let didRegisterPixelifySans: Bool = {
        guard let url = Bundle.module.url(
            forResource: "PixelifySans",
            withExtension: "ttf",
            subdirectory: "Fonts"
        ) else {
            return false
        }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    static func pixelPrompt(size: CGFloat) -> NSFont {
        _ = didRegisterPixelifySans
        return NSFont(name: "PixelifySans-Regular_SemiBold", size: size)
            ?? NSFont(name: "Pixelify Sans", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
    }
}

private final class PetPromptBubbleView: NSView {
    var isError = false {
        didSet { needsDisplay = true }
    }
    var bubbleFrame: NSRect = .zero {
        didSet { needsDisplay = true }
    }

    /// When set, the bubble becomes a drag handle: clicks on the bubble
    /// background (areas not covered by text or buttons) start a drag that
    /// the closure handles. The closure receives the initial screen-space
    /// mouse location captured at mouseDown so the drag anchor is precise.
    /// Text selection and button clicks still work because their views sit
    /// above this view in z-order and AppKit asks them first.
    var onDragRequested: ((NSPoint) -> Void)?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Opt-in: stay click-through (current behavior) unless a drag handler
        // is wired in.
        guard onDragRequested != nil else { return nil }
        return bounds.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if onDragRequested != nil {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let onDragRequested else {
            super.mouseDown(with: event)
            return
        }
        let startLocation = NSEvent.mouseLocation
        NSCursor.closedHand.push()
        onDragRequested(startLocation)
        NSCursor.pop()
    }

    override func draw(_ dirtyRect: NSRect) {
        let context = NSGraphicsContext.current
        let previousAntialiasing = context?.shouldAntialias
        context?.shouldAntialias = false
        defer {
            if let previousAntialiasing {
                context?.shouldAntialias = previousAntialiasing
            }
        }

        let unit: CGFloat = 3
        let drawingFrame = bubbleFrame == .zero ? bounds : bubbleFrame
        let bubbleRect = NSRect(
            x: drawingFrame.minX + 5 * unit,
            y: drawingFrame.minY + 3 * unit,
            width: floor((drawingFrame.width - 10 * unit) / unit) * unit,
            height: floor((drawingFrame.height - 7 * unit) / unit) * unit
        )

        let shadow = NSColor(calibratedWhite: 0.0, alpha: 0.22)
        let fill = NSColor(srgbRed: 0.95, green: 0.96, blue: 0.91, alpha: 1.0)
        let highlight = NSColor(calibratedWhite: 1.0, alpha: 0.55)
        let border = isError
            ? NSColor(srgbRed: 0.93, green: 0.23, blue: 0.23, alpha: 1.0)
            : NSColor(srgbRed: 0.42, green: 0.47, blue: 0.47, alpha: 1.0)
        let borderDark = isError
            ? NSColor(srgbRed: 0.54, green: 0.08, blue: 0.08, alpha: 1.0)
            : NSColor(srgbRed: 0.22, green: 0.27, blue: 0.28, alpha: 1.0)

        drawPixelBubbleBody(in: bubbleRect.offsetBy(dx: unit, dy: -unit), unit: unit, color: shadow)
        let tailAnchor = bubbleRect.minX + 4 * unit
        drawPixelTail(anchor: tailAnchor, baseY: bubbleRect.minY, unit: unit, color: shadow, offset: NSPoint(x: unit, y: -unit))
        drawPixelTail(anchor: tailAnchor, baseY: bubbleRect.minY, unit: unit, color: borderDark)
        drawPixelBubbleBody(in: bubbleRect, unit: unit, color: borderDark)
        drawPixelBubbleBody(in: bubbleRect.insetBy(dx: unit, dy: unit), unit: unit, color: border)
        drawPixelBubbleBody(in: bubbleRect.insetBy(dx: unit * 2, dy: unit * 2), unit: unit, color: fill)

        drawPixelTail(anchor: tailAnchor, baseY: bubbleRect.minY, unit: unit, color: fill, offset: NSPoint(x: unit * 2, y: unit * 2))

        highlight.setFill()
        NSBezierPath(rect: NSRect(
            x: bubbleRect.minX + 4 * unit,
            y: bubbleRect.maxY - 4 * unit,
            width: bubbleRect.width - 8 * unit,
            height: unit
        )).fill()
    }

    private func drawPixelBubbleBody(in rect: NSRect, unit: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(rect: NSRect(
            x: rect.minX + unit,
            y: rect.minY,
            width: rect.width - unit * 2,
            height: rect.height
        )).fill()
        NSBezierPath(rect: NSRect(
            x: rect.minX,
            y: rect.minY + unit,
            width: rect.width,
            height: rect.height - unit * 2
        )).fill()
    }

    private func drawPixelTail(anchor: CGFloat, baseY: CGFloat, unit: CGFloat, color: NSColor, offset: NSPoint = .zero) {
        color.setFill()
        let cells: [(CGFloat, CGFloat, CGFloat)] = [
            (0, 0, 7),
            (1, -1, 5),
            (2, -2, 3),
            (3, -3, 1)
        ]
        for (x, y, width) in cells {
            NSBezierPath(rect: NSRect(
                x: anchor + offset.x + x * unit,
                y: baseY + offset.y + y * unit,
                width: width * unit,
                height: unit
            )).fill()
        }
    }
}

@MainActor
final class PetController: NSObject, NSTextFieldDelegate {
    private let panel: NSPanel
    private let containerView: NSView
    private let promptPanel: NSPanel
    private let promptContainerView: NSView
    private let petView: PetMascotView
    private let appIconView: NSImageView
    private let promptBubbleView: PetPromptBubbleView
    private let promptTextField: AskPromptTextField
    private let answerScrollView: NSScrollView
    private let answerTextView: NSTextView
    private let continueButton = NSButton()
    private var workspaceObserver: NSObjectProtocol?
    private var trackingTimer: Timer?
    private var throwTimer: Timer?
    private var throwVelocity: NSPoint = .zero
    private var onAsk: (() -> Void)?
    private var radialMenu: RadialActionMenuController?
    private var selectedText: String?
    private var onTranslate: ((String) -> Void)?
    private var onRewrite: ((String) -> Void)?
    private var onSmartReply: ((String) -> Void)?
    private var onScreenshot: (() -> Void)?
    private var onLive: (() -> Void)?
    private var onDictate: (() -> Void)?
    private var summarizeOption: RingSummarizeOption?
    private var onPromptSubmit: ((String) -> Void)?
    private var onPromptClose: (() -> Void)?
    var onContinue: (() -> Void)?
    /// Fires when the user dismisses an open ANSWER bubble themselves (click
    /// on the pet, double-click, or Escape) — `onPromptClose` is nilled out
    /// by `showAnswer`, so this is the only signal the app delegate gets for
    /// that gesture. Used to tear down UI the delegate layered on top of the
    /// answer (e.g. the Ask annotation overlay), which PetController has no
    /// reference to itself.
    var onAnswerDismissedByUser: (() -> Void)?
    private var currentMode: TranslationMode
    private var isReadyLockedUntilPanelCloses = false
    private var isThinking = false
    private var isPromptOpen = false
    private var isPromptLoading = false
    private var isAnswerOpen = false
    /// Catches Esc while the answer bubble (or the loading state) is up.
    /// The prompt text field handles Esc itself while typing, but it is
    /// hidden/disabled in those two states, so without this monitor Esc
    /// has no responder and the bubble can only be closed with the mouse.
    private var escapeKeyMonitor: Any?
    private var promptBuffer = ""
    private var currentPromptInputLayout = AskNugumiPromptInputMetrics.layout(forContentHeight: 0)
    private var currentAnswerLayout = AskNugumiAnswerBubbleMetrics.layout(forContentHeight: 0)
    private var pointingTarget: NSPoint?
    private var pointingReturnTimer: Timer?
    private var lastCursorLocation = NSEvent.mouseLocation
    private var lastCursorMovementDate = Date.distantPast
    private var cursorOffset = PetController.defaultCursorOffset
    /// Exponentially-smoothed per-frame cursor velocity. The trailing side
    /// commits off this smoothed vector instead of per-frame movement, so
    /// sub-pixel tremor and tiny zig-zags can't flip the pet left/right every
    /// tick. Reset implicitly via decay when the cursor stops.
    private var smoothedCursorVelocity: NSPoint = .zero
    private var isReadyState: Bool {
        selectedText != nil || isReadyLockedUntilPanelCloses
    }

    private static let mascotSize = NSSize(width: 42, height: 34)
    private static let appIconSize = NSSize(width: 13, height: 13)
    private static let panelPadding: CGFloat = 6
    private static let panelSize = NSSize(
        width: mascotSize.width + panelPadding * 2,
        height: mascotSize.height + panelPadding * 2
    )
    private static let answerFontSize: CGFloat = 14
    private static let edgeMargin: CGFloat = 6
    private static let pointingArrivalThreshold: CGFloat = 8
    private static let textMovementUserInfoKey = "NSTextMovement"
    private static let promptPlaceholder = "Hey, need me?"
    private static let defaultCursorOffset = NSPoint(
        x: 12 - panelPadding,
        y: -mascotSize.height - 8 - panelPadding
    )

    var isPromptVisible: Bool {
        isPromptOpen || isPromptLoading || isAnswerOpen
    }

    var isPromptComposingVisible: Bool {
        isPromptOpen || isPromptLoading
    }

    init(initialMode: TranslationMode) {
        currentMode = initialMode
        let origin = PetController.originNearCursor(
            for: NSEvent.mouseLocation,
            size: Self.panelSize,
            offset: cursorOffset
        )
        panel = PetPanel(
            contentRect: NSRect(origin: origin, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        containerView = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
        let initialPromptInputLayout = AskNugumiPromptInputMetrics.layout(forContentHeight: 0)
        promptPanel = PetPanel(
            contentRect: NSRect(origin: origin, size: initialPromptInputLayout.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        promptContainerView = NSView(frame: NSRect(origin: .zero, size: initialPromptInputLayout.panelSize))
        petView = PetMascotView(frame: NSRect(
            origin: .zero,
            size: Self.panelSize
        ))
        appIconView = NSImageView(frame: NSRect(
            x: Self.panelSize.width - Self.appIconSize.width,
            y: Self.panelSize.height - Self.appIconSize.height,
            width: Self.appIconSize.width,
            height: Self.appIconSize.height
        ))
        promptBubbleView = PetPromptBubbleView(frame: initialPromptInputLayout.bubbleFrame)
        promptTextField = AskPromptTextField(frame: initialPromptInputLayout.textFrame)
        let initialAnswerLayout = AskNugumiAnswerBubbleMetrics.layout(forContentHeight: 0)
        answerScrollView = NSScrollView(frame: initialAnswerLayout.viewportFrame)
        answerTextView = NSTextView(frame: NSRect(
            origin: .zero,
            size: initialAnswerLayout.viewportFrame.size
        ))

        super.init()

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        InvisibilityState.apply(to: panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true

        promptPanel.level = .floating
        promptPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        InvisibilityState.apply(to: promptPanel)
        promptPanel.isReleasedWhenClosed = false
        promptPanel.isOpaque = false
        promptPanel.backgroundColor = .clear
        promptPanel.hasShadow = false
        promptPanel.hidesOnDeactivate = false
        promptPanel.ignoresMouseEvents = false

        containerView.autoresizingMask = [.width, .height]
        promptContainerView.autoresizingMask = [.width, .height]
        petView.wantsLayer = true
        petView.layer?.shadowColor = NSColor.black.cgColor
        petView.layer?.shadowOpacity = 0.32
        petView.layer?.shadowRadius = 3
        petView.layer?.shadowOffset = .zero
        petView.layer?.masksToBounds = false
        containerView.addSubview(petView)

        appIconView.imageScaling = .scaleProportionallyDown
        appIconView.isHidden = true
        containerView.addSubview(appIconView)

        promptBubbleView.alphaValue = 0
        promptBubbleView.isHidden = true
        promptContainerView.addSubview(promptBubbleView)

        promptBubbleView.onDragRequested = { [weak self] startLocation in
            self?.beginBubbleDrag(initialMouseLocation: startLocation)
        }

        promptTextField.delegate = self
        promptTextField.onEscape = { [weak self] in
            self?.closePromptFromUser()
        }
        promptTextField.font = NugumiFont.pixelPrompt(size: 16)
        promptTextField.textColor = NSColor(srgbRed: 0.26, green: 0.30, blue: 0.30, alpha: 1.0)
        promptTextField.isBordered = false
        promptTextField.isBezeled = false
        promptTextField.drawsBackground = false
        promptTextField.backgroundColor = .clear
        promptTextField.focusRingType = .none
        promptTextField.isEditable = false
        promptTextField.isSelectable = false
        configurePromptTextFieldForInput()
        promptTextField.alphaValue = 0
        promptTextField.isHidden = true
        setPromptPlaceholder(Self.promptPlaceholder)
        promptContainerView.addSubview(promptTextField)

        answerTextView.font = NugumiFont.pixelPrompt(size: Self.answerFontSize)
        answerTextView.textColor = NSColor(srgbRed: 0.26, green: 0.30, blue: 0.30, alpha: 1.0)
        answerTextView.drawsBackground = false
        answerTextView.backgroundColor = .clear
        answerTextView.isEditable = false
        answerTextView.isSelectable = true
        answerTextView.isRichText = false
        answerTextView.importsGraphics = false
        answerTextView.isHorizontallyResizable = false
        answerTextView.isVerticallyResizable = true
        answerTextView.textContainerInset = .zero
        answerTextView.textContainer?.lineFragmentPadding = 0
        answerTextView.textContainer?.widthTracksTextView = true
        answerTextView.textContainer?.heightTracksTextView = false

        answerScrollView.borderType = .noBorder
        answerScrollView.drawsBackground = false
        answerScrollView.hasHorizontalScroller = false
        answerScrollView.hasVerticalScroller = false
        answerScrollView.autohidesScrollers = true
        answerScrollView.scrollerStyle = .overlay
        answerScrollView.alphaValue = 0
        answerScrollView.isHidden = true
        answerScrollView.documentView = answerTextView
        promptContainerView.addSubview(answerScrollView)

        // "Continue dialog" affordance, bottom-right of the answer bubble.
        continueButton.isBordered = false
        continueButton.bezelStyle = .regularSquare
        continueButton.imagePosition = .imageOnly
        continueButton.image = NSImage(
            systemSymbolName: "arrowshape.turn.up.left.circle.fill",
            accessibilityDescription: "Continue conversation"
        )
        continueButton.contentTintColor = .nugumiAccent
        continueButton.toolTip = "Continue the conversation"
        continueButton.target = self
        continueButton.action = #selector(continueButtonTapped)
        continueButton.isHidden = true
        continueButton.alphaValue = 0
        promptContainerView.addSubview(continueButton)

        panel.contentView = containerView
        promptPanel.contentView = promptContainerView
        petView.onClick = { [weak self] in
            guard let self else { return }
            if self.isPromptVisible || self.onPromptClose != nil {
                self.closePromptFromUser()
                return
            }
            self.toggleRadialMenu()
        }

        refreshStyleBadge()
        subscribeToFrontmostAppChanges()
        installEscapeKeyMonitor()
    }

    private func installEscapeKeyMonitor() {
        guard escapeKeyMonitor == nil else { return }
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.keyCode == UInt16(kVK_Escape),
                  self.isAnswerOpen || self.isPromptLoading
            else {
                return event
            }
            self.closePromptFromUser()
            return nil
        }
    }

    private func removeEscapeKeyMonitor() {
        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
            self.escapeKeyMonitor = nil
        }
    }

    private func subscribeToFrontmostAppChanges() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshStyleBadge()
            }
        }
    }

    /// Dresses the pet in the writing register Nugumi will use for the frontmost app
    /// (formal = hat + mustache, casual = cap, polite = bare). Uses the app-based
    /// category only — deliberately not the AppleScript URL read — so passively
    /// switching apps never triggers an Automation prompt. The legacy corner badge
    /// view stays hidden.
    private func refreshStyleBadge() {
        appIconView.isHidden = true
        guard let runningApp = NSWorkspace.shared.frontmostApplication,
              runningApp.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return // keep the last register while Nugumi itself is frontmost
        }
        let category = AppCategoryClassifier.category(for: runningApp.bundleIdentifier)
        petView.setWritingStyle(WritingStyle.resolved(for: category))
    }

    func show() {
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        startTracking()
    }

    func close() {
        radialMenu?.close()
        radialMenu = nil
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        removeEscapeKeyMonitor()
        clearPrompt(animate: false)
        clearReady()
        trackingTimer?.invalidate()
        trackingTimer = nil
        cancelPointingAnimation()
        panel.close()
        promptPanel.close()
    }

    func showPrompt(
        onSubmit: @escaping (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        radialMenu?.close()
        radialMenu = nil
        cancelPointingAnimation()
        selectedText = nil
        self.onTranslate = nil
        self.onRewrite = nil
        self.onSmartReply = nil
        self.onAsk = nil
        summarizeOption = nil
        onPromptSubmit = onSubmit
        onPromptClose = onClose
        currentMode = .draftMessage
        isReadyLockedUntilPanelCloses = false
        isThinking = false
        isPromptOpen = true
        isPromptLoading = false
        isAnswerOpen = false
        panel.ignoresMouseEvents = false
        petView.allowsClickWhenNotReady = true
        appIconView.isHidden = true
        petView.apply(state: .idle, mode: currentMode)

        promptBuffer = ""
        promptTextField.isEnabled = true
        configurePromptTextFieldForInput()
        renderPromptText()
        promptBubbleView.isError = false
        setPromptPlaceholder(Self.promptPlaceholder)
        let presentation = promptPresentationAnchoredToPet(
            size: currentPromptInputLayout.panelSize,
            bubbleFrame: currentPromptInputLayout.bubbleFrame
        )
        panel.setFrameOrigin(presentation.petOrigin)
        promptPanel.setFrame(presentation.promptFrame, display: true)
        showPromptViews()
        promptPanel.alphaValue = 1
        show()
        promptPanel.orderFrontRegardless()
        focusPromptField()
        petView.onDoubleClick = { [weak self] in
            self?.closePromptFromUser()
        }
        petView.onDragRequested = { [weak self] startLocation in
            self?.beginBubbleDrag(initialMouseLocation: startLocation)
        }
    }

    func focusPrompt() {
        guard isPromptOpen else { return }
        promptPanel.orderFrontRegardless()
    }

    func setPromptLoading() {
        guard isPromptOpen else {
            showThinking()
            return
        }

        isPromptOpen = false
        isPromptLoading = true
        isAnswerOpen = false
        isThinking = true
        promptTextField.isEnabled = false
        panel.ignoresMouseEvents = false
        petView.allowsClickWhenNotReady = true
        petView.apply(state: .thinking, mode: currentMode)
        petView.onDragRequested = { [weak self] startLocation in
            self?.beginPetThrowDrag(initialMouseLocation: startLocation)
        }
        let targetFrame = panel.frame

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            promptPanel.animator().setFrame(targetFrame, display: true)
            promptPanel.animator().alphaValue = 0
            promptBubbleView.animator().alphaValue = 0
            promptTextField.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isPromptLoading else { return }
                self.promptBubbleView.isHidden = true
                self.promptTextField.isHidden = true
                self.promptPanel.orderOut(nil)
                self.promptPanel.alphaValue = 1
            }
        }
    }

    func showPromptError(_ message: String) {
        guard isPromptVisible || onPromptSubmit != nil else { return }

        isPromptOpen = true
        isPromptLoading = false
        isAnswerOpen = false
        isThinking = false
        panel.ignoresMouseEvents = false
        petView.allowsClickWhenNotReady = true
        promptTextField.isEnabled = true
        configurePromptTextFieldForInput()
        promptBubbleView.isError = true
        setPromptPlaceholder(message)
        petView.apply(state: .idle, mode: currentMode)
        refreshPromptInputLayout()
        let presentation = promptPresentationAnchoredToPet(
            size: currentPromptInputLayout.panelSize,
            bubbleFrame: currentPromptInputLayout.bubbleFrame
        )
        panel.setFrameOrigin(presentation.petOrigin)
        promptPanel.setFrame(presentation.promptFrame, display: true)
        showPromptViews()
        promptPanel.alphaValue = 1
        show()
        focusPrompt()
        focusPromptField()
        petView.onDoubleClick = { [weak self] in
            self?.closePromptFromUser()
        }
        petView.onDragRequested = { [weak self] startLocation in
            self?.beginBubbleDrag(initialMouseLocation: startLocation)
        }
    }

    func clearPrompt() {
        clearPrompt(animate: true)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard textMovement(from: notification) == NSTextMovement.return.rawValue else {
            return
        }
        submitPrompt()
    }

    /// Shift+Enter inserts a line break instead of submitting. AppKit binds
    /// Enter to `insertNewline:` and dispatches it through this delegate
    /// callback before ending editing — checking the current event's modifier
    /// lets us swap the behavior at the point of interception.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === promptTextField,
              commandSelector == #selector(NSResponder.insertNewline(_:)),
              NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        else {
            return false
        }
        textView.insertNewlineIgnoringFieldEditor(self)
        return true
    }

    func showAnswer(_ message: String, emotion: AskNugumiEmotion?) {
        radialMenu?.close()
        radialMenu = nil
        let cleanMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanMessage.isEmpty else { return }

        cancelPointingAnimation()
        selectedText = nil
        onTranslate = nil
        onRewrite = nil
        onSmartReply = nil
        onAsk = nil
        summarizeOption = nil
        onPromptSubmit = nil
        onPromptClose = nil
        isReadyLockedUntilPanelCloses = false
        isThinking = false
        isPromptOpen = false
        isPromptLoading = false
        isAnswerOpen = true
        promptBuffer = ""

        panel.ignoresMouseEvents = false
        petView.allowsClickWhenNotReady = true
        appIconView.isHidden = true
        promptBubbleView.isError = false
        configureAnswerTextView(with: cleanMessage)

        let presentation = promptPresentationAnchoredToPet(
            size: currentAnswerLayout.panelSize,
            bubbleFrame: currentAnswerLayout.bubbleFrame
        )
        panel.setFrameOrigin(presentation.petOrigin)
        promptPanel.setFrame(presentation.promptFrame, display: true)
        showPromptViews()
        promptPanel.alphaValue = 1
        show()
        promptPanel.orderFrontRegardless()
        panel.orderFrontRegardless()
        petView.apply(state: .talking, mode: currentMode, emotion: .neutral)
        petView.onDoubleClick = { [weak self] in
            self?.closePromptFromUser()
        }
        petView.onDragRequested = { [weak self] startLocation in
            self?.beginBubbleDrag(initialMouseLocation: startLocation)
        }
    }

    private func submitPrompt() {
        guard isPromptOpen, promptTextField.isEnabled else { return }
        let text = promptBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            renderPromptText()
            return
        }
        onPromptSubmit?(text)
    }

    private func closePromptFromUser() {
        guard isPromptVisible else { return }
        let onClose = onPromptClose
        let wasAnswerOpen = isAnswerOpen
        clearPrompt(animate: true)
        onClose?()
        if wasAnswerOpen {
            onAnswerDismissedByUser?()
        }
    }

    private func clearPrompt(animate: Bool) {
        guard isPromptVisible || onPromptSubmit != nil || onPromptClose != nil else { return }
        stopThrow()
        isPromptOpen = false
        isPromptLoading = false
        isAnswerOpen = false
        onPromptSubmit = nil
        onPromptClose = nil
        promptBuffer = ""
        renderPromptText()
        promptTextField.isEnabled = true
        promptBubbleView.isError = false
        setPromptPlaceholder(Self.promptPlaceholder)
        hidePromptViews()
        promptPanel.orderOut(nil)
        promptPanel.alphaValue = 1
        // Drag + double-click are only active while Ask is visible. Drop the
        // callbacks so the pet goes back to its plain click-to-act behavior
        // when the user is just hovering it on idle.
        petView.onDoubleClick = nil
        petView.onDragRequested = nil
        if !isThinking {
            panel.ignoresMouseEvents = true
            petView.allowsClickWhenNotReady = false
            petView.apply(state: .idle, mode: currentMode, emotion: .neutral)
            refreshStyleBadge()
        }
    }

    private func showPromptViews() {
        layoutPromptSubviews()
        promptBubbleView.isHidden = false
        promptBubbleView.alphaValue = 1
        if isAnswerOpen {
            promptTextField.alphaValue = 0
            promptTextField.isHidden = true
            answerScrollView.isHidden = false
            answerScrollView.alphaValue = 1
            continueButton.isHidden = (onContinue == nil)
            continueButton.alphaValue = (onContinue == nil) ? 0 : 1
        } else {
            answerScrollView.alphaValue = 0
            answerScrollView.isHidden = true
            promptTextField.isHidden = false
            promptTextField.alphaValue = 1
            continueButton.isHidden = true
            continueButton.alphaValue = 0
        }
    }

    private func hidePromptViews() {
        promptBubbleView.alphaValue = 0
        promptTextField.alphaValue = 0
        answerScrollView.alphaValue = 0
        promptBubbleView.isHidden = true
        promptTextField.isHidden = true
        answerScrollView.isHidden = true
        continueButton.isHidden = true
        continueButton.alphaValue = 0
    }

    @objc private func continueButtonTapped() {
        onContinue?()
    }

    private func configurePromptTextFieldForInput() {
        promptTextField.font = NugumiFont.pixelPrompt(size: AskNugumiPromptInputMetrics.fontSize)
        promptTextField.usesSingleLineMode = false
        promptTextField.maximumNumberOfLines = 0
        promptTextField.cell?.wraps = true
        promptTextField.cell?.isScrollable = false
        promptTextField.cell?.lineBreakMode = .byWordWrapping
        promptTextField.isEditable = true
        promptTextField.isSelectable = true
    }

    private func configureAnswerTextView(with message: String) {
        let contentHeight = answerContentHeight(for: message)
        currentAnswerLayout = AskNugumiAnswerBubbleMetrics.layout(forContentHeight: contentHeight)
        let layout = currentAnswerLayout
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NugumiFont.pixelPrompt(size: Self.answerFontSize),
            .foregroundColor: NSColor(srgbRed: 0.26, green: 0.30, blue: 0.30, alpha: 1.0),
            .paragraphStyle: paragraphStyle
        ]
        answerTextView.textStorage?.setAttributedString(NSAttributedString(
            string: message,
            attributes: attributes
        ))
        answerTextView.font = NugumiFont.pixelPrompt(size: Self.answerFontSize)
        answerTextView.textColor = NSColor(srgbRed: 0.26, green: 0.30, blue: 0.30, alpha: 1.0)
        // Only carve out a lane for the overlay scroller when it's actually
        // shown. The text view stays full-width (so the clip view fills the
        // bubble); the container wraps ~14px short so glyphs never sit under
        // the scrollbar, with no wasted space when there's no scroll.
        let scrollerGutter: CGFloat = layout.needsScroll ? 14 : 0
        answerTextView.textContainer?.widthTracksTextView = false
        answerTextView.textContainer?.containerSize = NSSize(
            width: layout.viewportFrame.width - scrollerGutter,
            height: .greatestFiniteMagnitude
        )
        answerTextView.frame = NSRect(
            origin: .zero,
            size: NSSize(
                width: layout.viewportFrame.width,
                height: layout.documentHeight
            )
        )
        answerScrollView.hasVerticalScroller = layout.needsScroll
        answerScrollView.autohidesScrollers = !layout.needsScroll
        answerTextView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    private func answerContentHeight(for message: String) -> CGFloat {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NugumiFont.pixelPrompt(size: Self.answerFontSize),
            .paragraphStyle: paragraphStyle
        ]
        let boundingRect = (message as NSString).boundingRect(
            with: NSSize(
                width: AskNugumiAnswerBubbleMetrics.layout(forContentHeight: 0).viewportFrame.width,
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        return ceil(boundingRect.height) + 4
    }

    private func setPromptPlaceholder(_ text: String) {
        promptTextField.placeholderString = text
        promptTextField.placeholderAttributedString = NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: promptBubbleView.isError
                    ? NSColor(srgbRed: 0.78, green: 0.18, blue: 0.18, alpha: 0.78)
                    : NSColor(srgbRed: 0.27, green: 0.31, blue: 0.33, alpha: 0.62),
                .font: promptTextField.font ?? NugumiFont.pixelPrompt(size: 16)
            ]
        )
    }

    private func renderPromptText() {
        promptTextField.stringValue = promptBuffer
        refreshPromptInputLayout()
    }

    private func refreshPromptInputLayout() {
        currentPromptInputLayout = AskNugumiPromptInputMetrics.layout(
            forContentHeight: promptInputContentHeight(for: promptBuffer)
        )
        guard isPromptOpen, !isAnswerOpen else { return }
        let presentation = promptPresentationAnchoredToPet(
            size: currentPromptInputLayout.panelSize,
            bubbleFrame: currentPromptInputLayout.bubbleFrame
        )
        panel.setFrameOrigin(presentation.petOrigin)
        promptPanel.setFrame(presentation.promptFrame, display: true)
        layoutPromptSubviews()
    }

    private func promptInputContentHeight(for text: String) -> CGFloat {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NugumiFont.pixelPrompt(size: AskNugumiPromptInputMetrics.fontSize),
            .paragraphStyle: paragraphStyle
        ]
        let measurementSize = NSSize(
            width: AskNugumiPromptInputMetrics.textMeasurementWidth,
            height: .greatestFiniteMagnitude
        )
        let measure: (String) -> CGFloat = { sample in
            (sample as NSString).boundingRect(
                with: measurementSize,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes
            ).height
        }
        // Floor the bubble height at the placeholder's measured height so the
        // dialog never shrinks below the "empty state" size when a single
        // short word is typed. Lets the bubble still grow for longer input.
        // Measure the placeholder actually on screen, not the default one —
        // showPromptError swaps in the (often longer) error message.
        let placeholder = promptTextField.placeholderString ?? Self.promptPlaceholder
        let rawHeight = text.isEmpty ? measure(placeholder) : max(measure(text), measure(placeholder))
        return ceil(rawHeight) + AskNugumiPromptInputMetrics.textMeasurementBottomInset
    }

    /// Give the prompt's native NSTextField keyboard focus so the blinking
    /// caret appears. The panel becomes key without activating Nugumi
    /// (`.nonactivatingPanel` on promptPanel) — other apps stay active and
    /// keep receiving keystrokes when the user clicks back into them.
    private func focusPromptField() {
        promptPanel.makeKeyAndOrderFront(nil)
        promptPanel.makeFirstResponder(promptTextField)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as AnyObject) === promptTextField else { return }
        promptBuffer = promptTextField.stringValue
        if !promptBuffer.isEmpty {
            promptBubbleView.isError = false
            setPromptPlaceholder(Self.promptPlaceholder)
        }
        refreshPromptInputLayout()
    }

    private func textMovement(from notification: Notification) -> Int? {
        notification.userInfo?[Self.textMovementUserInfoKey] as? Int
    }

    private func promptPresentationAnchoredToPet(
        size: NSSize,
        bubbleFrame: NSRect
    ) -> (promptFrame: NSRect, petOrigin: NSPoint) {
        let referencePoint = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let visibleFrame = NSScreen.visibleFrame(containing: referencePoint)
        let presentation = AskNugumiPetBubblePresentationMetrics.presentation(
            petOrigin: panel.frame.origin,
            petSize: Self.panelSize,
            promptSize: size,
            bubbleFrame: bubbleFrame,
            visibleFrame: visibleFrame,
            edgeMargin: Self.edgeMargin
        )

        return (presentation.promptFrame, presentation.petOrigin)
    }

    private func layoutPromptSubviews() {
        petView.frame = NSRect(origin: .zero, size: Self.panelSize)
        appIconView.frame = NSRect(
            x: Self.panelSize.width - Self.appIconSize.width,
            y: Self.panelSize.height - Self.appIconSize.height,
            width: Self.appIconSize.width,
            height: Self.appIconSize.height
        )
        if isAnswerOpen {
            promptBubbleView.frame = NSRect(origin: .zero, size: currentAnswerLayout.panelSize)
            promptBubbleView.bubbleFrame = currentAnswerLayout.bubbleFrame
            answerScrollView.frame = currentAnswerLayout.viewportFrame
            // The visible bubble border sits 15px in from the sides (5*unit)
            // and 9px up from the bottom (3*unit). Add the SAME gap past each
            // so the button is equidistant from the right and bottom edges.
            let bubble = currentAnswerLayout.bubbleFrame
            let buttonSize: CGFloat = 16
            let sideBorder: CGFloat = 15
            let bottomBorder: CGFloat = 9
            let gap: CGFloat = 8
            continueButton.frame = NSRect(
                x: bubble.maxX - sideBorder - gap - buttonSize,
                y: bubble.minY + bottomBorder + gap,
                width: buttonSize,
                height: buttonSize
            )
        } else {
            promptBubbleView.frame = NSRect(origin: .zero, size: currentPromptInputLayout.panelSize)
            promptBubbleView.bubbleFrame = currentPromptInputLayout.bubbleFrame
            promptTextField.frame = currentPromptInputLayout.textFrame
        }
    }

    func showReady(
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
        // Don't yank the pet back to "ready" while Ask is open (input, loading,
        // or answer) — a casual selection in another app should leave the
        // in-progress dialog alone instead of tearing it down.
        guard !PetSelectionStatusPolicy.shouldPreserveCurrentStatus(
            isThinking: isThinking,
            isPromptVisible: isPromptVisible
        ) else {
            return
        }
        // A stale ring can still reference the previous selection's closures
        // if a new one arrives while it's open — tear it down before rearming.
        radialMenu?.close()
        radialMenu = nil
        clearPrompt(animate: true)
        cancelPointingAnimation()
        self.selectedText = selectedText
        self.onTranslate = onTranslate
        self.onRewrite = onRewrite
        self.onSmartReply = onSmartReply
        self.onAsk = onAsk
        self.onScreenshot = onScreenshot
        self.onLive = onLive
        self.onDictate = onDictate
        self.summarizeOption = summarizeOption
        currentMode = initialMode
        isReadyLockedUntilPanelCloses = false
        panel.ignoresMouseEvents = false
        petView.apply(state: .ready, mode: currentMode)
        appIconView.isHidden = true
        show()
    }

    func holdReadyUntilPanelCloses(mode: TranslationMode? = nil) {
        radialMenu?.close()
        radialMenu = nil
        cancelPointingAnimation()
        if let mode {
            currentMode = mode
        }
        selectedText = nil
        onTranslate = nil
        onRewrite = nil
        onSmartReply = nil
        onAsk = nil
        summarizeOption = nil
        isReadyLockedUntilPanelCloses = true
        panel.ignoresMouseEvents = true
        petView.apply(state: .ready, mode: currentMode)
        appIconView.isHidden = true
    }

    func clearReady() {
        guard !PetSelectionStatusPolicy.shouldPreserveCurrentStatus(
            isThinking: isThinking,
            isPromptVisible: isPromptVisible
        ) else { return }
        radialMenu?.close()
        radialMenu = nil
        cancelPointingAnimation()
        selectedText = nil
        onTranslate = nil
        onRewrite = nil
        onSmartReply = nil
        onAsk = nil
        summarizeOption = nil
        isReadyLockedUntilPanelCloses = false
        panel.ignoresMouseEvents = true
        petView.apply(state: .idle, mode: currentMode)
        refreshStyleBadge()
    }

    func showThinking() {
        radialMenu?.close()
        radialMenu = nil
        if isPromptOpen {
            clearPrompt(animate: false)
        }
        cancelPointingAnimation()
        isThinking = true
        selectedText = nil
        onTranslate = nil
        onRewrite = nil
        onSmartReply = nil
        onAsk = nil
        summarizeOption = nil
        isReadyLockedUntilPanelCloses = false
        panel.ignoresMouseEvents = !isPromptLoading
        petView.allowsClickWhenNotReady = isPromptLoading
        appIconView.isHidden = true
        petView.apply(state: .thinking, mode: currentMode)
        petView.onDragRequested = { [weak self] startLocation in
            self?.beginPetThrowDrag(initialMouseLocation: startLocation)
        }
        show()
    }

    func clearThinking() {
        isThinking = false
        isPromptLoading = false
        stopThrow()
        panel.ignoresMouseEvents = true
        petView.allowsClickWhenNotReady = false
        petView.onDragRequested = nil
        petView.apply(state: .idle, mode: currentMode)
        refreshStyleBadge()
    }

    private func cancelPointingAnimation() {
        pointingReturnTimer?.invalidate()
        pointingReturnTimer = nil
        pointingTarget = nil
    }

    func setActionMode(_ mode: TranslationMode) {
        currentMode = mode
        guard !isPromptVisible else { return }
        petView.apply(state: selectedText == nil && !isReadyLockedUntilPanelCloses ? .idle : .ready, mode: currentMode)
        refreshStyleBadge()
    }

    private func startTracking() {
        guard trackingTimer == nil else { return }

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    private func updateTracking() {
        guard panel.isVisible else { return }

        petView.advanceAnimationFrame()
        if let pointingTarget {
            let targetOrigin = Self.originNearPoint(pointingTarget, size: Self.panelSize)
            let currentOrigin = panel.frame.origin
            let dx = targetOrigin.x - currentOrigin.x
            let dy = targetOrigin.y - currentOrigin.y
            let nextOrigin = NSPoint(
                x: currentOrigin.x + dx * 0.18,
                y: currentOrigin.y + dy * 0.18
            )
            panel.setFrameOrigin(nextOrigin)
            let distance = hypot(dx, dy)
            let didArrive = distance <= Self.pointingArrivalThreshold
            petView.apply(state: didArrive ? .ready : .run, mode: currentMode)
            return
        }
        guard selectedText == nil, !isReadyLockedUntilPanelCloses, !isThinking, !isPromptVisible else {
            return
        }

        let cursorLocation = NSEvent.mouseLocation
        let frameDelta = NSPoint(
            x: cursorLocation.x - lastCursorLocation.x,
            y: cursorLocation.y - lastCursorLocation.y
        )
        lastCursorLocation = cursorLocation
        let frameMagnitude = hypot(frameDelta.x, frameDelta.y)
        if frameMagnitude > 0.75 {
            lastCursorMovementDate = Date()
        }

        // Low-pass filter on cursor velocity — used ONLY by the shy-step
        // evasion below, not for the side flip. The side commitment uses raw
        // instantaneous frame velocity so only a true flick (high peak speed
        // in a single tick) flips the pet.
        let alpha: CGFloat = 0.08
        smoothedCursorVelocity = NSPoint(
            x: alpha * frameDelta.x + (1 - alpha) * smoothedCursorVelocity.x,
            y: alpha * frameDelta.y + (1 - alpha) * smoothedCursorVelocity.y
        )

        // Side only flips on a real flick — a sharp single-frame jerk above
        // this threshold. ~50pt/frame at 30Hz ≈ 1500pt/sec, which is a hard
        // wrist-snap, not normal cursor travel. Slow or sustained movement
        // keeps the current side no matter how long it lasts — only a sudden
        // burst earns a new side.
        let flickThreshold: CGFloat = 50
        if frameMagnitude >= flickThreshold {
            let candidate = Self.trailingOffset(
                forMovement: frameDelta,
                size: Self.panelSize,
                currentOffset: cursorOffset
            )
            if candidate != cursorOffset {
                cursorOffset = candidate
            }
        }

        // Shy-step displacement: for sub-threshold motion (jitter / small
        // moves that don't earn a side flip), nudge the pet a little further
        // along its current trailing direction whenever the cursor is closing
        // the gap on it. Net effect is "pet steps away" instead of "pet sits
        // still". The nudge decays with the EMA when the cursor stops.
        let evasion: NSPoint = {
            let petDistance = hypot(cursorOffset.x, cursorOffset.y)
            guard petDistance > 0 else { return .zero }
            let petDirX = cursorOffset.x / petDistance
            let petDirY = cursorOffset.y / petDistance
            // Projected velocity along the pet's direction. > 0 means the
            // cursor is moving toward where the pet currently sits.
            let velocityTowardPet =
                smoothedCursorVelocity.x * petDirX
                + smoothedCursorVelocity.y * petDirY
            guard velocityTowardPet > 0 else { return .zero }
            let evasionGain: CGFloat = 4.0
            let maxEvasion: CGFloat = 14.0
            let magnitude = min(velocityTowardPet * evasionGain, maxEvasion)
            return NSPoint(x: petDirX * magnitude, y: petDirY * magnitude)
        }()

        let effectiveOffset = NSPoint(
            x: cursorOffset.x + evasion.x,
            y: cursorOffset.y + evasion.y
        )
        let targetOrigin = Self.originNearCursor(
            for: cursorLocation,
            size: Self.panelSize,
            offset: effectiveOffset
        )
        let currentOrigin = panel.frame.origin
        let dx = targetOrigin.x - currentOrigin.x
        let dy = targetOrigin.y - currentOrigin.y
        let nextOrigin = NSPoint(
            x: currentOrigin.x + dx * 0.22,
            y: currentOrigin.y + dy * 0.22
        )
        panel.setFrameOrigin(nextOrigin)
        let cursorMovedRecently = Date().timeIntervalSince(lastCursorMovementDate) < 0.16
        petView.apply(state: cursorMovedRecently ? .run : .idle, mode: currentMode)
    }

    private func toggleRadialMenu() {
        if let radialMenu {
            radialMenu.close()
            self.radialMenu = nil
            return
        }
        // Same gate the old direct invocation had: the ring only makes sense
        // while a selection is armed.
        guard selectedText != nil, !isReadyLockedUntilPanelCloses else { return }
        var items: [RingItem] = [
            .phosphor("magnifying-glass", label: "Explain") { [weak self] in
                guard let self, let t = self.selectedText else { return }
                self.radialMenu = nil
                self.onTranslate?(t)
            },
            .phosphor("pencil-line", label: "Rewrite") { [weak self] in
                guard let self, let t = self.selectedText else { return }
                self.radialMenu = nil
                self.onRewrite?(t)
            },
            .phosphor("arrow-bend-up-left", label: "Reply") { [weak self] in
                guard let self, let t = self.selectedText else { return }
                self.radialMenu = nil
                self.onSmartReply?(t)
            },
            .phosphor("question", label: "Ask") { [weak self] in
                guard let self else { return }
                self.radialMenu = nil
                self.onAsk?()
            },
            .phosphor("scan", label: "Capture") { [weak self] in
                guard let self else { return }
                self.radialMenu = nil
                self.onScreenshot?()
            },
            .symbol("mic", label: "Dictate") { [weak self] in
                guard let self else { return }
                self.radialMenu = nil
                self.onDictate?()
            },
            .symbol("waveform", label: "Live") { [weak self] in
                guard let self else { return }
                self.radialMenu = nil
                self.onLive?()
            },
        ]
        if let opt = summarizeOption {
            items.insert(summarizeRingItem(opt, dismiss: { [weak self] in
                self?.radialMenu = nil
            }), at: 5)
        }
        let menu = RadialActionMenuController(
            centeredOn: petCenterInScreen(),
            ignoring: panel,
            items: items,
            onDismiss: { [weak self] in
                self?.radialMenu = nil
            }
        )
        radialMenu = menu
        menu.show()
    }

    private func petCenterInScreen() -> NSPoint {
        let frameInWindow = petView.convert(petView.bounds, to: nil)
        let screenRect = panel.convertToScreen(frameInWindow)
        return NSPoint(x: screenRect.midX, y: screenRect.midY)
    }

    private static func originNearCursor(for cursor: NSPoint, size: NSSize, offset: NSPoint) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: cursor.x + offset.x, y: cursor.y + offset.y)

        if origin.y < visibleFrame.minY + edgeMargin {
            origin.y = cursor.y + 12
        }
        if origin.y + size.height > visibleFrame.maxY - edgeMargin {
            origin.y = cursor.y - size.height - 8
        }
        if origin.x < visibleFrame.minX + edgeMargin {
            origin.x = cursor.x + 12
        }
        if origin.x + size.width > visibleFrame.maxX - edgeMargin {
            origin.x = cursor.x - size.width - 12
        }

        origin.x = min(max(origin.x, visibleFrame.minX + edgeMargin), visibleFrame.maxX - size.width - edgeMargin)
        origin.y = min(max(origin.y, visibleFrame.minY + edgeMargin), visibleFrame.maxY - size.height - edgeMargin)
        return origin
    }

    private static func originNearPoint(_ point: NSPoint, size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        origin.x = min(max(origin.x, visibleFrame.minX + edgeMargin), visibleFrame.maxX - size.width - edgeMargin)
        origin.y = min(max(origin.y, visibleFrame.minY + edgeMargin), visibleFrame.maxY - size.height - edgeMargin)
        return origin
    }

    private static func clampedOrigin(_ origin: NSPoint, size: NSSize, visibleFrame: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(origin.x, visibleFrame.minX + edgeMargin), visibleFrame.maxX - size.width - edgeMargin),
            y: min(max(origin.y, visibleFrame.minY + edgeMargin), visibleFrame.maxY - size.height - edgeMargin)
        )
    }

    private static func trailingOffset(
        forMovement movement: NSPoint,
        size: NSSize,
        currentOffset: NSPoint? = nil
    ) -> NSPoint {
        // Axis-bias hysteresis: if the pet is already committed horizontally
        // (left/right of cursor), require the vertical component to be
        // noticeably larger than the horizontal before flipping to a vertical
        // side — and vice-versa. Without this, diagonal motion where |dx|≈|dy|
        // would oscillate between horizontal and vertical sides.
        let axisBias: CGFloat = 1.9
        let currentIsHorizontal: Bool? = currentOffset.flatMap { offset in
            if offset.x == 12 || offset.x == -size.width - 12 {
                return true
            }
            if offset.y == 12 || offset.y == -size.height - 8 {
                return false
            }
            return nil
        }

        let pickHorizontal: Bool
        switch currentIsHorizontal {
        case .some(true):
            pickHorizontal = abs(movement.x) * axisBias >= abs(movement.y)
        case .some(false):
            pickHorizontal = abs(movement.x) >= abs(movement.y) * axisBias
        case .none:
            pickHorizontal = abs(movement.x) >= abs(movement.y)
        }

        if pickHorizontal {
            let xOffset = movement.x > 0 ? -size.width - 12 : 12
            return NSPoint(x: xOffset, y: -size.height / 2)
        }

        let yOffset = movement.y > 0 ? -size.height - 8 : 12
        return NSPoint(x: -size.width / 2, y: yOffset)
    }

    /// Drag the dialog bubble — and the pet with it — by tracking mouse
    /// movement until the user releases the button. Runs a synchronous event
    /// loop because that's the Cocoa-blessed way to handle window drag from a
    /// view's mouseDown. Annotation coordinates remain fixed to their screen
    /// positions so they anchor to whatever on-screen objects the answer
    /// describes, allowing the user to drag the bubble to a readable spot
    /// without losing visual reference. The caller supplies the initial
    /// screen-space mouse location captured at mouseDown so drag-vs-click
    /// detection upstream doesn't shift the anchor.
    private func beginBubbleDrag(initialMouseLocation: NSPoint) {
        let initialPetOrigin = panel.frame.origin
        let initialPromptOrigin = promptPanel.frame.origin

        while true {
            let event = NSApp.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            )
            guard let event else { break }
            if event.type == .leftMouseUp { break }

            let current = NSEvent.mouseLocation
            let dx = current.x - initialMouseLocation.x
            let dy = current.y - initialMouseLocation.y

            panel.setFrameOrigin(NSPoint(x: initialPetOrigin.x + dx, y: initialPetOrigin.y + dy))
            promptPanel.setFrameOrigin(NSPoint(x: initialPromptOrigin.x + dx, y: initialPromptOrigin.y + dy))
        }
    }

    // MARK: Throw physics (thinking-state drag)

    private static let throwVelocityFrameRate: TimeInterval = 1.0 / 60.0
    private static let throwSampleWindow: TimeInterval = 0.1   // last 100ms of motion → release velocity
    private static let throwBounceDamping: CGFloat = 0.65       // wall-bounce energy retained
    private static let throwFriction: CGFloat = 0.98             // per-frame velocity decay
    private static let throwReleaseThreshold: CGFloat = 2        // pts/frame below which release is just a drag, not a throw
    private static let throwStopThreshold: CGFloat = 0.4         // pts/frame below which the throw stops

    /// During thinking, drag works like the bubble drag (pet + prompt panel
    /// move together) but also samples the last 100ms of cursor motion. On
    /// release, if the user was moving fast enough, hand off to the throw
    /// simulator so the pet flies and bounces off screen edges.
    private func beginPetThrowDrag(initialMouseLocation: NSPoint) {
        stopThrow()   // a fresh grab cancels any in-flight throw

        let initialPetOrigin = panel.frame.origin
        let initialPromptOrigin = promptPanel.frame.origin
        var samples: [(time: Date, point: NSPoint)] = [(Date(), initialMouseLocation)]

        while true {
            let event = NSApp.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            )
            guard let event else { break }

            let now = NSEvent.mouseLocation
            let cutoff = Date(timeIntervalSinceNow: -Self.throwSampleWindow)
            samples.removeAll { $0.time < cutoff }
            samples.append((Date(), now))

            if event.type == .leftMouseUp { break }

            let dx = now.x - initialMouseLocation.x
            let dy = now.y - initialMouseLocation.y
            panel.setFrameOrigin(NSPoint(x: initialPetOrigin.x + dx, y: initialPetOrigin.y + dy))
            promptPanel.setFrameOrigin(NSPoint(x: initialPromptOrigin.x + dx, y: initialPromptOrigin.y + dy))
        }

        guard let first = samples.first, let last = samples.last else { return }
        let dt = last.time.timeIntervalSince(first.time)
        guard dt > 0.001 else { return }
        let vxPerSec = (last.point.x - first.point.x) / CGFloat(dt)
        let vyPerSec = (last.point.y - first.point.y) / CGFloat(dt)
        let perFrame = NSPoint(
            x: vxPerSec * CGFloat(Self.throwVelocityFrameRate),
            y: vyPerSec * CGFloat(Self.throwVelocityFrameRate)
        )
        guard hypot(perFrame.x, perFrame.y) > Self.throwReleaseThreshold else { return }
        startThrowSimulation(initialVelocity: perFrame)
    }

    private func startThrowSimulation(initialVelocity: NSPoint) {
        throwTimer?.invalidate()
        throwVelocity = initialVelocity
        petView.apply(state: .flying, mode: currentMode)
        let timer = Timer(timeInterval: Self.throwVelocityFrameRate, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stepThrow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        throwTimer = timer
    }

    private func stepThrow() {
        let petOrigin = panel.frame.origin
        let promptOrigin = promptPanel.frame.origin
        let petSize = panel.frame.size
        var newOrigin = NSPoint(x: petOrigin.x + throwVelocity.x, y: petOrigin.y + throwVelocity.y)

        let referencePoint = NSPoint(x: petOrigin.x + petSize.width / 2, y: petOrigin.y + petSize.height / 2)
        let screen = NSScreen.visibleFrame(containing: referencePoint)
        let bounce = Self.throwBounceDamping

        if newOrigin.x < screen.minX {
            newOrigin.x = screen.minX
            throwVelocity.x = -throwVelocity.x * bounce
        } else if newOrigin.x + petSize.width > screen.maxX {
            newOrigin.x = screen.maxX - petSize.width
            throwVelocity.x = -throwVelocity.x * bounce
        }
        if newOrigin.y < screen.minY {
            newOrigin.y = screen.minY
            throwVelocity.y = -throwVelocity.y * bounce
        } else if newOrigin.y + petSize.height > screen.maxY {
            newOrigin.y = screen.maxY - petSize.height
            throwVelocity.y = -throwVelocity.y * bounce
        }

        let dx = newOrigin.x - petOrigin.x
        let dy = newOrigin.y - petOrigin.y
        panel.setFrameOrigin(newOrigin)
        promptPanel.setFrameOrigin(NSPoint(x: promptOrigin.x + dx, y: promptOrigin.y + dy))

        throwVelocity.x *= Self.throwFriction
        throwVelocity.y *= Self.throwFriction

        if hypot(throwVelocity.x, throwVelocity.y) < Self.throwStopThreshold {
            stopThrow()
        }
    }

    private func stopThrow() {
        let wasFlying = throwTimer != nil
        throwTimer?.invalidate()
        throwTimer = nil
        throwVelocity = .zero
        // Snap the pet back to the state it was already in (thinking, if
        // throw was triggered from there). Skip if no throw was running to
        // avoid clobbering whatever state the caller is mid-setting.
        if wasFlying, isThinking {
            petView.apply(state: .thinking, mode: currentMode)
        }
    }
}

