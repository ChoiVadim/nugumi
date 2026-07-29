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

/// The Ask Gizmate capsule's glass body. Any click inside it focuses the text
/// field instead of starting a window drag, so the whole pill is clickable.
private final class AskPromptGlassView: NSVisualEffectView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

final class AskPromptTextField: NSTextField {
    var onEscape: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // NSCell.init(textCell:) yields a label-style cell (isEditable/isSelectable
        // default to false), so re-enable both or the field can't take focus —
        // no caret, clicks do nothing.
        cell = AskPromptTextFieldCell(textCell: "")
        isEditable = true
        isSelectable = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

private final class AskPromptTextFieldCell: NSTextFieldCell {}

private final class AskPromptPanel: NSPanel {
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

/// Activating an `.accessory` app that wasn't frontmost makes macOS deliver a
/// reopen event — the same one a Dock relaunch sends. Our own panels activate
/// the app to take focus, so `applicationShouldHandleReopen` can't tell those
/// apart from a genuine relaunch and would pop the main window. Any internal
/// activation routes through here, opening a brief window during which the
/// delegate ignores reopen.
@MainActor
enum SelfActivationGuard {
    private static var suppressUntil = Date.distantPast
    /// Who was in front before Gizmate took focus for a panel, so dismissing that
    /// panel can hand focus straight back instead of leaving Gizmate active — where
    /// AppKit would promote whatever window is next in line (the settings window)
    /// and raise it.
    private static weak var previousApp: NSRunningApplication?

    static func activate() {
        suppressUntil = Date().addingTimeInterval(0.6)
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
        }

        // Activating an app raises ALL of its windows, so an open-but-behind
        // settings window would jump in front of whatever the user is actually
        // looking at — they asked for a small panel at the cursor, not for
        // Gizmate's window. Note the real windows that weren't already in front
        // and send them back once the activation has settled. Panels are
        // untouched: `canBecomeMain` is false for them, and they're the point.
        let demoted = NSApp.windows.filter {
            $0.isVisible && $0.canBecomeMain && !$0.isKeyWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        guard !demoted.isEmpty else { return }
        DispatchQueue.main.async {
            for window in demoted where window.isVisible && !window.isKeyWindow {
                window.orderBack(nil)
            }
        }
    }

    static var isSuppressing: Bool { Date() < suppressUntil }

    /// Called when a panel we activated for is dismissed with nothing to replace
    /// it. Returns focus to the app the user was in; only then does closing the
    /// panel leave the screen the way they left it.
    ///
    /// A no-op when a Gizmate window is genuinely in front — if the user clicked
    /// into the settings window while the panel was up, that's where they want
    /// to be.
    static func relinquish() {
        suppressUntil = Date().addingTimeInterval(0.6)
        guard let previousApp, !previousApp.isTerminated else { return }
        guard NSApp.keyWindow?.canBecomeMain != true else {
            self.previousApp = nil
            return
        }
        previousApp.activate()
        self.previousApp = nil
    }
}

@MainActor
final class AskPromptController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private static let textMovementUserInfoKey = "NSTextMovement"

    private let panel: NSPanel
    private let textField: AskPromptTextField
    private let onSubmit: (String) -> Void
    private let onClose: () -> Void
    /// What the empty field reads. A tool borrows this capsule for its own
    /// input, and "Ask Gizmate" over a field that feeds "Draft reply" would be
    /// a lie about where the text is going.
    private let placeholder: String
    private var didClose = false
    private var isSubmitting = false

    var isVisible: Bool { panel.isVisible }

    /// Center of the pill's window in screen coordinates. Used by the
    /// caller to position the substitute floating loading bar at the same
    /// spot when the pill is hidden during an in-flight question.
    var panelCenter: NSPoint {
        NSPoint(x: panel.frame.midX, y: panel.frame.midY)
    }

