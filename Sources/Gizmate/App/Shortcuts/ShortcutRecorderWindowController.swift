import AppKit
import Carbon.HIToolbox
import Foundation


@MainActor
final class ShortcutRecorderWindowController: NSWindowController, NSWindowDelegate {
    private static let horizontalPadding: CGFloat = 16
    private static let verticalPadding: CGFloat = 16
    private static let shadowMargin: CGFloat = 30
    private static let cornerRadius: CGFloat = 28
    private static let iconSize = NSSize(width: 42, height: 34)
    private static let textGap: CGFloat = 10
    private static let cardSize = NSSize(width: 450, height: 176)
    private static let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    private static let messageFont = NSFont.systemFont(ofSize: 12, weight: .regular)

    /// What the key is for, as shown in the panel's message — an action's
    /// `menuTitle` or a gizmo's name. A plain string so the recorder needs no
    /// idea which of the two it is serving.
    private let subject: String
    /// nil when nothing is bound yet — a gizmo starts keyless, unlike an
    /// action, which always falls back to its default.
    private let currentShortcut: GlobalShortcut?
    private let onShortcut: (GlobalShortcut) -> Bool
    private let onClose: () -> Void
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let shortcutField = ShortcutCaptureFieldView()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let okButton = NSButton(title: "OK", target: nil, action: nil)
    private var pendingShortcut: GlobalShortcut?

    init(
        title: String,
        currentShortcut: GlobalShortcut?,
        onShortcut: @escaping (GlobalShortcut) -> Bool,
        onClose: @escaping () -> Void
    ) {
        self.subject = title
        self.currentShortcut = currentShortcut
        self.onShortcut = onShortcut
        self.onClose = onClose

        let windowSize = NSSize(
            width: Self.cardSize.width + Self.shadowMargin * 2,
            height: Self.cardSize.height + Self.shadowMargin * 2
        )
        let panel = ShortcutRecorderPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true

        super.init(window: panel)
        panel.delegate = self
        buildUI(in: panel, windowSize: windowSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func present() {
        guard let window else {
            return
        }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Field is firstResponder from the start so Esc dismisses immediately.
        // The field stays in .idle until the user clicks it — see
        // ShortcutCaptureFieldView.mouseDown.
        window.makeFirstResponder(shortcutField)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.onClose()
        }
    }

    private func buildUI(in panel: NSPanel, windowSize: NSSize) {
        let rootView = NSView(frame: NSRect(origin: .zero, size: windowSize))
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        rootView.layer?.masksToBounds = false
        panel.contentView = rootView

        let glass = GlassHostView(
            frame: NSRect(
                origin: NSPoint(x: Self.shadowMargin, y: Self.shadowMargin),
                size: Self.cardSize
            ),
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
            roundedRect: NSRect(origin: .zero, size: Self.cardSize),
            cornerWidth: Self.cornerRadius,
            cornerHeight: Self.cornerRadius,
            transform: nil
        )
        glass.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(glass)
        let contentView = glass.contentView

        let iconColumn = NSView()
        iconColumn.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView(image: NSApp.applicationIconImage)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "Set shortcut")
        titleLabel.font = Self.titleFont
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.stringValue = "Click the field, then press keys for \(subject) - or double-tap ⌃ ⌥ ⇧ ⌘, or click a spare mouse button."
        messageLabel.font = Self.messageFont
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 0
        messageLabel.preferredMaxLayoutWidth = textWidth
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        shortcutField.idleDisplayText = currentShortcut?.displayString ?? ""
        shortcutField.onBeginRecording = { [weak self] in
            guard let self else { return }
            self.pendingShortcut = nil
            self.okButton.isEnabled = false
            self.messageLabel.stringValue = "Press the new shortcut now, double-tap ⌃ ⌥ ⇧ ⌘, or tap the trackpad with three fingers."
        }
        shortcutField.onCaptured = { [weak self] shortcut in
            self?.capture(shortcut)
        }
        shortcutField.onCancel = { [weak self] in
            self?.close()
        }
        shortcutField.onInvalidShortcut = { [weak self] message in
            self?.messageLabel.stringValue = message
        }
        shortcutField.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .regular
        cancelButton.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        cancelButton.focusRingType = .none
        cancelButton.keyEquivalent = "\u{1B}" // Esc
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        okButton.target = self
        okButton.action = #selector(okTapped)
        okButton.bezelStyle = .rounded
        okButton.controlSize = .regular
        okButton.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        okButton.focusRingType = .none
        okButton.isEnabled = false
        okButton.keyEquivalent = "\r" // Return
        okButton.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(iconColumn)
        iconColumn.addSubview(iconView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(messageLabel)
        contentView.addSubview(shortcutField)
        contentView.addSubview(cancelButton)
        contentView.addSubview(okButton)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: rootView.topAnchor, constant: Self.shadowMargin),
            glass.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: Self.shadowMargin),
            glass.widthAnchor.constraint(equalToConstant: Self.cardSize.width),
            glass.heightAnchor.constraint(equalToConstant: Self.cardSize.height),

