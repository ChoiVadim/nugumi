import AppKit
import Combine
import Foundation

enum SnippetKind: String, Codable, CaseIterable {
    case snippet
    case dictionaryTerm

    var displayName: String {
        switch self {
        case .snippet: return "Snippet"
        case .dictionaryTerm: return "Word"
        }
    }
}

struct Snippet: Codable, Identifiable, Equatable {
    let id: UUID
    var kind: SnippetKind
    var trigger: String
    var value: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: SnippetKind = .snippet,
        trigger: String = "",
        value: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.trigger = trigger
        self.value = kind == .dictionaryTerm ? "" : value
        self.createdAt = createdAt
    }

    var isUsable: Bool {
        let trigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .snippet:
            return !trigger.isEmpty && !value.isEmpty
        case .dictionaryTerm:
            return !trigger.isEmpty
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case trigger
        case value
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        trigger = try container.decode(String.self, forKey: .trigger)
        value = try container.decode(String.self, forKey: .value)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        if let kind = try container.decodeIfPresent(SnippetKind.self, forKey: .kind) {
            self.kind = kind
        } else {
            self.kind = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .dictionaryTerm
                : .snippet
        }
        if self.kind == .dictionaryTerm {
            value = ""
        }
    }
}

@MainActor
final class SnippetsStore: ObservableObject {
    @Published private(set) var snippets: [Snippet] = []
    var onChange: (() -> Void)?

    private static let defaultsKey = "snippets"

    init() {
        load()
    }

    @discardableResult
    func add(kind: SnippetKind) -> Snippet {
        let snippet = Snippet(kind: kind)
        snippets.append(snippet)
        save()
        onChange?()
        return snippet
    }

    func update(_ id: UUID, trigger: String? = nil, value: String? = nil) {
        guard let idx = snippets.firstIndex(where: { $0.id == id }) else { return }
        if let trigger { snippets[idx].trigger = trigger }
        if let value {
            snippets[idx].value = snippets[idx].kind == .dictionaryTerm ? "" : value
        }
        save()
        onChange?()
    }

    func delete(_ id: UUID) {
        snippets.removeAll { $0.id == id }
        save()
        onChange?()
    }

    func usableSnippets() -> [Snippet] {
        snippets.filter(\.isUsable)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([Snippet].self, from: data)
        else { return }
        snippets = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

@MainActor
private final class SnippetsWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown else {
            super.sendEvent(event)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command,
              let key = event.charactersIgnoringModifiers?.lowercased()
        else {
            super.sendEvent(event)
            return
        }

        let selector: Selector?
        switch key {
        case "a":
            selector = #selector(NSText.selectAll(_:))
        case "c":
            selector = #selector(NSText.copy(_:))
        case "v":
            selector = #selector(NSText.paste(_:))
        case "x":
            selector = #selector(NSText.cut(_:))
        default:
            selector = nil
        }

        guard let selector else {
            super.sendEvent(event)
            return
        }

        if let responder = firstResponder, responder.responds(to: selector) {
            responder.perform(selector, with: self)
            return
        }

        super.sendEvent(event)
    }
}

@MainActor
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class SnippetsWindowController: NSWindowController, NSWindowDelegate {
    private let store: SnippetsStore
    private let onClose: () -> Void
    private let stack = NSStackView()
    private let snippetRowsStack = NSStackView()
    private let dictionaryRowsStack = NSStackView()
    private var rows: [UUID: SnippetRow] = [:]

    init(store: SnippetsStore, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose

        let window = SnippetsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 560),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Gizmate snippets & dictionary"
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 480, height: 400)
        window.center()

        super.init(window: window)
        window.delegate = self
        buildUI()
        rebuildRows()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func presentAndFocus() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        guard let rootView = window?.contentView else { return }
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor

        let glass = GlassHostView(
            frame: rootView.bounds,
            cornerRadius: 18,
            tintColor: nil,
            style: .regular
        )
        glass.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(glass)
        let contentView = glass.contentView

        let title = NSTextField(labelWithString: "Snippets & dictionary")
        title.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(wrappingLabelWithString:
            "Snippets expand phrases while writing. Dictionary words are preserved exactly.")
        subtitle.font = NSFont.systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        configureRowsStack(snippetRowsStack)
        configureRowsStack(dictionaryRowsStack)