    init(
        near screenPoint: NSPoint,
        placeholder: String = "Ask Gizmate",
        onSubmit: @escaping (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.onSubmit = onSubmit
        self.onClose = onClose
        self.placeholder = placeholder

        let layout = AskGizmateFloatingPromptMetrics.layout
        let origin = Self.origin(near: screenPoint, size: layout.panelSize)
        panel = AskPromptPanel(
            contentRect: NSRect(origin: origin, size: layout.panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        textField = AskPromptTextField(frame: .zero)

        super.init()

        panel.delegate = self
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        InvisibilityState.apply(to: panel)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true

        buildUI()
    }

    func show() {
        textField.stringValue = ""
        textField.isEnabled = true
        SelfActivationGuard.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textField)
    }

    func setLoading() {
        panel.sharingType = .none
        textField.isEnabled = false
        textField.stringValue = ""
        setPlaceholder("Looking...")
    }

    /// Visually removes the pill while keeping the controller alive, so
    /// `showError` can bring it back via `makeKeyAndOrderFront`.
    func hidePanel() {
        panel.orderOut(nil)
    }

    func showError(_ message: String) {
        isSubmitting = false
        textField.isEnabled = true
        textField.stringValue = ""
        setPlaceholder(message)
        SelfActivationGuard.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textField)
    }

    func close() {
        guard !didClose else { return }
        didClose = true
        panel.close()
        onClose()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, !self.didClose else { return }
            self.didClose = true
            self.onClose()
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard textMovement(from: notification) == NSTextMovement.return.rawValue else {
            return
        }
        submit()
    }

    private func buildUI() {
        let layout = AskGizmateFloatingPromptMetrics.layout
        let rootView = NSView(frame: NSRect(origin: .zero, size: layout.panelSize))
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        rootView.layer?.masksToBounds = false

        // Same liquid-glass capsule as the main window and the language HUD —
        // no glow gradients, just the hud material with a hairline border.
        let glass = AskPromptGlassView(frame: layout.pillFrame)
        glass.onClick = { [weak self] in
            guard let self else { return }
            self.panel.makeKeyAndOrderFront(nil)
            self.panel.makeFirstResponder(self.textField)
        }
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.autoresizingMask = [.width, .height]
        glass.wantsLayer = true
        glass.layer?.cornerRadius = layout.cornerRadius
        glass.layer?.masksToBounds = true
        glass.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        glass.layer?.borderWidth = 1
        rootView.addSubview(glass)

        textField.delegate = self
        textField.onEscape = { [weak self] in
            self?.close()
        }
        setPlaceholder(placeholder)
        textField.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        textField.textColor = NSColor(calibratedWhite: 1.0, alpha: 0.88)
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.backgroundColor = .clear
        textField.focusRingType = .none
        textField.usesSingleLineMode = true
        textField.maximumNumberOfLines = 1
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.cell?.lineBreakMode = .byTruncatingTail
        textField.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(textField)

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(
                equalTo: glass.leadingAnchor,
                constant: layout.textFrame.minX - layout.pillFrame.minX
            ),
            textField.trailingAnchor.constraint(
                equalTo: glass.trailingAnchor,
                constant: -(layout.pillFrame.maxX - layout.textFrame.maxX)
            ),
            // Intrinsic height + centerY keeps the text optically centered in
            // the capsule (a fixed-height cell draws its baseline high).
            textField.centerYAnchor.constraint(equalTo: glass.centerYAnchor)
        ])

        panel.contentView = rootView
    }

    private func submit() {
        guard textField.isEnabled, !isSubmitting else { return }
        let text = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            panel.makeFirstResponder(textField)
            return
        }
        isSubmitting = true
        onSubmit(text)
    }

    private func setPlaceholder(_ text: String) {
        textField.placeholderString = text
        textField.placeholderAttributedString = NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.44),
                .font: textField.font ?? NSFont.systemFont(ofSize: 14, weight: .regular)
            ]
        )
    }

    private func textMovement(from notification: Notification) -> Int? {
        notification.userInfo?[Self.textMovementUserInfoKey] as? Int
    }

    private static func origin(near point: NSPoint, size: NSSize) -> NSPoint {
        let visibleFrame = NSScreen.visibleFrame(containing: point)
        let edgeMargin = AskGizmateFloatingPromptMetrics.edgeMargin
        let preferredGap: CGFloat = 10
        let preferredBelowY = point.y - size.height - preferredGap
        let preferredAboveY = point.y + preferredGap
        let desiredY: CGFloat
        if preferredBelowY < visibleFrame.minY + edgeMargin,
           preferredAboveY + size.height <= visibleFrame.maxY - edgeMargin {
            desiredY = preferredAboveY
        } else {
            desiredY = preferredBelowY
        }

        return NSPoint(
            x: clamped(point.x - size.width / 2, min: visibleFrame.minX + edgeMargin, max: visibleFrame.maxX - size.width - edgeMargin),
            y: clamped(desiredY, min: visibleFrame.minY + edgeMargin, max: visibleFrame.maxY - size.height - edgeMargin)
        )
    }

    private static func clamped(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        guard minValue <= maxValue else {
            return (minValue + maxValue) / 2
        }
        return Swift.min(Swift.max(value, minValue), maxValue)
    }
}

