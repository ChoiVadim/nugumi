import AppKit
import Combine
import Foundation

/// Where a prompt tool's answer goes once the model is done.
enum PromptToolResult: String, Codable, CaseIterable {
    /// The usual result panel, with the language selector and follow-up field.
    case panel
    /// Types the answer straight back over the selection, no panel.
    case replace
    /// Copies the answer to the clipboard and says so in a notification.
    case clipboard

    var displayName: String {
        switch self {
        case .panel: return "Show panel"
        case .replace: return "Replace text"
        case .clipboard: return "Copy"
        }
    }

    var explanation: String {
        switch self {
        case .panel:
            return "Opens the result panel, where you can revise the answer or copy it."
        case .replace:
            return "Types the answer over your selection, like Rewrite does."
        case .clipboard:
            return "Puts the answer on the clipboard without showing a panel."
        }
    }
}

/// A user-authored ring action: one system prompt run over the current
/// selection, with the answer routed by `result`. Deliberately data only — no
/// code, no shell, no file access — so a tool can never reach further than the
/// built-in text actions already do.
struct PromptTool: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    /// SF Symbol name from `PromptToolIcons.all`. Built-in ring actions keep
    /// their bundled Phosphor glyphs; user tools draw from SF Symbols.
    var symbolName: String
    var prompt: String
    var result: PromptToolResult
    /// Appends "Write the output in <target language>." to the prompt. Right for
    /// rewriting and explaining; wrong for language-agnostic transforms (text →
    /// JSON, extract the dates), where a language instruction corrupts the output.
    var appliesTargetLanguage: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String = "",
        symbolName: String = PromptToolIcons.fallback,
        prompt: String = "",
        result: PromptToolResult = .panel,
        appliesTargetLanguage: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.prompt = prompt
        self.result = result
        self.appliesTargetLanguage = appliesTargetLanguage
        self.createdAt = createdAt
    }

    /// A tool with no name or no prompt can't run: the ring skips it and the
    /// Ring tab shows it as unfinished.
    var isUsable: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The saved symbol, or the fallback when a name no longer resolves (the
    /// user edited defaults by hand, or an SF Symbol vanished across an OS).
    var resolvedSymbolName: String {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) != nil
            ? symbolName
            : PromptToolIcons.fallback
    }

    // Lenient decoding, same reasoning as `Snippet`: a field added in a later
    // version must not throw away every tool the user already saved.
    private enum CodingKeys: String, CodingKey {
        case id, name, symbolName, prompt, result, appliesTargetLanguage, createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        symbolName = try container.decodeIfPresent(String.self, forKey: .symbolName)
            ?? PromptToolIcons.fallback
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        result = try container.decodeIfPresent(PromptToolResult.self, forKey: .result) ?? .panel
        appliesTargetLanguage = try container
            .decodeIfPresent(Bool.self, forKey: .appliesTargetLanguage) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

/// The user's prompt tools, persisted in UserDefaults. Same shape and contract
/// as `SnippetsStore` — `onChange` lets the app delegate react (the ring reads
/// the list fresh every time it opens, so nothing else needs invalidating).
@MainActor
final class PromptToolsStore: ObservableObject {
    @Published private(set) var tools: [PromptTool] = []
    var onChange: (() -> Void)?

    private static let defaultsKey = "promptTools"

    init() {
        load()
    }

    func tool(id: UUID) -> PromptTool? {
        tools.first { $0.id == id }
    }

    @discardableResult
    func add(_ tool: PromptTool) -> PromptTool {
        tools.append(tool)
        save()
        onChange?()
        return tool
    }

    func update(_ tool: PromptTool) {
        guard let idx = tools.firstIndex(where: { $0.id == tool.id }) else { return }
        tools[idx] = tool
        save()
        onChange?()
    }

    func delete(_ id: UUID) {
        tools.removeAll { $0.id == id }
        save()
        onChange?()
    }

    func usableTools() -> [PromptTool] {
        tools.filter(\.isUsable)
    }

    /// Settings ▸ Reset — drop every tool and forget the key.
    func reset() {
        tools = []
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        onChange?()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([PromptTool].self, from: data)
        else { return }
        tools = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tools) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