            iconColumn.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.verticalPadding),
            iconColumn.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.horizontalPadding),
            iconColumn.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Self.verticalPadding),
            iconColumn.widthAnchor.constraint(equalToConstant: Self.iconSize.width),

            iconView.centerXAnchor.constraint(equalTo: iconColumn.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconColumn.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize.width),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize.height),

            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.verticalPadding + 1),
            titleLabel.leadingAnchor.constraint(equalTo: iconColumn.trailingAnchor, constant: Self.textGap),
            titleLabel.widthAnchor.constraint(equalToConstant: textWidth),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            messageLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            shortcutField.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 10),
            shortcutField.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            shortcutField.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            shortcutField.heightAnchor.constraint(equalToConstant: 42),

            cancelButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            cancelButton.heightAnchor.constraint(equalToConstant: 30),
            cancelButton.topAnchor.constraint(equalTo: shortcutField.bottomAnchor, constant: 10),
            cancelButton.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -Self.verticalPadding),

            okButton.leadingAnchor.constraint(equalTo: cancelButton.trailingAnchor, constant: 8),
            okButton.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            okButton.widthAnchor.constraint(equalTo: cancelButton.widthAnchor),
            okButton.heightAnchor.constraint(equalToConstant: 30),
            okButton.topAnchor.constraint(equalTo: shortcutField.bottomAnchor, constant: 10),
            okButton.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -Self.verticalPadding)
        ])
    }

    private func capture(_ shortcut: GlobalShortcut) {
        pendingShortcut = shortcut
        shortcutField.showCaptured(displayString: shortcut.displayString)
        messageLabel.stringValue = "Press OK to save this shortcut."
        okButton.isEnabled = true
    }

    @objc private func cancelTapped() {
        close()
    }

    @objc private func okTapped() {
        guard let pendingShortcut else {
            NSSound.beep()
            return
        }

        if onShortcut(pendingShortcut) {
            close()
            return
        }

        messageLabel.stringValue = "This shortcut is already used. Press another one."
        shortcutField.showConflict()
        okButton.isEnabled = false
        self.pendingShortcut = nil
    }

    private var textWidth: CGFloat {
        Self.cardSize.width
            - Self.horizontalPadding
            - Self.iconSize.width
            - Self.textGap
            - Self.horizontalPadding
    }
}

@MainActor
private final class ShortcutRecorderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// Unified shortcut capture field. Self-contained event responder + display.
// Inspired by Sindre Sorhus' KeyboardShortcuts library: clicks promote the
// view to firstResponder, while a local NSEvent monitor intercepts keyDown /
// flagsChanged at app dispatch time — more robust than the responder chain,
// and naturally swallows keys destined for AppKit's text input system.
@MainActor
private final class ShortcutCaptureFieldView: NSView {

    enum State {
        case idle      // not yet armed — shows current shortcut or "click" hint
        case recording // armed, awaiting a shortcut
        case captured  // showing a captured shortcut pending confirmation
        case conflict  // last capture was rejected; user must press another
    }

    var onCaptured: ((GlobalShortcut) -> Void)?
    var onCancel: (() -> Void)?
    var onInvalidShortcut: ((String) -> Void)?
    var onBeginRecording: (() -> Void)?

    // Text shown when the field is .idle (typically the existing shortcut).
    var idleDisplayText: String = "" {
        didSet {
            if state == .idle {
                refreshStyle()
            }
        }
    }

    private(set) var state: State = .idle {
        didSet { refreshStyle() }
    }
    private var capturedDisplayText: String = ""

