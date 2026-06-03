import AppKit
import Carbon.HIToolbox
import Foundation

enum GlobalShortcutAction: String, CaseIterable {
    case translateOrReply
    case translateSelection
    case screenshotArea
    case toggleInvisibility
    case askNugumi
    case liveTranslation

    var id: UInt32 {
        switch self {
        case .translateOrReply: return 1
        case .translateSelection: return 2
        case .screenshotArea: return 3
        case .toggleInvisibility: return 4
        case .askNugumi: return 5
        case .liveTranslation: return 6
        }
    }

    var defaultsKey: String {
        "globalShortcut.\(rawValue)"
    }

    var menuTitle: String {
        switch self {
        case .translateOrReply: return "Translate selected text"
        case .translateSelection: return "Rewrite my text"
        case .screenshotArea: return "Translate screen area"
        case .toggleInvisibility: return "Toggle invisibility mode"
        case .askNugumi: return "Ask Nugumi"
        case .liveTranslation: return "Live translation captions"
        }
    }

    var recorderTitle: String {
        "Set \(menuTitle) shortcut"
    }

    var defaultShortcut: GlobalShortcut {
        switch self {
        case .translateOrReply:
            return GlobalShortcut(
                keyCode: UInt32(kVK_ANSI_1),
                modifiers: [.control],
                keyEquivalent: "1",
                keyDisplay: "1"
            )
        case .translateSelection:
            return GlobalShortcut(
                keyCode: UInt32(kVK_ANSI_2),
                modifiers: [.control],
                keyEquivalent: "2",
                keyDisplay: "2"
            )
        case .screenshotArea:
            return GlobalShortcut(
                keyCode: UInt32(kVK_ANSI_3),
                modifiers: [.control],
                keyEquivalent: "3",
                keyDisplay: "3"
            )
        case .toggleInvisibility:
            return GlobalShortcut(
                keyCode: UInt32(kVK_ANSI_Backslash),
                modifiers: [.control, .shift],
                keyEquivalent: "\\",
                keyDisplay: "\\"
            )
        case .askNugumi:
            // Preserves the historical "double-tap Control" gesture; user can
            // rebind to any combo or another double-tap modifier from the menu.
            return GlobalShortcut(doubleTapModifier: .control)
        case .liveTranslation:
            return GlobalShortcut(
                keyCode: UInt32(kVK_ANSI_4),
                modifiers: [.control],
                keyEquivalent: "4",
                keyDisplay: "4"
            )
        }
    }
}

struct GlobalShortcut: Codable, Equatable {
    static let supportedModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    static let singleModifierOptions: [NSEvent.ModifierFlags] = [.control, .option, .shift, .command]

    enum Kind: String, Codable {
        case combo
        case doubleTap
    }

    let kind: Kind
    let keyCode: UInt32
    private let modifiersRawValue: UInt
    let keyEquivalent: String
    let keyDisplay: String

    init(
        keyCode: UInt32,
        modifiers: NSEvent.ModifierFlags,
        keyEquivalent: String,
        keyDisplay: String
    ) {
        self.kind = .combo
        self.keyCode = keyCode
        self.modifiersRawValue = modifiers.intersection(Self.supportedModifiers).rawValue
        self.keyEquivalent = keyEquivalent
        self.keyDisplay = keyDisplay
    }

    init(doubleTapModifier modifier: NSEvent.ModifierFlags) {
        self.kind = .doubleTap
        self.keyCode = 0
        self.modifiersRawValue = modifier.intersection(Self.supportedModifiers).rawValue
        self.keyEquivalent = ""
        self.keyDisplay = ""
    }

    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(Self.supportedModifiers)
        guard !modifiers.isEmpty else {
            return nil
        }

        let characters = event.charactersIgnoringModifiers
        let keyDisplay = ShortcutKeyFormatter.displayName(
            keyCode: UInt32(event.keyCode),
            characters: characters
        )
        guard !keyDisplay.isEmpty else {
            return nil
        }

