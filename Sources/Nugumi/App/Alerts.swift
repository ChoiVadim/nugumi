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
private final class NugumiModalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

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

@MainActor
final class NugumiInputAlertController: NSWindowController, NSWindowDelegate {
    private static let horizontalPadding: CGFloat = 18
    private static let verticalPadding: CGFloat = 18
    private static let shadowMargin: CGFloat = 30
    private static let cornerRadius: CGFloat = 28
    private static let mascotSize = NSSize(width: 42, height: 34)
    private static let textGap: CGFloat = 10
    private static let fieldHeight: CGFloat = 30
    private static let buttonHeight: CGFloat = 30
    private static let buttonStackSpacing: CGFloat = 8
    private static let textColumnWidth: CGFloat = 320
    private static let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    private static let messageFont = NSFont.systemFont(ofSize: 12, weight: .regular)

    struct Result {
        let response: NSApplication.ModalResponse
        let text: String
    }

    private var textField: NSTextField!
    private(set) var enteredText: String = ""

    private let title_: String
    private let message: String
    private let placeholder: String
    private let initialValue: String?
    private let isSecure: Bool
    private let primaryButtonTitle: String
    private let secondaryButtonTitle: String?
    private let tertiaryButtonTitle: String?

    init(
        title: String,
        message: String,
        placeholder: String,
        initialValue: String? = nil,
        isSecure: Bool = true,
        primaryButtonTitle: String,
        secondaryButtonTitle: String? = nil,
        tertiaryButtonTitle: String? = nil
    ) {
        self.title_ = title
        self.message = message
        self.placeholder = placeholder
        self.initialValue = initialValue
        self.isSecure = isSecure
        self.primaryButtonTitle = primaryButtonTitle
        self.secondaryButtonTitle = secondaryButtonTitle
        self.tertiaryButtonTitle = tertiaryButtonTitle

        let cardSize = Self.cardSize(
            title: title,
            message: message,
            buttons: [primaryButtonTitle, secondaryButtonTitle, tertiaryButtonTitle].compactMap { $0 }
        )
        let windowSize = NSSize(
            width: cardSize.width + Self.shadowMargin * 2,
            height: cardSize.height + Self.shadowMargin * 2
        )
        let panel = NugumiModalPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        InvisibilityState.apply(to: panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true

        super.init(window: panel)
        panel.delegate = self
        buildUI(panel: panel, windowSize: windowSize, cardSize: cardSize)
    }

    required init?(coder: NSCoder) { nil }

    func showModal() -> Result {
        guard let window else { return Result(response: .cancel, text: "") }
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textField)
        let response = NSApp.runModal(for: window)
        return Result(response: response, text: enteredText)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            NSApp.stopModal(withCode: .cancel)
        }
    }

    private func buildUI(panel: NSPanel, windowSize: NSSize, cardSize: NSSize) {
        let rootView = NSView(frame: NSRect(origin: .zero, size: windowSize))
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        rootView.layer?.masksToBounds = false
        panel.contentView = rootView

        let glass = GlassHostView(
            frame: NSRect(origin: NSPoint(x: Self.shadowMargin, y: Self.shadowMargin), size: cardSize),
            cornerRadius: Self.cornerRadius,
            tintColor: nil,
            style: .regular
        )
        glass.wantsLayer = true
        glass.layer?.masksToBounds = false
        glass.layer?.shadowColor = NSColor.black.cgColor
        glass.layer?.shadowOpacity = 0.24
        glass.layer?.shadowRadius = 18
        glass.layer?.shadowOffset = CGSize(width: 0, height: -4)
        glass.layer?.shadowPath = CGPath(
            roundedRect: NSRect(origin: .zero, size: cardSize),
            cornerWidth: Self.cornerRadius,
            cornerHeight: Self.cornerRadius,
            transform: nil
        )
        glass.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(glass)
        let contentView = glass.contentView

        let mascotColumn = NSView()
        mascotColumn.translatesAutoresizingMaskIntoConstraints = false

        let mascotView = PetMascotView(frame: NSRect(origin: .zero, size: Self.mascotSize))
        mascotView.apply(state: .idle, mode: .selection)
        mascotView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title_)
        titleLabel.font = Self.titleFont
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = Self.messageFont
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 0
        messageLabel.preferredMaxLayoutWidth = Self.textColumnWidth
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        let field: NSTextField = isSecure ? NSSecureTextField() : NSTextField()
        field.placeholderString = placeholder
        if let initialValue { field.stringValue = initialValue }
        field.font = NSFont.systemFont(ofSize: 13)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.cell?.lineBreakMode = .byTruncatingTail
        textField = field

        let buttonStack = NSStackView()
        buttonStack.orientation = .vertical
        buttonStack.alignment = .centerX
        buttonStack.distribution = .fillEqually
        buttonStack.spacing = Self.buttonStackSpacing
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        var buttons: [NSButton] = []
        let primary = makeButton(title: primaryButtonTitle, action: #selector(primaryTapped))
        buttonStack.addArrangedSubview(primary)
        buttons.append(primary)
        if let secondaryButtonTitle {
            let secondary = makeButton(title: secondaryButtonTitle, action: #selector(secondaryTapped))
            buttonStack.addArrangedSubview(secondary)
            buttons.append(secondary)
        }
        if let tertiaryButtonTitle {
            let tertiary = makeButton(title: tertiaryButtonTitle, action: #selector(tertiaryTapped))
            buttonStack.addArrangedSubview(tertiary)
            buttons.append(tertiary)
        }

        contentView.addSubview(mascotColumn)
        mascotColumn.addSubview(mascotView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(messageLabel)
        contentView.addSubview(field)
        contentView.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: rootView.topAnchor, constant: Self.shadowMargin),
            glass.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: Self.shadowMargin),
            glass.widthAnchor.constraint(equalToConstant: cardSize.width),
            glass.heightAnchor.constraint(equalToConstant: cardSize.height),

            mascotColumn.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.verticalPadding),
            mascotColumn.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.horizontalPadding),
            mascotColumn.widthAnchor.constraint(equalToConstant: Self.mascotSize.width),
            mascotColumn.heightAnchor.constraint(equalToConstant: Self.mascotSize.height),

            mascotView.centerXAnchor.constraint(equalTo: mascotColumn.centerXAnchor),
            mascotView.centerYAnchor.constraint(equalTo: mascotColumn.centerYAnchor),
            mascotView.widthAnchor.constraint(equalToConstant: Self.mascotSize.width),
            mascotView.heightAnchor.constraint(equalToConstant: Self.mascotSize.height),

            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.verticalPadding + 1),
            titleLabel.leadingAnchor.constraint(equalTo: mascotColumn.trailingAnchor, constant: Self.textGap),
            titleLabel.widthAnchor.constraint(equalToConstant: Self.textColumnWidth),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            messageLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            field.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            field.heightAnchor.constraint(equalToConstant: Self.fieldHeight),

            buttonStack.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            buttonStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Self.verticalPadding)
        ])

        for button in buttons {
            NSLayoutConstraint.activate([
                button.heightAnchor.constraint(equalToConstant: Self.buttonHeight),
                button.widthAnchor.constraint(equalTo: buttonStack.widthAnchor)
            ])
        }
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        button.focusRingType = .none
        return button
    }

    @objc private func primaryTapped() {
        enteredText = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        close(with: .alertFirstButtonReturn)
    }

    @objc private func secondaryTapped() {
        enteredText = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        close(with: .alertSecondButtonReturn)
    }

    @objc private func tertiaryTapped() {
        close(with: .alertThirdButtonReturn)
    }

    private func close(with response: NSApplication.ModalResponse) {
        NSApp.stopModal(withCode: response)
        window?.orderOut(nil)
    }

    private static func cardSize(title: String, message: String, buttons: [String]) -> NSSize {
        let titleHeight = ceil(titleFont.boundingRectForFont.height)
        let messageHeight = ceil((message as NSString).boundingRect(
            with: NSSize(width: textColumnWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: messageFont]
        ).height)
        let buttonsBlock = CGFloat(buttons.count) * buttonHeight
            + CGFloat(max(0, buttons.count - 1)) * buttonStackSpacing
        let inner = titleHeight + 4 + messageHeight + 12 + fieldHeight + 12 + buttonsBlock
        let height = verticalPadding * 2 + max(mascotSize.height, inner)
        let width = horizontalPadding * 2 + mascotSize.width + textGap + textColumnWidth
        return NSSize(width: ceil(width), height: ceil(height))
    }
}