    private let doubleTapInterval: TimeInterval = 0.30
    private var lastTapModifier: NSEvent.ModifierFlags?
    private var lastTapDate: Date?
    private var heldModifiers: NSEvent.ModifierFlags = []
    private var eventMonitor: Any?
    private var trackpadMonitor: TrackpadTapShortcutMonitor?

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        focusRingType = .none
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.06).cgColor

        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        refreshStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        trackpadMonitor?.stop()
    }

    // MARK: - Responder & hit testing

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // NSTextField (even label-mode) absorbs clicks on its text region with a
    // silent default mouseDown. Force every in-bounds click to land on us so
    // the user can click anywhere in the field, not just the padding.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let pointInSelf = convert(point, from: superview)
        return bounds.contains(pointInSelf) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        enterRecording()
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        startEventMonitor()
        heldModifiers = NSEvent.modifierFlags.intersection(GlobalShortcut.supportedModifiers)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        stopEventMonitor()
        // Drop recording-only states; preserve .captured across focus changes
        // so a captured shortcut survives an OK-button click.
        if state == .recording || state == .conflict {
            state = .idle
        }
        return true
    }

    private func enterRecording() {
        capturedDisplayText = ""
        heldModifiers = NSEvent.modifierFlags.intersection(GlobalShortcut.supportedModifiers)
        lastTapModifier = nil
        lastTapDate = nil
        state = .recording
        onBeginRecording?()
    }

    // MARK: - Public state setters

    func showCaptured(displayString: String) {
        capturedDisplayText = displayString
        state = .captured
    }

    func showConflict() {
        capturedDisplayText = ""
        lastTapModifier = nil
        lastTapDate = nil
        heldModifiers = NSEvent.modifierFlags.intersection(GlobalShortcut.supportedModifiers)
        state = .conflict
    }

    // MARK: - Styling

    private func refreshStyle() {
        switch state {
        case .idle:
            if idleDisplayText.isEmpty {
                label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
                label.stringValue = "Click here to set a shortcut"
            } else {
                label.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
                label.stringValue = idleDisplayText
            }
            label.textColor = .secondaryLabelColor
            setBorderColor(NSColor.separatorColor)

        case .recording:
            label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            label.stringValue = "Type a shortcut, double-tap ⌃ ⌥ ⇧ ⌘, or 3-finger tap"
            label.textColor = .secondaryLabelColor
            setBorderColor(NSColor.controlAccentColor.withAlphaComponent(0.85))

        case .captured:
            label.font = NSFont.monospacedSystemFont(ofSize: 17, weight: .semibold)
            label.stringValue = capturedDisplayText
            label.textColor = .labelColor
            setBorderColor(NSColor.controlAccentColor.withAlphaComponent(0.85))

        case .conflict:
            label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            label.stringValue = "Already used - try another"
            label.textColor = .secondaryLabelColor
            setBorderColor(NSColor.systemRed.withAlphaComponent(0.85))
        }
    }

    private func setBorderColor(_ color: NSColor) {
        layer?.borderColor = color.cgColor
    }

    // MARK: - Event monitor

    private func startEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleLocal(event)
        }
        // Touches never reach a window's event queue the way keys and clicks
        // do, so the recorder listens the same way the shortcut itself will.
        let monitor = TrackpadTapShortcutMonitor { [weak self] count in
            self?.handleTrackpadTap(fingers: count)
        }
        monitor.start()
        trackpadMonitor = monitor
    }

    private func stopEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        trackpadMonitor?.stop()
        trackpadMonitor = nil
    }

    private func handleTrackpadTap(fingers: Int) {
        guard window?.firstResponder === self, state == .recording || state == .conflict else { return }
        // One finger is the click that armed the field; two is secondary
        // click, which the system fires underneath any tap we bind.
        guard fingers >= 2 else { return }
        lastTapModifier = nil
        lastTapDate = nil
        let shortcut = GlobalShortcut(trackpadTap: UInt32(fingers))
        if shortcut.isValid {
            onCaptured?(shortcut)
        } else {
            NSSound.beep()
            onInvalidShortcut?("Tap with three, four or five fingers. Two fingers is a secondary click.")
        }
    }

    private func handleLocal(_ event: NSEvent) -> NSEvent? {
        // Only consume events while we own focus in our own window.
        guard window?.firstResponder === self else { return event }

        switch event.type {
        case .keyDown:
            if event.keyCode == UInt16(kVK_Escape) {
                onCancel?()
                return nil
            }
            // Outside recording states, swallow other keys silently — we don't
            // want the panel to ding or insert text either.
            guard state != .idle else { return nil }

            let modifiers = event.modifierFlags.intersection(GlobalShortcut.supportedModifiers)
            // A bare keystroke (no ⌃⌥⇧⌘) isn't a valid shortcut in our model,
            // so let it through to AppKit's normal dispatch — that's how the
            // OK button's Return key equivalent fires to commit a capture.
            guard !modifiers.isEmpty else {
                return event
            }

            lastTapModifier = nil
            lastTapDate = nil
            if let shortcut = GlobalShortcut(event: event) {
                onCaptured?(shortcut)
            } else {
                NSSound.beep()
                onInvalidShortcut?(
                    "Use a modifier (⌃ ⌥ ⇧ ⌘) plus a key, or quickly tap a modifier twice."
                )
            }
            return nil

        case .flagsChanged:
            handleFlagsChanged(event)
            return nil

        case .otherMouseDown:
            // A spare mouse button (middle or higher) is a valid shortcut on
            // its own. Only capture while armed — an idle field lets the
            // click pass so buttons elsewhere in the window keep working.
            guard state == .recording || state == .conflict else { return event }
            lastTapModifier = nil
            lastTapDate = nil
            onCaptured?(GlobalShortcut(mouseButton: UInt32(event.buttonNumber)))
            return nil

        default:
            return event
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection(GlobalShortcut.supportedModifiers)
        let previous = heldModifiers
        heldModifiers = mods

        guard state != .idle else { return }

        // Rising edge: a modifier just transitioned from "not held" to "held".
        let newlyPressed = mods.subtracting(previous)
        guard !newlyPressed.isEmpty else { return }

        // Only solo modifiers qualify for double-tap. Combos flow through keyDown.
        let solo = GlobalShortcut.singleModifierOptions.first { mods == $0 }
        guard let modifier = solo else {
            lastTapModifier = nil
            lastTapDate = nil
            return
        }

        let now = Date()
        if lastTapModifier == modifier,
           let when = lastTapDate,
           now.timeIntervalSince(when) <= doubleTapInterval
        {
            lastTapModifier = nil
            lastTapDate = nil
            onCaptured?(GlobalShortcut(doubleTapModifier: modifier))
        } else {
            lastTapModifier = modifier
            lastTapDate = now
        }
    }
}