        self.init(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers,
            keyEquivalent: ShortcutKeyFormatter.menuEquivalent(
                keyCode: UInt32(event.keyCode),
                characters: characters
            ),
            keyDisplay: keyDisplay
        )
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case keyCode
        case modifiersRawValue
        case keyEquivalent
        case keyDisplay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Old encodings (pre-Ask-Nugumi) have no `kind` field — treat as .combo.
        self.kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .combo
        self.keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        self.modifiersRawValue = try container.decode(UInt.self, forKey: .modifiersRawValue)
        self.keyEquivalent = try container.decode(String.self, forKey: .keyEquivalent)
        self.keyDisplay = try container.decode(String.self, forKey: .keyDisplay)
    }

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiersRawValue).intersection(Self.supportedModifiers)
    }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.control) {
            result |= UInt32(controlKey)
        }
        if modifiers.contains(.option) {
            result |= UInt32(optionKey)
        }
        if modifiers.contains(.shift) {
            result |= UInt32(shiftKey)
        }
        if modifiers.contains(.command) {
            result |= UInt32(cmdKey)
        }
        return result
    }

    var menuKeyEquivalent: String {
        kind == .combo ? keyEquivalent : ""
    }

    var keyEquivalentModifierMask: NSEvent.ModifierFlags {
        kind == .combo ? modifiers : []
    }

    var displayString: String {
        let modifierGlyphs = Self.modifierGlyphs(for: modifiers)
        switch kind {
        case .combo:
            return modifierGlyphs + keyDisplay
        case .doubleTap:
            // "⌃⌃" / "⌥⌥" / "⇧⇧" / "⌘⌘"
            return modifierGlyphs + modifierGlyphs
        }
    }

    var isValid: Bool {
        switch kind {
        case .combo:
            return !modifiers.isEmpty && !keyDisplay.isEmpty
        case .doubleTap:
            return Self.singleModifierOptions.contains { modifiers == $0 }
        }
    }

    private static func modifierGlyphs(for modifiers: NSEvent.ModifierFlags) -> String {
        var prefix = ""
        if modifiers.contains(.control) {
            prefix += "⌃"
        }
        if modifiers.contains(.option) {
            prefix += "⌥"
        }
        if modifiers.contains(.shift) {
            prefix += "⇧"
        }
        if modifiers.contains(.command) {
            prefix += "⌘"
        }
        return prefix
    }

    static func == (lhs: GlobalShortcut, rhs: GlobalShortcut) -> Bool {
        guard lhs.kind == rhs.kind, lhs.modifiers == rhs.modifiers else {
            return false
        }
        switch lhs.kind {
        case .combo:
            return lhs.keyCode == rhs.keyCode
        case .doubleTap:
            return true
        }
    }
}

@MainActor
final class DoubleModifierPressDetector {
    private let modifier: NSEvent.ModifierFlags
    private let interval: TimeInterval
    private let onDetected: @MainActor () -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastDownDate: Date?
    private var wasDown = false
    var isEnabled = true {
        didSet {
            if isEnabled != oldValue {
                resetState()
            }
        }
    }

    init(
        modifier: NSEvent.ModifierFlags,
        interval: TimeInterval = 0.30,
        onDetected: @escaping @MainActor () -> Void
    ) {
        self.modifier = modifier.intersection(GlobalShortcut.supportedModifiers)
        self.interval = interval
        self.onDetected = onDetected
    }

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        // Global monitor: fires only while ANOTHER app is frontmost.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
        // Local monitor: fires while Nugumi itself is the active app (e.g.
        // right after the pet prompt was shown and clicked). Without this the
        // detector goes deaf once the app activates and never recovers until
        // another app regains focus. Must return the event unmodified.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        resetState()
    }

    private func resetState() {
        lastDownDate = nil
        wasDown = false
    }

    private func handle(_ event: NSEvent) {
        guard isEnabled else { return }

        let active = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // The modifier is "down" only if it is the SOLE supported modifier
        // currently pressed — combos like Cmd+Ctrl should not feed the detector.
        let supportedActive = active.intersection(GlobalShortcut.supportedModifiers)
        let isDown = supportedActive == modifier
        defer { wasDown = isDown }
        guard isDown, !wasDown else { return }

        let now = Date()
        if let last = lastDownDate, now.timeIntervalSince(last) <= interval {
            lastDownDate = nil
            onDetected()
        } else {
            lastDownDate = now
        }
    }
}

enum GlobalShortcutStore {
    static func shortcut(
        for action: GlobalShortcutAction,
        defaults: UserDefaults = .standard
    ) -> GlobalShortcut {
        guard let data = defaults.data(forKey: action.defaultsKey),
              let shortcut = try? JSONDecoder().decode(GlobalShortcut.self, from: data),
              shortcut.isValid
        else {
            return action.defaultShortcut
        }
        return shortcut
    }

    static func set(
        _ shortcut: GlobalShortcut,
        for action: GlobalShortcutAction,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(shortcut) else {
            return
        }
        defaults.set(data, forKey: action.defaultsKey)
    }

    static func resetToDefaults(defaults: UserDefaults = .standard) {
        for action in GlobalShortcutAction.allCases {
            defaults.removeObject(forKey: action.defaultsKey)
        }
    }
}

@MainActor
final class ShortcutRecorderWindowController: NSWindowController, NSWindowDelegate {
    private static let horizontalPadding: CGFloat = 16
    private static let verticalPadding: CGFloat = 16
    private static let shadowMargin: CGFloat = 30
    private static let cornerRadius: CGFloat = 28
    private static let mascotSize = NSSize(width: 42, height: 34)
    private static let textGap: CGFloat = 10
    private static let cardSize = NSSize(width: 450, height: 176)
    private static let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    private static let messageFont = NSFont.systemFont(ofSize: 12, weight: .regular)