final class NugumiAlertController: NSWindowController, NSWindowDelegate {
    private static let horizontalPadding: CGFloat = 16
    private static let verticalPadding: CGFloat = 16
    private static let shadowMargin: CGFloat = 30
    private static let cornerRadius: CGFloat = 28
    private static let mascotSize = NSSize(width: 42, height: 34)
    private static let textGap: CGFloat = 10
    private static let minTextWidth: CGFloat = 168
    private static let maxTextWidth: CGFloat = 300
    private static let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    private static let messageFont = NSFont.systemFont(ofSize: 12, weight: .regular)

    private struct AlertLayout {
        let cardSize: NSSize
        let textWidth: CGFloat
    }

    init(
        title: String,
        message: String,
        primaryButtonTitle: String,
        secondaryButtonTitle: String? = nil
    ) {
        let layout = Self.layout(
            title: title,
            message: message,
            primaryButtonTitle: primaryButtonTitle,
            secondaryButtonTitle: secondaryButtonTitle
        )
        let windowSize = NSSize(
            width: layout.cardSize.width + Self.shadowMargin * 2,
            height: layout.cardSize.height + Self.shadowMargin * 2
        )
        let panel = NugumiModalPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        InvisibilityState.apply(to: panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true

        super.init(window: panel)
        panel.delegate = self
        buildUI(
            in: panel,
            windowSize: windowSize,
            layout: layout,
            title: title,
            message: message,
            primaryButtonTitle: primaryButtonTitle,
            secondaryButtonTitle: secondaryButtonTitle
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    func showModal() -> NSApplication.ModalResponse {
        guard let window else { return .cancel }
        window.center()
        window.makeKeyAndOrderFront(nil)
        return NSApp.runModal(for: window)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            NSApp.stopModal(withCode: .cancel)
        }
    }

    private func buildUI(
        in panel: NSPanel,
        windowSize: NSSize,
        layout: AlertLayout,
        title: String,
        message: String,
        primaryButtonTitle: String,
        secondaryButtonTitle: String?
    ) {
        let rootView = NSView(frame: NSRect(origin: .zero, size: windowSize))
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        rootView.layer?.masksToBounds = false
        panel.contentView = rootView

        let glass = GlassHostView(
            frame: NSRect(origin: NSPoint(x: Self.shadowMargin, y: Self.shadowMargin), size: layout.cardSize),
            cornerRadius: Self.cornerRadius,
            tintColor: nil,
            style: .regular
        )
        glass.wantsLayer = true
        glass.layer?.masksToBounds = false
        glass.layer?.shadowColor = NSColor.black.cgColor
        glass.layer?.shadowOpacity = 0.24
        glass.layer?.shadowRadius = 18
        glass.layer?.shadowOffset = CGSize(width: 0, height: -4)
        glass.layer?.shadowPath = CGPath(
            roundedRect: NSRect(origin: .zero, size: layout.cardSize),
            cornerWidth: Self.cornerRadius,
            cornerHeight: Self.cornerRadius,
            transform: nil
        )
        glass.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(glass)
        let contentView = glass.contentView

        let mascotColumn = NSView()
        mascotColumn.translatesAutoresizingMaskIntoConstraints = false

        let mascotView = PetMascotView(frame: NSRect(origin: .zero, size: Self.mascotSize))
        mascotView.apply(state: .idle, mode: .selection)
        mascotView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = Self.titleFont
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = Self.messageFont
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 0
        messageLabel.preferredMaxLayoutWidth = layout.textWidth
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        let primaryButton = makeButton(title: primaryButtonTitle, action: #selector(primaryTapped))

        contentView.addSubview(mascotColumn)
        mascotColumn.addSubview(mascotView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(messageLabel)
        contentView.addSubview(primaryButton)

        var constraints: [NSLayoutConstraint] = [
            glass.topAnchor.constraint(equalTo: rootView.topAnchor, constant: Self.shadowMargin),
            glass.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: Self.shadowMargin),
            glass.widthAnchor.constraint(equalToConstant: layout.cardSize.width),
            glass.heightAnchor.constraint(equalToConstant: layout.cardSize.height),

            mascotColumn.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.verticalPadding),
            mascotColumn.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.horizontalPadding),
            mascotColumn.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Self.verticalPadding),
            mascotColumn.widthAnchor.constraint(equalToConstant: Self.mascotSize.width),

            mascotView.centerXAnchor.constraint(equalTo: mascotColumn.centerXAnchor),
            mascotView.centerYAnchor.constraint(equalTo: mascotColumn.centerYAnchor),
            mascotView.widthAnchor.constraint(equalToConstant: Self.mascotSize.width),
            mascotView.heightAnchor.constraint(equalToConstant: Self.mascotSize.height),

            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.verticalPadding + 1),
            titleLabel.leadingAnchor.constraint(equalTo: mascotColumn.trailingAnchor, constant: Self.textGap),
            titleLabel.widthAnchor.constraint(equalToConstant: layout.textWidth),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            messageLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            primaryButton.heightAnchor.constraint(equalToConstant: 30),
            primaryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.buttonWidth(for: primaryButtonTitle)),
            primaryButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Self.verticalPadding)
        ]

        if let secondaryButtonTitle {
            let secondaryButton = makeButton(title: secondaryButtonTitle, action: #selector(secondaryTapped))
            contentView.addSubview(secondaryButton)
            constraints.append(contentsOf: [
                secondaryButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                secondaryButton.trailingAnchor.constraint(equalTo: primaryButton.leadingAnchor, constant: -8),
                secondaryButton.bottomAnchor.constraint(equalTo: primaryButton.bottomAnchor),
                secondaryButton.heightAnchor.constraint(equalTo: primaryButton.heightAnchor),
                secondaryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.buttonWidth(for: secondaryButtonTitle)),
                secondaryButton.widthAnchor.constraint(equalTo: primaryButton.widthAnchor),

                primaryButton.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor)
            ])
        } else {
            constraints.append(contentsOf: [
                primaryButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                primaryButton.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor)
            ])
        }

        constraints.append(primaryButton.topAnchor.constraint(greaterThanOrEqualTo: messageLabel.bottomAnchor, constant: 12))
        NSLayoutConstraint.activate(constraints)
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        button.focusRingType = .none
        return button
    }

    @objc private func primaryTapped() {
        close(with: .alertFirstButtonReturn)
    }

    @objc private func secondaryTapped() {
        close(with: .alertSecondButtonReturn)
    }

    private func close(with response: NSApplication.ModalResponse) {
        NSApp.stopModal(withCode: response)
        window?.orderOut(nil)
    }

    private static func layout(
        title: String,
        message: String,
        primaryButtonTitle: String,
        secondaryButtonTitle: String?
    ) -> AlertLayout {
        let titleWidth = ceil((title as NSString).size(withAttributes: [.font: titleFont]).width)
        let messageSingleLineWidth = ceil((message as NSString).size(withAttributes: [.font: messageFont]).width)
        let primaryButtonWidth = buttonWidth(for: primaryButtonTitle)
        let buttonWidth: CGFloat
        if let secondaryButtonTitle {
            let secondaryButtonWidth = Self.buttonWidth(for: secondaryButtonTitle)
            buttonWidth = max(primaryButtonWidth, secondaryButtonWidth) * 2 + 8
        } else {
            buttonWidth = primaryButtonWidth
        }

        let textWidth = min(
            max(max(titleWidth, messageSingleLineWidth, buttonWidth), minTextWidth),
            maxTextWidth
        )
        let messageHeight = ceil((message as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: messageFont]
        ).height)
        let textBlockHeight = ceil(titleFont.boundingRectForFont.height) + 4 + messageHeight
        let height = verticalPadding + max(mascotSize.height, textBlockHeight + 12 + 30) + verticalPadding
        let width = horizontalPadding * 2 + mascotSize.width + textGap + textWidth
        return AlertLayout(
            cardSize: NSSize(width: ceil(width), height: max(112, ceil(height))),
            textWidth: textWidth
        )
    }

    private static func buttonWidth(for title: String) -> CGFloat {
        let titleWidth = ceil((title as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
        ]).width)
        return max(54, titleWidth + 28)
    }
}