        let snippetsHeader = makeSectionHeader(
            title: "Snippets",
            subtitle: "Short phrases Gizmate expands before rewriting.",
            buttonTitle: "+ Add snippet",
            action: #selector(addSnippetTapped)
        )
        let dictionaryHeader = makeSectionHeader(
            title: "Dictionary",
            subtitle: "Words and names Gizmate keeps exactly as written.",
            buttonTitle: "+ Add word",
            action: #selector(addWordTapped)
        )
        stack.addArrangedSubview(snippetsHeader)
        stack.addArrangedSubview(snippetRowsStack)
        stack.addArrangedSubview(dictionaryHeader)
        stack.addArrangedSubview(dictionaryRowsStack)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let documentView = FlippedDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        scroll.documentView = documentView

        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),

            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor)
        ])
        snippetsHeader.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        snippetRowsStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        dictionaryHeader.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        dictionaryRowsStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        contentView.addSubview(title)
        contentView.addSubview(subtitle)
        contentView.addSubview(scroll)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: rootView.topAnchor),
            glass.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            title.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 56),
            title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            scroll.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])
    }

    private func configureRowsStack(_ stack: NSStackView) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
    }

    private func makeSectionHeader(
        title: String,
        subtitle: String,
        buttonTitle: String,
        action: Selector
    ) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let button = NSButton(title: buttonTitle, target: self, action: action)
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(textStack)
        container.addSubview(button)

        NSLayoutConstraint.activate([
            textStack.topAnchor.constraint(equalTo: container.topAnchor),
            textStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -12),
            textStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: textStack.centerYAnchor),
            button.heightAnchor.constraint(equalToConstant: 28)
        ])

        return container
    }

    private func rebuildRows() {
        for view in snippetRowsStack.arrangedSubviews {
            snippetRowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for view in dictionaryRowsStack.arrangedSubviews {
            dictionaryRowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rows.removeAll()

        for snippet in store.snippets {
            appendRow(for: snippet)
        }
    }

    @discardableResult
    private func appendRow(for snippet: Snippet) -> SnippetRow {
        let row = SnippetRow(snippet: snippet) { [weak self] trigger, value in
            self?.store.update(snippet.id, trigger: trigger, value: value)
        } onDelete: { [weak self] in
            guard let self else { return }
            self.store.delete(snippet.id)
            if let row = self.rows.removeValue(forKey: snippet.id) {
                if let parent = row.superview as? NSStackView {
                    parent.removeArrangedSubview(row)
                }
                row.removeFromSuperview()
            }
        }
        let parent = snippet.kind == .snippet ? snippetRowsStack : dictionaryRowsStack
        parent.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: parent.widthAnchor).isActive = true
        rows[snippet.id] = row
        return row
    }

    @objc private func addSnippetTapped() {
        add(kind: .snippet)
    }

    @objc private func addWordTapped() {
        add(kind: .dictionaryTerm)
    }

    private func add(kind: SnippetKind) {
        let snippet = store.add(kind: kind)
        let row = appendRow(for: snippet)
        DispatchQueue.main.async {
            row.focusTrigger()
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.onClose()
        }
    }
}

@MainActor
private final class ShortcutTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command,
              let key = event.charactersIgnoringModifiers?.lowercased()
        else {
            return super.performKeyEquivalent(with: event)
        }

        let selector: Selector?
        switch key {
        case "a":
            selector = #selector(NSText.selectAll(_:))
        case "c":
            selector = #selector(NSText.copy(_:))
        case "v":
            selector = #selector(NSText.paste(_:))
        case "x":
            selector = #selector(NSText.cut(_:))
        default:
            selector = nil
        }

        guard let selector else {
            return super.performKeyEquivalent(with: event)
        }

        if let editor = currentEditor(), editor.responds(to: selector) {
            editor.perform(selector, with: self)
            return true
        }

        return NSApp.sendAction(selector, to: nil, from: self)
    }
}

@MainActor
private final class SnippetRow: NSView, NSTextFieldDelegate {
    private let kind: SnippetKind
    private let kindLabel: NSTextField
    private let triggerField = ShortcutTextField()
    private let valueField = ShortcutTextField()
    private let actionButton = NSButton(title: "✕", target: nil, action: nil)
    private var isEditing = false
    private let onUpdate: (_ trigger: String, _ value: String) -> Void
    private let onDelete: () -> Void