    private let action: GlobalShortcutAction
    private let currentShortcut: GlobalShortcut
    private let onShortcut: (GlobalShortcut) -> Bool
    private let onClose: () -> Void
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let shortcutField = ShortcutCaptureFieldView()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let okButton = NSButton(title: "OK", target: nil, action: nil)
    private var pendingShortcut: GlobalShortcut?

    init(
        action: GlobalShortcutAction,
        currentShortcut: GlobalShortcut,
        onShortcut: @escaping (GlobalShortcut) -> Bool,
        onClose: @escaping () -> Void
    ) {
        self.action = action
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

        let mascotColumn = NSView()
        mascotColumn.translatesAutoresizingMaskIntoConstraints = false

        let mascotView = PetMascotView(frame: NSRect(origin: .zero, size: Self.mascotSize))
        mascotView.apply(state: .idle, mode: .selection)
        mascotView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "Set shortcut")
        titleLabel.font = Self.titleFont
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.stringValue = "Click the field, then press keys for \(action.menuTitle) — or double-tap ⌃ ⌥ ⇧ ⌘."
        messageLabel.font = Self.messageFont
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 0
        messageLabel.preferredMaxLayoutWidth = textWidth
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        shortcutField.idleDisplayText = currentShortcut.displayString
        shortcutField.onBeginRecording = { [weak self] in
            guard let self else { return }
            self.pendingShortcut = nil
            self.okButton.isEnabled = false
            self.messageLabel.stringValue = "Press the new shortcut now, or double-tap ⌃ ⌥ ⇧ ⌘."
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

        contentView.addSubview(mascotColumn)
        mascotColumn.addSubview(mascotView)
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
            - Self.mascotSize.width
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
            label.stringValue = "Type a shortcut — or double-tap ⌃ ⌥ ⇧ ⌘"
            label.textColor = .secondaryLabelColor
            setBorderColor(NSColor.controlAccentColor.withAlphaComponent(0.85))

        case .captured:
            label.font = NSFont.monospacedSystemFont(ofSize: 17, weight: .semibold)
            label.stringValue = capturedDisplayText
            label.textColor = .labelColor
            setBorderColor(NSColor.controlAccentColor.withAlphaComponent(0.85))

        case .conflict:
            label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            label.stringValue = "Already used — try another"
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
            matching: [.keyDown, .flagsChanged]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleLocal(event)
        }
    }

    private func stopEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
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

private enum ShortcutKeyFormatter {
    static func displayName(keyCode: UInt32, characters: String?) -> String {
        if let name = displayNames[keyCode] {
            return name
        }

        guard let characters, !characters.isEmpty else {
            return ""
        }

        return characters.uppercased()
    }

    static func menuEquivalent(keyCode: UInt32, characters: String?) -> String {
        if let equivalent = menuEquivalents[keyCode] {
            return equivalent
        }

        return characters?.lowercased() ?? ""
    }

    private static let displayNames: [UInt32: String] = [
        UInt32(kVK_Return): "Return",
        UInt32(kVK_Tab): "Tab",
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Delete): "Delete",
        UInt32(kVK_Escape): "Esc",
        UInt32(kVK_Command): "Command",
        UInt32(kVK_Shift): "Shift",
        UInt32(kVK_CapsLock): "Caps Lock",
        UInt32(kVK_Option): "Option",
        UInt32(kVK_Control): "Control",
        UInt32(kVK_RightCommand): "Command",
        UInt32(kVK_RightShift): "Shift",
        UInt32(kVK_RightOption): "Option",
        UInt32(kVK_RightControl): "Control",
        UInt32(kVK_F1): "F1",
        UInt32(kVK_F2): "F2",
        UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5",
        UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7",
        UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10",
        UInt32(kVK_F11): "F11",
        UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13",
        UInt32(kVK_F14): "F14",
        UInt32(kVK_F15): "F15",
        UInt32(kVK_F16): "F16",
        UInt32(kVK_F17): "F17",
        UInt32(kVK_F18): "F18",
        UInt32(kVK_F19): "F19",
        UInt32(kVK_F20): "F20",
        UInt32(kVK_Home): "Home",
        UInt32(kVK_End): "End",
        UInt32(kVK_PageUp): "Page Up",
        UInt32(kVK_PageDown): "Page Down",
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_UpArrow): "↑"
    ]

    private static let menuEquivalents: [UInt32: String] = [
        UInt32(kVK_Return): "\r",
        UInt32(kVK_Tab): "\t",
        UInt32(kVK_Space): " ",
        UInt32(kVK_Delete): "\u{8}",
        UInt32(kVK_Escape): "\u{1B}",
        UInt32(kVK_LeftArrow): String(UnicodeScalar(NSLeftArrowFunctionKey)!),
        UInt32(kVK_RightArrow): String(UnicodeScalar(NSRightArrowFunctionKey)!),
        UInt32(kVK_DownArrow): String(UnicodeScalar(NSDownArrowFunctionKey)!),
        UInt32(kVK_UpArrow): String(UnicodeScalar(NSUpArrowFunctionKey)!)
    ]
}