    init(
        snippet: Snippet,
        onUpdate: @escaping (_ trigger: String, _ value: String) -> Void,
        onDelete: @escaping () -> Void
    ) {
        kind = snippet.kind
        kindLabel = NSTextField(labelWithString: snippet.kind.displayName)
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        kindLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        kindLabel.textColor = .secondaryLabelColor
        kindLabel.alignment = .right
        kindLabel.translatesAutoresizingMaskIntoConstraints = false

        triggerField.placeholderString = snippet.kind == .snippet ? "Trigger phrase…" : "Word or name…"
        triggerField.stringValue = snippet.trigger
        triggerField.font = NSFont.systemFont(ofSize: 12)
        triggerField.bezelStyle = .roundedBezel
        triggerField.delegate = self
        triggerField.target = self
        triggerField.action = #selector(commitField(_:))
        triggerField.translatesAutoresizingMaskIntoConstraints = false

        let arrow = NSTextField(labelWithString: "→")
        arrow.font = NSFont.systemFont(ofSize: 13)
        arrow.textColor = .tertiaryLabelColor
        arrow.translatesAutoresizingMaskIntoConstraints = false

        valueField.placeholderString = "Expansion…"
        valueField.stringValue = snippet.value
        valueField.font = NSFont.systemFont(ofSize: 12)
        valueField.bezelStyle = .roundedBezel
        valueField.delegate = self
        valueField.target = self
        valueField.action = #selector(commitField(_:))
        valueField.translatesAutoresizingMaskIntoConstraints = false

        actionButton.target = self
        actionButton.action = #selector(actionTapped)
        actionButton.bezelStyle = .roundRect
        actionButton.controlSize = .small
        actionButton.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        actionButton.refusesFirstResponder = true
        actionButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(kindLabel)
        addSubview(triggerField)
        addSubview(actionButton)

        var constraints: [NSLayoutConstraint] = [
            kindLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            kindLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            kindLabel.widthAnchor.constraint(equalToConstant: 64),

            triggerField.leadingAnchor.constraint(equalTo: kindLabel.trailingAnchor, constant: 8),
            triggerField.centerYAnchor.constraint(equalTo: centerYAnchor),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.widthAnchor.constraint(equalToConstant: 28),

            heightAnchor.constraint(equalToConstant: 30)
        ]

        switch snippet.kind {
        case .snippet:
            addSubview(arrow)
            addSubview(valueField)
            constraints.append(contentsOf: [
                triggerField.widthAnchor.constraint(equalToConstant: 150),

                arrow.leadingAnchor.constraint(equalTo: triggerField.trailingAnchor, constant: 8),
                arrow.centerYAnchor.constraint(equalTo: centerYAnchor),

                valueField.leadingAnchor.constraint(equalTo: arrow.trailingAnchor, constant: 8),
                valueField.centerYAnchor.constraint(equalTo: centerYAnchor),
                valueField.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -8)
            ])
        case .dictionaryTerm:
            constraints.append(
                triggerField.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -8)
            )
        }

        NSLayoutConstraint.activate(constraints)
        updateActionButton()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func focusTrigger() {
        window?.makeFirstResponder(triggerField)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        isEditing = true
        updateActionButton()
    }

    func controlTextDidChange(_ obj: Notification) {
        isEditing = true
        updateActionButton()
        save()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        save()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isEditing = false
            self.updateActionButton()
        }
    }

    @objc private func commitField(_ sender: NSTextField) {
        save()
        isEditing = false
        updateActionButton()
        window?.makeFirstResponder(nil)
    }

    @objc private func actionTapped() {
        if isEditing {
            save()
            isEditing = false
            updateActionButton()
            window?.makeFirstResponder(nil)
        } else {
            onDelete()
        }
    }

    private func save() {
        onUpdate(triggerField.stringValue, kind == .dictionaryTerm ? "" : valueField.stringValue)
    }

    private func updateActionButton() {
        actionButton.title = isEditing ? "✓" : "✕"
        actionButton.contentTintColor = isEditing ? .gizmateAccent : nil
        actionButton.toolTip = isEditing ? "Save" : "Delete"
    }
}
