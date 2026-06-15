import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreServices
import CoreText
import Darwin
import Foundation
import Sparkle
import SwiftUI
import UserNotifications
import Vision

private enum MenuItemTag: Int {
    case permissionNotice = 100
    case accessibilitySettings = 101
    case permissionSeparator = 102
    case targetLanguage = 103
    case quit = 104
    case bootstrapNotice = 105
    case bootstrapAction = 106
    case bootstrapSeparator = 107
    case screenshotArea = 108
    case translateSelection = 109
    case draftTargetLanguage = 110
    case floatingDefaultMode = 111
    case thinkingLevel = 112
    case selectedModel = 113
    case checkForUpdates = 114
    case selectionDisplayMode = 115
    case usageStatsSummary = 116
    case writingStyle = 117
    case cleanupLevel = 118
    case snippets = 119
    case replacementMode = 120
    case keyboardShortcuts = 121
    case translateOrReplySelection = 122
    case resetSettings = 123
    case invisibilityMode = 124
    case contactSupport = 125
    case permissionsOnboarding = 126
    case mainWindow = 127
}

enum InvisibilityState {
    static let defaultsKey = "invisibilityModeEnabled"
    static let firstRunShownKey = "invisibilityModeFirstRunShown"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static var currentSharingType: NSWindow.SharingType {
        isEnabled ? .none : .readOnly
    }

    static func apply(to window: NSWindow) {
        window.sharingType = currentSharingType
    }

    @MainActor
    static func applyToAllOpenWindows() {
        let type = currentSharingType
        for window in NSApp.windows {
            window.sharingType = type
        }
    }
}

enum BackendKind: Equatable {
    case ollama(requiresAccount: Bool)
    case cloud(CloudProvider)
}

struct LLMModel: Equatable {
    let id: String
    let apiModelID: String
    let shortName: String
    let displayName: String
    let backend: BackendKind
    let supportsImages: Bool

    init(
        id: String,
        apiModelID: String? = nil,
        shortName: String,
        displayName: String,
        backend: BackendKind,
        supportsImages: Bool
    ) {
        self.id = id
        self.apiModelID = apiModelID ?? id
        self.shortName = shortName
        self.displayName = displayName
        self.backend = backend
        self.supportsImages = supportsImages
    }

    var isCloud: Bool {
        if case .ollama(let requiresAccount) = backend { return requiresAccount }
        return false
    }

    var isOllama: Bool {
        if case .ollama = backend { return true }
        return false
    }

    var cloudProvider: CloudProvider? {
        if case .cloud(let provider) = backend { return provider }
        return nil
    }

    // Models are grouped by provider in the picker, so display names omit the
    // provider (it's the section header) and keep only the speed/tier hint.
    static let all: [LLMModel] = [
        // Ollama — curated defaults shown under their real model names, matching
        // whatever `/api/tags` discovers (see makeOllamaModel).
        .init(id: "gpt-oss:120b-cloud", shortName: "gpt-oss:120b", displayName: "gpt-oss:120b", backend: .ollama(requiresAccount: true),  supportsImages: false),
        .init(id: "gpt-oss:20b",        shortName: "gpt-oss:20b",  displayName: "gpt-oss:20b",  backend: .ollama(requiresAccount: false), supportsImages: false),
        // The one curated local vision model, so Ask Nugumi works on a
        // pure-Ollama setup (gpt-oss has no vision). Bare tag on purpose:
        // `ollama pull gemma4` registers as "gemma4:latest", and the two
        // spellings are unified via canonicalOllamaID.
        .init(id: "gemma4",             shortName: "Gemma 4",      displayName: "Gemma 4 (vision)", backend: .ollama(requiresAccount: false), supportsImages: true),
        // OpenAI (GPT-5 family, all vision-capable)
        .init(id: "gpt-5.4-mini", shortName: "GPT-5.4 mini", displayName: "GPT-5.4 mini (fast)",  backend: .cloud(.openAI), supportsImages: true),
        .init(id: "gpt-5.4",      shortName: "GPT-5.4",      displayName: "GPT-5.4 (affordable)", backend: .cloud(.openAI), supportsImages: true),
        .init(id: "gpt-5.5",      shortName: "GPT-5.5",      displayName: "GPT-5.5 (flagship)",   backend: .cloud(.openAI), supportsImages: true),
        // Anthropic
        .init(id: "claude-haiku-4-5-20251001", shortName: "Claude Haiku 4.5",  displayName: "Claude Haiku 4.5 (fast)",  backend: .cloud(.anthropic), supportsImages: true),
        .init(id: "claude-sonnet-4-6",         shortName: "Claude Sonnet 4.6", displayName: "Claude Sonnet 4.6",        backend: .cloud(.anthropic), supportsImages: true),
        .init(id: "claude-opus-4-7",           shortName: "Claude Opus 4.7",   displayName: "Claude Opus 4.7 (top)",    backend: .cloud(.anthropic), supportsImages: true),
        // Gemini
        .init(id: "gemini-2.5-flash-lite", shortName: "Gemini 2.5 Flash Lite", displayName: "Gemini 2.5 Flash Lite (fastest)", backend: .cloud(.gemini), supportsImages: true),
        .init(id: "gemini-2.5-flash",      shortName: "Gemini 2.5 Flash",      displayName: "Gemini 2.5 Flash",                backend: .cloud(.gemini), supportsImages: true),
        .init(id: "gemini-2.5-pro",        shortName: "Gemini 2.5 Pro",        displayName: "Gemini 2.5 Pro (top)",            backend: .cloud(.gemini), supportsImages: true),
    ]

    /// Curated Ollama defaults (gpt-oss cloud + local). Always shown, even
    /// before the server reports anything, so users know the baseline.
    static let curatedOllamaModels = all.filter(\.isOllama)
    static let apiKeyModels = all.filter { $0.cloudProvider != nil }

    /// Models for one cloud provider, in `all` order. The picker headers use
    /// `CloudProvider.displayName`, so the section names match Cloud access.
    static func models(for provider: CloudProvider) -> [LLMModel] {
        apiKeyModels.filter { $0.cloudProvider == provider }
    }

    /// Picker list for one API-key provider: curated entries (with their
    /// hand-written names and tier hints) confirmed by the last successful
    /// /models fetch, followed by fetched chat models we don't curate yet.
    /// Never fetched → curated list unchanged.
    static func cloudModels(for provider: CloudProvider) -> [LLMModel] {
        mergedCloudModels(
            provider: provider,
            curated: models(for: provider),
            discovered: CloudModelCache.discovered(for: provider)
        )
    }

    /// Pure merge (testable without UserDefaults). Matching is canonical-id
    /// based so Anthropic's dated/undated aliases compare equal. Fresh models
    /// sort descending by id (numeric-aware, so 4-10 outranks 4-9) — within
    /// one provider's naming scheme that puts
    /// newer versions first — and default to supportsImages like Codex
    /// discovery does (backend rejects images for text-only models; hiding
    /// usable models is worse).
    static func mergedCloudModels(
        provider: CloudProvider,
        curated: [LLMModel],
        discovered: [CloudModelDiscovery.DiscoveredModel]?
    ) -> [LLMModel] {
        guard let discovered, !discovered.isEmpty else { return curated }
        let fetchedIDs = Set(discovered.map { CloudModelDiscovery.canonicalID($0.id) })
        let curatedIDs = Set(curated.map { CloudModelDiscovery.canonicalID($0.apiModelID) })

        var out = curated.filter {
            fetchedIDs.contains(CloudModelDiscovery.canonicalID($0.apiModelID))
        }
        let fresh = discovered
            .filter { !curatedIDs.contains(CloudModelDiscovery.canonicalID($0.id)) }
            .sorted { $0.id.compare($1.id, options: .numeric) == .orderedDescending }
        out += fresh.map { model in
            let name = model.displayName
                ?? CloudModelDiscovery.prettyName(provider: provider, id: model.id)
            return LLMModel(
                id: model.id,
                shortName: name,
                displayName: name,
                backend: .cloud(provider),
                supportsImages: true
            )
        }
        return out
    }

    /// All Ollama models to offer: the curated Online/Offline defaults, then
    /// whatever the running server reported via `/api/tags` (see
    /// OllamaModelCache). When signed in, the server already lists the cloud
    /// catalog, so there's no hand-maintained cloud list to drift or collide
    /// with the curated entries. Deduped by id, curated entries win.
    static var ollamaModels: [LLMModel] {
        var seen = Set<String>()
        var out: [LLMModel] = []
        func add(_ model: LLMModel) {
            if seen.insert(canonicalOllamaID(model.id)).inserted { out.append(model) }
        }
        curatedOllamaModels.forEach(add)
        OllamaModelCache.discovered.map(makeOllamaModel).forEach(add)
        return out
    }

    /// Ollama treats a bare tag and ":latest" as the same model — "gemma4"
    /// pulls and lists as "gemma4:latest". Compare ids in this canonical form
    /// so curated entries match what `/api/tags` reports.
    static func canonicalOllamaID(_ id: String) -> String {
        id.hasSuffix(":latest") ? String(id.dropLast(":latest".count)) : id
    }

    /// Build an LLMModel for a raw Ollama model name (as it appears in
    /// `ollama list` / `/api/tags`). Cloud models carry either a `-cloud` or a
    /// `:cloud` suffix (e.g. `gpt-oss:120b-cloud`, `glm-5.1:cloud`).
    private static func makeOllamaModel(name: String) -> LLMModel {
        let isCloud = name.hasSuffix("-cloud") || name.hasSuffix(":cloud")
        let short = name
            .replacingOccurrences(of: "-cloud", with: "")
            .replacingOccurrences(of: ":cloud", with: "")
            .replacingOccurrences(of: ":latest", with: "")
        return LLMModel(
            id: name,
            apiModelID: name,
            shortName: short,
            // Local vs cloud is conveyed by the picker subsection header, so the
            // row is just the bare model name.
            displayName: short,
            backend: .ollama(requiresAccount: isCloud),
            // Vision support comes from the server's reported capabilities
            // (`/api/show`); only vision models surface in Ask Nugumi.
            supportsImages: OllamaModelCache.visionCapable.contains(name)
        )
    }

    /// Models served by the Codex (ChatGPT subscription) backend. The slugs
    /// come from CodexModelCache (live discovery → UserDefaults → fallback),
    /// so this list reflects whatever the user's account currently sees.
    static var codexModels: [LLMModel] {
        CodexModelCache.slugs.map { makeCodexModel(slug: $0) }
    }

    private static func makeCodexModel(slug: String) -> LLMModel {
        let pretty = slug
            .replacingOccurrences(of: "gpt-", with: "GPT-")
            .replacingOccurrences(of: "-mini", with: " mini")
            .replacingOccurrences(of: "-codex", with: " codex")
            .replacingOccurrences(of: "-spark", with: " spark")
            .replacingOccurrences(of: "-max", with: " max")
        return LLMModel(
            id: "codex/\(slug)",
            apiModelID: slug,
            shortName: pretty,
            // Grouped under the "ChatGPT" header, so no provider suffix here.
            displayName: pretty,
            backend: .cloud(.openAICodex),
            // Vision support varies by model — backend rejects images for
            // text-only slugs. Optimistic default avoids hiding usable models.
            supportsImages: true
        )
    }

    static let defaultModel = all[0]

    static func option(id: String) -> LLMModel {
        if id.hasPrefix("codex/") {
            let slug = String(id.dropFirst("codex/".count))
            return codexModels.first { $0.id == id } ?? makeCodexModel(slug: slug)
        }
        if let curated = all.first(where: { $0.id == id }) { return curated }
        // Discovered cloud models live outside `all`; resolve them so backend
        // dispatch and the menu label can find them (mirrors Ollama below).
        // Resolution depends on the persisted CloudModelCache: if the cache
        // was lost (e.g. defaults never flushed), a stored discovered id
        // silently falls back to defaultModel below — unlike curated ids,
        // which always resolve. Accepted best-effort trade-off.
        for provider in [CloudProvider.openAI, .anthropic, .gemini] {
            if let cloud = cloudModels(for: provider).first(where: { $0.id == id }) {
                return cloud
            }
        }
        if let ollama = ollamaModels.first(where: { $0.id == id }) { return ollama }
        // A stored ":latest" id must keep resolving after dedup collapses it
        // into the bare-tag curated entry (and vice versa).
        let canonical = canonicalOllamaID(id)
        if let ollama = ollamaModels.first(where: { canonicalOllamaID($0.id) == canonical }) { return ollama }
        return defaultModel
    }
}

enum ModelUseScope: String, CaseIterable {
    case textActions
    case askNugumi

    var defaultsKey: String {
        switch self {
        case .textActions:
            return "textModelID"
        case .askNugumi:
            return "askNugumiModelID"
        }
    }

    func defaultModelID(legacySelectedModelID: String?) -> String {
        switch self {
        case .textActions:
            if let legacySelectedModelID,
               LLMModel.all.contains(where: { $0.id == legacySelectedModelID }) {
                return legacySelectedModelID
            }
            return LLMModel.defaultModel.id
        case .askNugumi:
            if let flagship = LLMModel.all.first(where: { $0.id == "gpt-5.5" && $0.supportsImages }) {
                return flagship.id
            }
            return LLMModel.all.first(where: \.supportsImages)?.id ?? LLMModel.defaultModel.id
        }
    }

    func menuTitle(for model: LLMModel) -> String {
        switch self {
        case .textActions:
            return "Everyday text: \(model.shortName)"
        case .askNugumi:
            return "Ask Nugumi: \(model.shortName)"
        }
    }

    func availableModels(from models: [LLMModel] = LLMModel.all) -> [LLMModel] {
        switch self {
        case .textActions:
            return models
        case .askNugumi:
            return models.filter(\.supportsImages)
        }
    }
}

/// Per-engine model presets applied when an engine connects (key validated,
/// ChatGPT signed in, Ollama model installed) — see `applyEnginePreset`.
/// Everyday text gets the fast/cheap tier, Ask Nugumi the vision flagship.
enum EngineModelPreset {
    case ollama
    case cloud(CloudProvider)

    /// Preset model id per scope; nil when the engine has no candidate for
    /// that scope.
    func modelID(for scope: ModelUseScope) -> String? {
        switch self {
        case .ollama:
            return scope == .textActions ? "gpt-oss:20b" : "gemma4"
        case .cloud(.openAI):
            return scope == .textActions ? "gpt-5.4-mini" : "gpt-5.5"
        case .cloud(.anthropic):
            return scope == .textActions ? "claude-sonnet-4-6" : "claude-opus-4-7"
        case .cloud(.gemini):
            return scope == .textActions ? "gemini-2.5-flash" : "gemini-2.5-pro"
        case .cloud(.openAICodex):
            // Codex slugs are discovered per account — resolve against the
            // live catalog instead of hardcoding ids.
            let slugs = CodexModelCache.slugs
            let slug: String?
            switch scope {
            case .textActions:
                slug = slugs.first { $0.hasSuffix("-mini") && !$0.contains("codex") } ?? slugs.first
            case .askNugumi:
                slug = slugs.first { !$0.contains("mini") && !$0.contains("codex") } ?? slugs.first
            }
            return slug.map { "codex/\($0)" }
        }
    }
}

typealias OllamaModelOption = LLMModel

enum ThinkingLevel: String, CaseIterable {
    case low
    case medium
    case high

    var menuTitle: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var settingsTitle: String {
        "Thinking: \(rawValue)"
    }
}

extension ModelUseScope {
    var thinkingDefaultsKey: String {
        switch self {
        case .textActions:
            return "textThinkingLevel"
        case .askNugumi:
            return "askNugumiThinkingLevel"
        }
    }

    func defaultThinkingLevel(legacyThinkingRawValue: String?) -> ThinkingLevel {
        switch self {
        case .textActions:
            return legacyThinkingRawValue
                .flatMap(ThinkingLevel.init(rawValue:))
                ?? .low
        case .askNugumi:
            return .high
        }
    }

    func thinkingMenuTitle(for level: ThinkingLevel) -> String {
        switch self {
        case .textActions:
            return "Everyday text: \(level.menuTitle)"
        case .askNugumi:
            return "Ask Nugumi: \(level.menuTitle)"
        }
    }
}

enum FloatingButtonDefaultMode: String {
    case translate
    case smartReply

    static func storedMode(rawValue: String?) -> FloatingButtonDefaultMode {
        guard let rawValue else { return .translate }
        if rawValue == "selection" {
            return .translate
        }
        return FloatingButtonDefaultMode(rawValue: rawValue) ?? .translate
    }

    var translationMode: TranslationMode {
        switch self {
        case .translate: return .selection
        case .smartReply: return .smartReply
        }
    }

    var menuTitle: String {
        switch self {
        case .translate: return "Main mode: translate"
        case .smartReply: return "Main mode: reply"
        }
    }
}

enum SelectionDisplayMode: String, CaseIterable {
    case floatingBar
    case pet
    case off

    var menuTitle: String {
        switch self {
        case .floatingBar: return "Floating bar"
        case .pet: return "Pet mode"
        case .off: return "Off"
        }
    }

    var settingsTitle: String {
        switch self {
        case .floatingBar: return "Display: floating bar"
        case .pet: return "Display: pet mode"
        case .off: return "Display: off"
        }
    }
}

enum ReplacementMode: String, CaseIterable {
    case instantInsert
    case showPanel

    var menuTitle: String {
        switch self {
        case .instantInsert: return "Insert without preview"
        case .showPanel: return "Show preview panel"
        }
    }

    var settingsTitle: String {
        switch self {
        case .instantInsert: return "Replace action: insert without preview"
        case .showPanel: return "Replace action: show preview panel"
        }
    }
}

private struct GlobalHotKeyDefinition {
    static let signature = OSType(0x54524E53) // TRNS

    let id: UInt32
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let modifierFlags: NSEvent.ModifierFlags
    let displayString: String

    init(action: GlobalShortcutAction, shortcut: GlobalShortcut) {
        id = action.id
        keyCode = shortcut.keyCode
        carbonModifiers = shortcut.carbonModifiers
        modifierFlags = shortcut.modifiers
        displayString = shortcut.displayString
    }
}

private final class GlobalHotKey {
    private let definition: GlobalHotKeyDefinition

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var fallbackMonitor: Any?
    private let onPressed: @MainActor () -> Void

    init(definition: GlobalHotKeyDefinition, onPressed: @escaping @MainActor () -> Void) {
        self.definition = definition
        self.onPressed = onPressed
    }

    func register() {
        unregister()

        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let eventRef, let userData else {
                    return OSStatus(eventNotHandledErr)
                }

                var hotKeyID = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                let registrar = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                guard parameterStatus == noErr,
                      hotKeyID.signature == GlobalHotKeyDefinition.signature,
                      hotKeyID.id == registrar.definition.id
                else {
                    return OSStatus(eventNotHandledErr)
                }

                Task { @MainActor in
                    registrar.onPressed()
                }
                return noErr
            },
            1,
            &eventSpec,
            selfPointer,
            &eventHandlerRef
        )

        guard handlerStatus == noErr else {
            installFallbackMonitor()
            return
        }

        let hotKeyID = EventHotKeyID(
            signature: GlobalHotKeyDefinition.signature,
            id: definition.id
        )
        let hotKeyStatus = RegisterEventHotKey(
            definition.keyCode,
            definition.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard hotKeyStatus == noErr else {
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
                self.eventHandlerRef = nil
            }
            installFallbackMonitor()
            return
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }

        if let fallbackMonitor {
            NSEvent.removeMonitor(fallbackMonitor)
            self.fallbackMonitor = nil
        }
    }

    private func installFallbackMonitor() {
        fallbackMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard self.matches(event) else {
                return
            }

            Task { @MainActor in
                self.onPressed()
            }
        }
    }

    private func matches(_ event: NSEvent) -> Bool {
        guard event.keyCode == UInt16(definition.keyCode) else {
            return false
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers.intersection(GlobalShortcut.supportedModifiers) == definition.modifierFlags
    }
}

struct TranslationLanguage: Equatable {
    let id: String
    let displayName: String
    let promptName: String

    static let all: [TranslationLanguage] = [
        .init(id: "ru", displayName: "Russian", promptName: "Russian"),
        .init(id: "en", displayName: "English (US)", promptName: "English"),
        .init(id: "ko", displayName: "Korean", promptName: "Korean"),
        .init(id: "ja", displayName: "Japanese", promptName: "Japanese"),
        .init(id: "zh-Hans", displayName: "Chinese Simplified", promptName: "Simplified Chinese"),
        .init(id: "es", displayName: "Spanish", promptName: "Spanish"),
        .init(id: "fr", displayName: "French", promptName: "French"),
        .init(id: "de", displayName: "German", promptName: "German")
    ]

    static let defaultLanguage = all.first { $0.id == "en" } ?? all[0]
    static let defaultDraftLanguage = all.first { $0.id == "ko" } ?? defaultLanguage

    static func language(id: String) -> TranslationLanguage {
        all.first { $0.id == id } ?? defaultLanguage
    }
}

private enum TextNormalizer {
    static func cleanedSelection(_ text: String) -> String {
        var cleaned = normalizedBaseText(text)

        cleaned = cleaned.replacingOccurrences(
            of: #"(?<=\p{L})-\n(?=\p{L})"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?<=[.!?。！？])\s*(?=[▶•●▪▸])"#,
            with: "\n",
            options: .regularExpression
        )
        return cleanedStructuredSource(cleaned)
    }

    static func cleanedTranslation(_ text: String) -> String {
        var cleaned = normalizedBaseText(text)

        cleaned = cleaned.replacingOccurrences(
            of: #"[ \t]+\n"#,
            with: "\n",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\n[ \t]+"#,
            with: "\n",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\s+([,.;:!?…])"#,
            with: "$1",
            options: .regularExpression
        )
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func looksMeaningful(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var letterCount = 0
        var hasIdeographOrKana = false
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                letterCount += 1
            }
            switch scalar.value {
            case 0x3040...0x30FF,     // Hiragana + Katakana
                 0x3400...0x4DBF,     // CJK Unified Ideographs Extension A
                 0x4E00...0x9FFF,     // CJK Unified Ideographs
                 0xAC00...0xD7AF,     // Hangul Syllables
                 0xF900...0xFAFF:     // CJK Compatibility Ideographs
                hasIdeographOrKana = true
            default:
                break
            }
        }

        if hasIdeographOrKana { return true }
        return letterCount >= 2
    }

    static func cleanedDraftMessage(_ text: String) -> String {
        var cleaned = normalizedBaseText(text)

        cleaned = cleaned.replacingOccurrences(
            of: #"[ \t]+\n"#,
            with: "\n",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\n[ \t]+"#,
            with: "\n",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\n{4,}"#,
            with: "\n\n\n",
            options: .regularExpression
        )
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedBaseText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
    }

    private static func cleanedStructuredSource(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var resultLines: [String] = []
        var currentLine = ""

        func flushCurrentLine() {
            guard !currentLine.isEmpty else { return }
            resultLines.append(currentLine)
            currentLine = ""
        }

        for rawLine in lines {
            let line = cleanedInlineText(rawLine)
            if line.isEmpty {
                flushCurrentLine()
                if resultLines.last != "" {
                    resultLines.append("")
                }
                continue
            }

            if isStructuralLine(line) {
                flushCurrentLine()
                currentLine = line
                continue
            }

            if currentLine.isEmpty {
                currentLine = line
            } else {
                currentLine += joiningTextBetween(currentLine, and: line) + line
            }
        }

        flushCurrentLine()

        while resultLines.last == "" {
            resultLines.removeLast()
        }

        return resultLines
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanedInlineText(_ text: String) -> String {
        var cleaned = text
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        cleaned = cleaned.replacingOccurrences(
            of: #"\s+([,.;:!?…])"#,
            with: "$1",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"([(])\s+"#,
            with: "$1",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\s+([)])"#,
            with: "$1",
            options: .regularExpression
        )
        return cleaned
    }

    private static func isStructuralLine(_ text: String) -> Bool {
        text.range(
            of: #"^\s*(?:[▶•●▪▸◆◇○◦\-–—*]|\d+[.)]|[A-Za-z][.)])\s*"#,
            options: .regularExpression
        ) != nil
    }

    private static func joiningTextBetween(_ left: String, and right: String) -> String {
        guard let last = left.unicodeScalars.last, let first = right.unicodeScalars.first else {
            return " "
        }

        let noSpaceBefore = CharacterSet(charactersIn: ",.;:!?…)]}）】」』")
        let noSpaceAfter = CharacterSet(charactersIn: "([{（【「『")
        if noSpaceBefore.contains(first) || noSpaceAfter.contains(last) {
            return ""
        }

        return " "
    }
}

struct CompositionSettings: Equatable {
    let style: WritingStyle
    let cleanup: CleanupLevel
    let snippets: [Snippet]
    /// When true, the compose prompt gets a language-specific Gen Z styling
    /// overlay (see `GenZStyle`). Global toggle, orthogonal to `style`.
    let genZ: Bool
    /// The user's saved email voice sample — a representative email whose
    /// greeting, rhythm, and sign-off the model mirrors. Only populated for the
    /// `email` category; `nil`/empty elsewhere, so the prompt section vanishes.
    let voiceSample: String?
}

private final class TranslationCache {
    private let maxEntries: Int
    private var entries: [String: String] = [:]
    private var keysByRecentUse: [String] = []

    init(maxEntries: Int = 200) {
        self.maxEntries = maxEntries
    }

    func translation(for text: String, targetLanguage: TranslationLanguage, thinkingLevel: ThinkingLevel) -> String? {
        let key = cacheKey(for: text, targetLanguage: targetLanguage, thinkingLevel: thinkingLevel)
        guard let translation = entries[key] else {
            return nil
        }

        markRecentlyUsed(key)
        return translation
    }

    func store(_ translation: String, for text: String, targetLanguage: TranslationLanguage, thinkingLevel: ThinkingLevel) {
        let key = cacheKey(for: text, targetLanguage: targetLanguage, thinkingLevel: thinkingLevel)
        guard !key.isEmpty, !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        entries[key] = translation
        markRecentlyUsed(key)
        trimIfNeeded()
    }

    private func cacheKey(for text: String, targetLanguage: TranslationLanguage, thinkingLevel: ThinkingLevel) -> String {
        "\(targetLanguage.id):\(thinkingLevel.rawValue):\(TextNormalizer.cleanedSelection(text))"
    }

    private func markRecentlyUsed(_ key: String) {
        keysByRecentUse.removeAll { $0 == key }
        keysByRecentUse.append(key)
    }

    private func trimIfNeeded() {
        while keysByRecentUse.count > maxEntries, let oldestKey = keysByRecentUse.first {
            keysByRecentUse.removeFirst()
            entries.removeValue(forKey: oldestKey)
        }
    }
}

@main
@MainActor
final class NugumiApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var mouseMonitor: Any?
    private var keyboardMonitor: Any?
    private var lastLeftMouseDownLocation: NSPoint?
    /// Per-bundle count of consecutive selection-gesture attempts that returned
    /// no readable text. Apps like KakaoTalk expose neither AX text attributes
    /// nor a working Cmd+C path, so the floating bar silently never appears —
    /// this counter lets us surface a one-time hint pointing users at
    /// Screenshot Translation instead.
    private var unreadableSelectionFailureCounts: [String: Int] = [:]
    private static let unreadableSelectionFailureThreshold = 3
    private static let unreadableSelectionHintShownDefaultsKey = "unreadableSelectionHintShownBundles"
    private let selectionReader = SelectionReader()
    private let ollamaBaseURL = URL(string: "http://127.0.0.1:11434")!
    private var currentBackend: any LLMBackend {
        backend(for: textModelID)
    }
    private var askBackend: any LLMBackend {
        backend(for: askNugumiModelID)
    }

    private func backend(for modelID: String) -> any LLMBackend {
        let model = LLMModel.option(id: modelID)
        switch model.backend {
        case .ollama:
            return OllamaClient(baseURL: ollamaBaseURL, model: model.apiModelID)
        case .cloud(let provider):
            switch provider {
            case .openAICodex:
                return OpenAICodexClient(apiModelID: model.apiModelID)
            case .openAI, .anthropic, .gemini:
                let key = KeychainStore.apiKey(for: provider) ?? ""
                return OpenAIChatClient(provider: provider, apiKey: key, model: model.apiModelID)
            }
        }
    }

    private var translateButtonController: FloatingTranslateButtonController?
    private var floatingLoadingBar: FloatingTranslateButtonController?
    private var floatingTargetButton: FloatingTranslateButtonController?
    /// Round loading bubble shown in place of the Ask Nugumi pill while a
    /// question is in flight. Unlike the pill, it has no outside-click
    /// monitors, so clicking elsewhere can't dismiss the in-flight request.
    private var askFloatingLoadingBar: FloatingTranslateButtonController?
    private var petController: PetController?
    private var translationPanelController: TranslationPanelController?
    private var askPromptController: AskPromptController?
    private var askNugumiTask: Task<Void, Never>?
    private var askNugumiRequestID: UUID?
    private var askHistory: [AskNugumiTurn] = []
    /// Screen capture taken the moment Ask Nugumi is summoned, before the
    /// prompt steals focus. Activating Nugumi deactivates the frontmost app,
    /// which instantly closes its open menus/popovers, so a submit-time
    /// capture can never see them. Consumed by `submitAskNugumiPrompt`.
    private var pendingAskNugumiCapture: AskNugumiScreenCapture?
    private var isScreenshotTranslationRunning = false
    private var isAskNugumiRunning = false
    private var screenshotDragStartLocation: NSPoint?
    private var screenshotDragEndLocation: NSPoint?
    private var screenshotPanelSide: TranslationPanelController.Side?
    private var screenshotDragTracker: ScreenshotDragTracker?
    private var globalHotKeys: [GlobalHotKey] = []
    private var modifierDetectors: [DoubleModifierPressDetector] = []
    private var shortcutRecorderWindowController: ShortcutRecorderWindowController?
    private var lastReplacementSourcePID: pid_t?
    private var translationCache = TranslationCache()
    private let usageStatsStore = UsageStatsStore()
    private let analyticsClient = AnalyticsClient()
    private let snippetsStore = SnippetsStore()
    private let translationHistoryStore = TranslationHistoryStore()
    private lazy var bootstrap: OllamaBootstrap = OllamaBootstrap(
        baseURL: ollamaBaseURL,
        models: LLMModel.ollamaModels
    )
    private var snippetsWindowController: SnippetsWindowController?
    private var mainWindowController: MainWindowController?
    /// Ollama model whose pull the user kicked off from the AI Engine setup card.
    /// When it finishes we promote it to the everyday-text default once, mirroring
    /// the retired onboarding window's `onOllamaReady` behavior.
    private var pendingOllamaAutoSelectID: String?
    private var accessibilityTrustTimer: Timer?
    private var screenRecordingTrustTimer: Timer?

    private struct WindowSharingSnapshot {
        let window: NSWindow
        let sharingType: NSWindow.SharingType
    }
    private var onboardingWindowController: OnboardingWindowController?
    private var lastObservedModelReadyState: [String: BootstrapStepStatus] = [:]
    private lazy var updaterController: SPUStandardUpdaterController? = {
        guard isRunningFromAppBundle else { return nil }
        return SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }()
    private var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }
    private var targetLanguage: TranslationLanguage {
        get {
            TranslationLanguage.language(
                id: UserDefaults.standard.string(forKey: "targetLanguageID") ?? TranslationLanguage.defaultLanguage.id
            )
        }
        set {
            UserDefaults.standard.set(newValue.id, forKey: "targetLanguageID")
        }
    }
    private var draftTargetLanguage: TranslationLanguage {
        get {
            TranslationLanguage.language(
                id: UserDefaults.standard.string(forKey: "draftTargetLanguageID") ?? TranslationLanguage.defaultDraftLanguage.id
            )
        }
        set {
            UserDefaults.standard.set(newValue.id, forKey: "draftTargetLanguageID")
        }
    }
    /// The single "other" language the "Toggle writing language" shortcut flips
    /// to. The toggle swaps this with `draftTargetLanguage`, so the configured
    /// pair is always {writing language, alternate} — the writing language side
    /// is the live target, only this one is user-selectable.
    private var writingToggleAlternate: TranslationLanguage {
        get {
            if let id = UserDefaults.standard.string(forKey: "writingToggleAlternateID") {
                return TranslationLanguage.language(id: id)
            }
            // Migrate from the legacy A/B pair: carry over whichever language
            // isn't the active writing language so existing setups are preserved.
            let current = draftTargetLanguage
            let legacyA = UserDefaults.standard.string(forKey: "writingToggleLanguageAID")
                .map { TranslationLanguage.language(id: $0) }
            let legacyB = UserDefaults.standard.string(forKey: "writingToggleLanguageBID")
                .map { TranslationLanguage.language(id: $0) }
            if let a = legacyA, a.id != current.id { return a }
            if let b = legacyB, b.id != current.id { return b }
            return TranslationLanguage.defaultLanguage.id == current.id
                ? TranslationLanguage.defaultDraftLanguage
                : TranslationLanguage.defaultLanguage
        }
        set {
            UserDefaults.standard.set(newValue.id, forKey: "writingToggleAlternateID")
        }
    }
    private var floatingDefaultMode: FloatingButtonDefaultMode {
        get {
            FloatingButtonDefaultMode.storedMode(
                rawValue: UserDefaults.standard.string(forKey: "floatingButtonDefaultMode")
            )
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "floatingButtonDefaultMode")
        }
    }
    private var selectionDisplayMode: SelectionDisplayMode {
        get {
            let raw = UserDefaults.standard.string(forKey: "selectionDisplayMode") ?? SelectionDisplayMode.pet.rawValue
            return SelectionDisplayMode(rawValue: raw) ?? .pet
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "selectionDisplayMode")
        }
    }
    private var legacySelectedModelID: String? {
        UserDefaults.standard.string(forKey: "selectedOllamaModel")
    }
    private var textModelID: String {
        get {
            UserDefaults.standard.string(forKey: ModelUseScope.textActions.defaultsKey)
                ?? ModelUseScope.textActions.defaultModelID(legacySelectedModelID: legacySelectedModelID)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: ModelUseScope.textActions.defaultsKey)
        }
    }
    private var askNugumiModelID: String {
        get {
            UserDefaults.standard.string(forKey: ModelUseScope.askNugumi.defaultsKey)
                ?? ModelUseScope.askNugumi.defaultModelID(legacySelectedModelID: legacySelectedModelID)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: ModelUseScope.askNugumi.defaultsKey)
        }
    }
    private func modelID(for scope: ModelUseScope) -> String {
        switch scope {
        case .textActions:
            return textModelID
        case .askNugumi:
            return askNugumiModelID
        }
    }
    private func setModelID(_ modelID: String, for scope: ModelUseScope) {
        switch scope {
        case .textActions:
            textModelID = modelID
        case .askNugumi:
            askNugumiModelID = modelID
        }
    }
    private var legacyThinkingRawValue: String? {
        UserDefaults.standard.string(forKey: "thinkingLevel")
    }
    private var textThinkingLevel: ThinkingLevel {
        get {
            UserDefaults.standard.string(forKey: ModelUseScope.textActions.thinkingDefaultsKey)
                .flatMap(ThinkingLevel.init(rawValue:))
                ?? ModelUseScope.textActions.defaultThinkingLevel(legacyThinkingRawValue: legacyThinkingRawValue)
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: ModelUseScope.textActions.thinkingDefaultsKey)
        }
    }
    private var askNugumiThinkingLevel: ThinkingLevel {
        get {
            UserDefaults.standard.string(forKey: ModelUseScope.askNugumi.thinkingDefaultsKey)
                .flatMap(ThinkingLevel.init(rawValue:))
                ?? ModelUseScope.askNugumi.defaultThinkingLevel(legacyThinkingRawValue: legacyThinkingRawValue)
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: ModelUseScope.askNugumi.thinkingDefaultsKey)
        }
    }
    private func thinkingLevel(for scope: ModelUseScope) -> ThinkingLevel {
        switch scope {
        case .textActions:
            return textThinkingLevel
        case .askNugumi:
            return askNugumiThinkingLevel
        }
    }
    private func setThinkingLevel(_ level: ThinkingLevel, for scope: ModelUseScope) {
        switch scope {
        case .textActions:
            textThinkingLevel = level
        case .askNugumi:
            askNugumiThinkingLevel = level
        }
    }
    private var cleanupLevel: CleanupLevel {
        get {
            let raw = UserDefaults.standard.string(forKey: "cleanupLevel") ?? CleanupLevel.light.rawValue
            return CleanupLevel(rawValue: raw) ?? .light
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "cleanupLevel")
        }
    }

    /// Global Gen Z styling toggle. Off by default; injected into compose
    /// prompts via `CompositionSettings.genZ`.
    private var genZModeEnabled: Bool {
        get { GenZStyle.isEnabled }
        set { UserDefaults.standard.set(newValue, forKey: GenZStyle.defaultsKey) }
    }

    /// The user's email voice sample — a typical email they write, used as a
    /// style reference for the `email` category only. Empty by default. Treated
    /// as personal content (like Snippets), so it survives a settings reset.
    private var emailVoiceSample: String {
        get { UserDefaults.standard.string(forKey: "voiceSample.email") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "voiceSample.email") }
    }

    private var replacementMode: ReplacementMode {
        get {
            let raw = UserDefaults.standard.string(forKey: "replacementMode") ?? ReplacementMode.instantInsert.rawValue
            return ReplacementMode(rawValue: raw) ?? .instantInsert
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "replacementMode")
        }
    }

    private var invisibilityModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: InvisibilityState.defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: InvisibilityState.defaultsKey) }
    }

    private func writingStyle(for category: AppCategory) -> WritingStyle {
        let key = "writingStyle.\(category.rawValue)"
        if let raw = UserDefaults.standard.string(forKey: key),
           let style = WritingStyle(rawValue: raw) {
            return style
        }
        return Self.defaultStyle(for: category)
    }

    private func setWritingStyle(_ style: WritingStyle, for category: AppCategory) {
        UserDefaults.standard.set(style.rawValue, forKey: "writingStyle.\(category.rawValue)")
    }

    private static func defaultStyle(for category: AppCategory) -> WritingStyle {
        category.defaultWritingStyle
    }

    // MARK: - Custom app → category assignments

    private static let customAppAssignmentsKey = "customAppAssignmentsV1"
    private static let suppressedBuiltInAppsKey = "suppressedBuiltInAppsV1"

    func customAppAssignments() -> [CustomAppAssignment] {
        guard let data = UserDefaults.standard.data(forKey: Self.customAppAssignmentsKey),
              let list = try? JSONDecoder().decode([CustomAppAssignment].self, from: data)
        else { return [] }
        return list
    }

    private func saveCustomAppAssignments(_ list: [CustomAppAssignment]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Self.customAppAssignmentsKey)
        }
        syncAppClassifierOverrides()
    }

    func suppressedBuiltInApps() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.suppressedBuiltInAppsKey) ?? [])
    }

    private func saveSuppressedBuiltInApps(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: Self.suppressedBuiltInAppsKey)
        syncAppClassifierOverrides()
    }

    /// Push persisted assignments into the classifier's static lookup so the live
    /// rewrite path (`AppCategoryClassifier.category(for:)`) honors them.
    func syncAppClassifierOverrides() {
        var overrides: [String: AppCategory] = [:]
        for assignment in customAppAssignments() {
            overrides[assignment.bundleID] = assignment.category
        }
        AppCategoryClassifier.userOverrides = overrides
        AppCategoryClassifier.suppressedBuiltIns = suppressedBuiltInApps()
    }

    func addCustomApp(bundleID: String, name: String, category: AppCategory) {
        var list = customAppAssignments().filter { $0.bundleID != bundleID }
        list.append(CustomAppAssignment(bundleID: bundleID, name: name, category: category))
        saveCustomAppAssignments(list)
        // If the user re-adds a previously-removed built-in, un-suppress it.
        if AppCategoryClassifier.bundleIDMap[bundleID] != nil {
            var suppressed = suppressedBuiltInApps()
            suppressed.remove(bundleID)
            saveSuppressedBuiltInApps(suppressed)
        }
    }

    /// Removes an app from its category. Built-in mapped apps are suppressed (so they
    /// stop auto-classifying); user-added apps are deleted outright.
    func removeApp(bundleID: String) {
        if customAppAssignments().contains(where: { $0.bundleID == bundleID }) {
            saveCustomAppAssignments(customAppAssignments().filter { $0.bundleID != bundleID })
        }
        if AppCategoryClassifier.bundleIDMap[bundleID] != nil {
            var suppressed = suppressedBuiltInApps()
            suppressed.insert(bundleID)
            saveSuppressedBuiltInApps(suppressed)
        }
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = NugumiApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Developer switch: NUGUMI_FIRST_RUN=1 clears the first-run flags so
        // the full install experience (intro video → permissions → feature
        // tour → engine choice → main window) replays on this launch. TCC
        // permissions can't be revoked from here — use `tccutil reset` for
        // full fidelity.
        if ProcessInfo.processInfo.environment["NUGUMI_FIRST_RUN"] == "1" {
            for key in [
                OnboardingModel.featureTourCompletedKey,
                OnboardingModel.introPlayedKey,
                "mainWindowAutoShownV1",
                "permissionsOnboarding.screenCaptureRequested",
            ] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        // AX default messaging timeout is 6s. Parameterized calls (e.g.
        // kAXBoundsForRangeParameterizedAttribute) can stall the main thread
        // when an unsupported app responds slowly. Cap it.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.5)
        setupStatusItem()
        installMainMenu()
        statusItem?.isVisible = !invisibilityModeEnabled
        InvisibilityState.applyToAllOpenWindows()
        requestAccessibilityPermissionIfNeeded()
        requestScreenRecordingPermissionIfNeeded()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            self?.presentPermissionsWindowIfNeeded()
        }
        startMouseMonitor()
        startKeyboardMonitor()
        applySelectionDisplayMode()
        setupGlobalHotKeys()
        syncAppClassifierOverrides()
        setupBootstrap()
        // Refresh the API-key providers' model catalogs (best-effort, cached).
        Task.detached { await CloudModelDiscovery.refreshAll() }
        _ = updaterController
        analyticsClient.trackInstallIfNeeded()
        analyticsClient.track(.appLaunched, properties: permissionStatusProperties(
            accessibilityTrusted: AXIsProcessTrusted(),
            screenRecordingTrusted: CGPreflightScreenCaptureAccess()
        ))
        reconcilePermissionAnalyticsAtLaunch()
        showMainWindowOnFirstRunIfNeeded()
    }

    /// Opens the main window once after install so users discover it. While the
    /// onboarding window is up this defers WITHOUT consuming the flag — the
    /// onboarding close handler calls it again, so the main window appears only
    /// after the tour, never side by side with it.
    @MainActor
    private func showMainWindowOnFirstRunIfNeeded() {
        let key = "mainWindowAutoShownV1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self,
                  self.onboardingWindowController == nil
            else { return }
            UserDefaults.standard.set(true, forKey: key)
            // Fresh installs have no model ready yet — land on setup directly.
            let section: MainWindowSection? = self.bootstrap.isReady(for: self.textModelID) ? nil : .aiEngine
            self.presentMainWindow(section: section)
        }
    }

    private func shortcut(for action: GlobalShortcutAction) -> GlobalShortcut {
        GlobalShortcutStore.shortcut(for: action)
    }

    private func setupGlobalHotKeys() {
        globalHotKeys.forEach { $0.unregister() }
        globalHotKeys.removeAll()
        modifierDetectors.forEach { $0.stop() }
        modifierDetectors.removeAll()

        let bindings: [(GlobalShortcutAction, @MainActor () -> Void)] = [
            (.screenshotArea, { [weak self] in self?.startScreenshotTranslation() }),
            (.translateSelection, { [weak self] in self?.startSelectedTextTranslationForReplacement() }),
            (.translateOrReply, { [weak self] in self?.startSelectionTranslateOrReply() }),
            (.toggleInvisibility, { [weak self] in self?.toggleInvisibilityMode() }),
            (.askNugumi, { [weak self] in self?.startAskNugumiPrompt() }),
            (.toggleWritingLanguage, { [weak self] in self?.toggleWritingLanguageAction() })
        ]

        for (action, handler) in bindings {
            let shortcut = shortcut(for: action)
            switch shortcut.kind {
            case .combo:
                let hotKey = GlobalHotKey(
                    definition: GlobalHotKeyDefinition(action: action, shortcut: shortcut),
                    onPressed: handler
                )
                globalHotKeys.append(hotKey)
                hotKey.register()
            case .doubleTap:
                let detector = DoubleModifierPressDetector(
                    modifier: shortcut.modifiers,
                    onDetected: handler
                )
                modifierDetectors.append(detector)
                detector.start()
            }
        }
    }

    @MainActor
    private func startAskNugumiPrompt() {
        // Toggle: if any Ask Nugumi UI (prompt, loading, answer, or an
        // in-flight request) is already up, the shortcut dismisses it instead
        // of opening another one.
        let askUIOpen = isAskNugumiRunning
            || askPromptController != nil
            || petController?.isPromptVisible == true
        if askUIOpen {
            dismissAskNugumi()
            return
        }

        translateButtonController?.close()
        translateButtonController = nil
        floatingTargetButton?.close()
        floatingTargetButton = nil
        translationPanelController?.close()
        translationPanelController = nil

        if selectionDisplayMode == .pet {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingAskNugumiCapture = await self.captureScreenBeforeAskPromptTakesFocus()
                self.presentPetAskPrompt()
            }
            return
        }

        let controller = AskPromptController(
            near: NSEvent.mouseLocation,
            onSubmit: { [weak self] prompt in
                self?.submitAskNugumiPrompt(prompt)
            },
            onClose: { [weak self] in
                guard let self else { return }
                self.askPromptController = nil
                self.pendingAskNugumiCapture = nil
                if self.isAskNugumiRunning {
                    self.cancelAskNugumiRequest()
                }
            }
        )
        askPromptController = controller
        // Capture before `show()`: activating Nugumi closes any menu the
        // user is asking about. The prompt appears one capture (~100 ms)
        // later, with the dropdown already safely in the pending shot.
        Task { @MainActor [weak self] in
            guard let self, self.askPromptController === controller else { return }
            self.pendingAskNugumiCapture = await self.captureScreenBeforeAskPromptTakesFocus()
            guard self.askPromptController === controller else { return }
            controller.show()
        }
    }

    /// Best-effort screen capture for `pendingAskNugumiCapture`. Returns nil
    /// on failure (e.g. missing screen-recording permission) so the submit
    /// path falls back to its own capture with full error reporting.
    @MainActor
    private func captureScreenBeforeAskPromptTakesFocus() async -> AskNugumiScreenCapture? {
        let sharingSnapshot = Self.hideAppWindowsFromScreenCapture()
        defer { Self.restoreAppWindowSharing(sharingSnapshot) }
        return try? await ScreenshotCapture.captureActiveScreen(containing: NSEvent.mouseLocation)
    }

    @MainActor
    private func submitAskNugumiPrompt(_ prompt: String) {
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrompt.isEmpty else { return }

        let model = LLMModel.option(id: askNugumiModelID)
        guard model.supportsImages else {
            askPromptController?.showError("Ask Nugumi needs a vision model.")
            petController?.showPromptError("Needs a vision model.")
            return
        }

        if let setupError = askNugumiSetupErrorIfNeeded(for: model) {
            let message = Self.translationPanelErrorMessage(for: setupError)
            askPromptController?.showError(message)
            petController?.showPromptError(message)
            return
        }

        let requestID = UUID()
        askNugumiTask?.cancel()
        askNugumiRequestID = requestID
        isAskNugumiRunning = true
        askPromptController?.setLoading()
        if petController?.isPromptVisible == true {
            petController?.setPromptLoading()
        }

        // Hide the wide "Ask Nugumi" pill and surface the round loading bar
        // instead. The pill's outside-click monitors close the panel on any
        // background click, which currently kills in-flight requests; the
        // small loading bar has `ignoresMouseEvents = true` and no global
        // click monitors, so the user can click anywhere without losing
        // the answer. If the request fails, `AskPromptController.showError`
        // calls `panel.makeKeyAndOrderFront` and the pill reappears with
        // the error text.
        if selectionDisplayMode != .pet, let prompt = askPromptController {
            let pillCenter = prompt.panelCenter
            prompt.hidePanel()
            showAskFloatingLoadingBar(at: pillCenter)
        }

        let cursorLocation = NSEvent.mouseLocation
        let backend = askBackend
        // Prefer the capture taken when the prompt was summoned — it still
        // shows transient UI (open menus, popovers) that closed as soon as
        // the prompt took focus. Submit-time capture is the fallback.
        let preparedCapture = pendingAskNugumiCapture
        pendingAskNugumiCapture = nil
        askNugumiTask = Task { [weak self] in
            do {
                let capture: AskNugumiScreenCapture
                if let preparedCapture {
                    capture = preparedCapture
                } else {
                    let sharingSnapshot = await MainActor.run {
                        Self.hideAppWindowsFromScreenCapture()
                    }
                    do {
                        capture = try await ScreenshotCapture.captureActiveScreen(containing: cursorLocation)
                    } catch {
                        await MainActor.run {
                            Self.restoreAppWindowSharing(sharingSnapshot)
                        }
                        throw error
                    }
                    await MainActor.run {
                        Self.restoreAppWindowSharing(sharingSnapshot)
                    }
                }
                try Task.checkCancellation()

                let shouldContinue = await MainActor.run { () -> Bool in
                    guard let self, self.askNugumiRequestID == requestID else {
                        return false
                    }
                    self.petController?.showThinking()
                    return true
                }
                guard shouldContinue else { return }

                let history = await MainActor.run { self?.askHistory ?? [] }
                let currentThinkingLevel = await MainActor.run { self?.askNugumiThinkingLevel ?? .high }
                let response = try await backend.ask(
                    history: history,
                    question: cleanPrompt,
                    image: capture.image,
                    thinkingLevel: currentThinkingLevel
                ) { _ in }
                try Task.checkCancellation()

                await MainActor.run {
                    self?.presentAskNugumiResult(
                        response,
                        capture: capture,
                        prompt: cleanPrompt,
                        requestID: requestID
                    )
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.clearAskNugumiRequestIfCurrent(requestID)
                }
            } catch {
                await MainActor.run {
                    self?.presentAskNugumiFailure(error, requestID: requestID)
                }
            }
        }
    }

    @MainActor
    private func presentAskNugumiResult(
        _ response: AskNugumiResponse,
        capture: AskNugumiScreenCapture,
        prompt: String,
        requestID: UUID
    ) {
        guard askNugumiRequestID == requestID else { return }
        clearAskNugumiRequestIfCurrent(requestID)
        analyticsClient.track(.askScreenCompleted, properties: [
            "model_id": askNugumiModelID
        ])
        analyticsClient.trackFirstUsefulActionIfNeeded(
            sourceEvent: .askScreenCompleted,
            properties: ["model_id": askNugumiModelID]
        )
        recordAskTurn(question: prompt, answer: response.message)
        hideAskFloatingLoadingBar()
        askPromptController?.close()
        askPromptController = nil

        translationPanelController?.close()
        translationPanelController = nil

        if selectionDisplayMode == .pet {
            presentPetAskNugumiResult(response, capture: capture)
            return
        }

        petController?.clearPrompt()
        let controller = TranslationPanelController(
            anchor: .point(NSEvent.mouseLocation, panelSide: .right),
            sourceText: prompt,
            targetLanguage: targetLanguage,
            resultLabel: "Answer",
            onClose: { [weak self] in
                self?.translationPanelController = nil
                self?.floatingTargetButton?.close()
                self?.floatingTargetButton = nil
                self?.petController?.clearReady()
            }
        )
        translationPanelController = controller
        let panelRequestID = controller.showLoading(targetLanguage: targetLanguage)
        controller.showTranslation(response.message, requestID: panelRequestID)

        if let target = response.petTarget {
            presentFloatingAskTargetPointer(for: target, capture: capture)
        } else {
            floatingTargetButton?.close()
            floatingTargetButton = nil
        }
    }

    @MainActor
    private func presentFloatingAskTargetPointer(
        for target: AskNugumiPetTarget,
        capture: AskNugumiScreenCapture
    ) {
        let point = AskNugumiCoordinateMapper.exactScreenPoint(
            for: target,
            screenFrame: capture.screenFrame
        )
        let button: FloatingTranslateButtonController
        if let existing = floatingTargetButton {
            button = existing
        } else {
            // Launch the pointer from the pet so it visibly travels from the
            // character to the target; fall back to the cursor if no pet.
            let launchPoint = petController?.petAnchorPoint ?? NSEvent.mouseLocation
            button = FloatingTranslateButtonController(
                screenPoint: launchPoint,
                selectedText: "",
                initialMode: .selection,
                onTranslate: { _ in },
                onRewrite: { _ in },
                onSmartReply: { _ in }
            )
            floatingTargetButton = button
        }
        button.pointAt(point, visibleFrame: capture.visibleFrame)
    }

    /// Brings up the round loading bubble centered on the pill's old
    /// position so the user sees that the question is in flight after the
    /// pill is hidden. The button is wired to no-op handlers — it exists
    /// purely as a visual indicator.
    @MainActor
    private func showAskFloatingLoadingBar(at pillCenter: NSPoint) {
        // The bar's init places the button at
        // `screenPoint + (5 + buttonSize/2, -buttonSize/2 - 5)` from its
        // anchor; reverse the math so its center lands on the pill's center.
        let offsetX = 5 + AskNugumiFloatingTargetPresentationPolicy.buttonSize / 2
        let offsetY = AskNugumiFloatingTargetPresentationPolicy.buttonSize / 2 + 5
        let anchor = NSPoint(x: pillCenter.x - offsetX, y: pillCenter.y + offsetY)

        let bar = FloatingTranslateButtonController(
            screenPoint: anchor,
            selectedText: "",
            initialMode: .selection,
            onTranslate: { _ in },
            onRewrite: { _ in },
            onSmartReply: { _ in }
        )
        bar.show()
        bar.setLoading()
        askFloatingLoadingBar?.close()
        askFloatingLoadingBar = bar
    }

    @MainActor
    private func hideAskFloatingLoadingBar() {
        askFloatingLoadingBar?.close()
        askFloatingLoadingBar = nil
    }

    @MainActor
    private func presentPetAskNugumiResult(
        _ response: AskNugumiResponse,
        capture: AskNugumiScreenCapture
    ) {
        if petController == nil {
            petController = PetController(initialMode: .selection)
        }

        guard let petController else { return }

        if let target = response.petTarget {
            let presentation = AskNugumiPetAnswerTargetPresentationPolicy.presentation(
                for: target,
                screenFrame: capture.screenFrame
            )
            // The pet stays put; the pixel arrow travels to the target.
            petController.showAnswer(
                response.message,
                emotion: response.emotion,
                markerTarget: presentation.markerTarget
            )
        } else {
            petController.showAnswer(response.message, emotion: response.emotion)
        }
    }

    @MainActor
    private func presentAskNugumiFailure(_ error: Error, requestID: UUID) {
        guard askNugumiRequestID == requestID else { return }
        clearAskNugumiRequestIfCurrent(requestID)
        hideAskFloatingLoadingBar()

        if let screenshotError = error as? ScreenshotTranslationError,
           case .screenRecordingPermissionDenied = screenshotError {
            analyticsClient.track(.errorOccurred, properties: [
                "error_type": "screen_recording_permission_denied",
                "error_context": "ask_screen"
            ])
            askPromptController?.close()
            askPromptController = nil
            petController?.clearPrompt()
            presentScreenshotTranslationError(screenshotError)
            return
        }

        let routed = handleTranslationFailure(error)
        if routed {
            askPromptController?.close()
            askPromptController = nil
            petController?.clearPrompt()
            return
        }
        analyticsClient.track(.errorOccurred, properties: [
            "error_type": Self.analyticsErrorType(error),
            "error_context": "ask_screen"
        ])
        // `showError` on the hidden pill calls `makeKeyAndOrderFront`, so
        // the pill reappears at its original spot carrying the error text.
        askPromptController?.showError(error.localizedDescription)
        petController?.showPromptError(error.localizedDescription)
    }

    @MainActor
    private func cancelAskNugumiRequest() {
        askNugumiTask?.cancel()
        askNugumiTask = nil
        askNugumiRequestID = nil
        isAskNugumiRunning = false
        petController?.clearThinking()
        petController?.clearPrompt()
        floatingTargetButton?.close()
        floatingTargetButton = nil
        hideAskFloatingLoadingBar()
    }

    /// Opens the pet prompt input wired to Ask Nugumi. Reused for the initial
    /// shortcut-triggered prompt and for the answer bubble's "continue" button —
    /// `askHistory` persists across the session so follow-ups keep context.
    @MainActor
    private func presentPetAskPrompt() {
        if petController == nil {
            petController = PetController(initialMode: .draftMessage)
        }
        petController?.onContinue = { [weak self] in
            self?.continueAskNugumiDialog()
        }
        petController?.showPrompt(
            onSubmit: { [weak self] prompt in
                self?.submitAskNugumiPrompt(prompt)
            },
            onClose: { [weak self] in
                guard let self else { return }
                self.pendingAskNugumiCapture = nil
                if self.isAskNugumiRunning {
                    self.cancelAskNugumiRequest()
                }
            }
        )
    }

    /// "Continue dialog" affordance on the answer bubble: re-open the prompt
    /// for a follow-up question in the same conversation.
    @MainActor
    private func continueAskNugumiDialog() {
        guard !isAskNugumiRunning else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pendingAskNugumiCapture = await self.captureScreenBeforeAskPromptTakesFocus()
            self.presentPetAskPrompt()
        }
    }

    /// Tears down every Ask Nugumi surface (pet prompt/answer, standalone
    /// prompt window, in-flight request). Used by the Ask Nugumi shortcut toggle.
    @MainActor
    private func dismissAskNugumi() {
        if isAskNugumiRunning {
            cancelAskNugumiRequest()
        }
        pendingAskNugumiCapture = nil
        askPromptController?.close()
        askPromptController = nil
        petController?.clearPrompt()
        floatingTargetButton?.close()
        floatingTargetButton = nil
        hideAskFloatingLoadingBar()
    }

    @MainActor
    private func recordAskTurn(question: String, answer: String) {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty, !trimmedAnswer.isEmpty else { return }
        let turn = AskNugumiTurn(question: trimmedQuestion, answer: trimmedAnswer)
        askHistory = AskNugumiPromptBuilder.appending(turn, to: askHistory)
        translationHistoryStore.recordAsk(question: trimmedQuestion, answer: trimmedAnswer)
    }

    @MainActor
    private func recordTranslation(
        source: String,
        result: String,
        kind: UsageStatsEventKind,
        targetLanguage: TranslationLanguage
    ) {
        usageStatsStore.recordUse(sourceText: source, resultText: result, kind: kind, targetLanguage: targetLanguage)
        translationHistoryStore.record(sourceText: source, resultText: result, kind: kind, targetLanguage: targetLanguage)
    }

    private static func hideAppWindowsFromScreenCapture() -> [WindowSharingSnapshot] {
        let snapshots = NSApp.windows.map { window in
            WindowSharingSnapshot(window: window, sharingType: window.sharingType)
        }
        NSApp.windows.forEach { window in
            window.sharingType = .none
        }
        return snapshots
    }

    private static func restoreAppWindowSharing(_ snapshots: [WindowSharingSnapshot]) {
        snapshots.forEach { snapshot in
            snapshot.window.sharingType = snapshot.sharingType
        }
    }

    @MainActor
    private func clearAskNugumiRequestIfCurrent(_ requestID: UUID) {
        guard askNugumiRequestID == requestID else { return }
        askNugumiTask = nil
        askNugumiRequestID = nil
        isAskNugumiRunning = false
        petController?.clearThinking()
    }

    @MainActor
    private func askNugumiSetupErrorIfNeeded(for model: LLMModel) -> TranslationError? {
        switch model.backend {
        case .ollama:
            return translationErrorIfBootstrapNeedsSetup(for: model.id)
        case .cloud(let provider):
            // Use the unified hasCredentials helper — for .openAICodex it
            // checks OAuth tokens via KeychainStore.codexCredentials(),
            // for API-key providers it checks the saved key. The previous
            // `apiKey(for:)` check was always nil for Codex even when the
            // user was signed in, killing requests pre-flight.
            return provider.hasCredentials ? nil : .invalidAPIKey(provider)
        }
    }

    @objc private func toggleInvisibilityMode() {
        let now = !invisibilityModeEnabled
        invisibilityModeEnabled = now
        statusItem?.isVisible = !now
        InvisibilityState.applyToAllOpenWindows()
        updateMenuState()
        if now && !UserDefaults.standard.bool(forKey: InvisibilityState.firstRunShownKey) {
            showInvisibilityFirstRunDialog()
            UserDefaults.standard.set(true, forKey: InvisibilityState.firstRunShownKey)
        }
    }

    private func showInvisibilityFirstRunDialog() {
        let chord = shortcut(for: .toggleInvisibility).displayString
        NSApp.activate(ignoringOtherApps: true)
        _ = NugumiAlertController(
            title: "Invisibility mode is on",
            message: "Nugumi is now hidden from screenshots and screen sharing, and the menu-bar icon is gone. Press \(chord) anywhere to bring it back.",
            primaryButtonTitle: "Got it"
        ).showModal()
    }

    /// Flips the writing (draft) language with the configured alternate, swapping
    /// the two so the pair {writing language, alternate} is preserved each toggle.
    @objc private func toggleWritingLanguageAction() {
        let previous = draftTargetLanguage
        let next = writingToggleAlternate
        draftTargetLanguage = next
        writingToggleAlternate = previous
        translationPanelController?.close()
        translationPanelController = nil
        updateMenuState()
        mainWindowController?.bridge.refreshFromHost()
        LanguageToggleHUD.shared.show(text: "Writing in \(next.displayName)")
    }

    private func setupBootstrap() {
        wireBootstrap()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self else { return }
            // While onboarding is up, don't stack the main window on top of
            // it — the onboarding close handler opens it (on AI Engine when
            // no model is ready) via showMainWindowOnFirstRunIfNeeded.
            guard self.onboardingWindowController == nil else { return }
            if !self.bootstrap.isReady(for: self.textModelID) {
                self.presentMainWindow(section: .aiEngine)
            }
        }
    }

    private func wireBootstrap() {
        bootstrap.onChange = { [weak self] state in
            self?.handleBootstrapStateChange(state)
        }
        bootstrap.refresh()
    }

    @MainActor
    private func onModelSelectionChanged(for scope: ModelUseScope) {
        bootstrap.refresh()
        guard scope == .textActions else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self else { return }
            if !self.bootstrap.isReady(for: self.textModelID) {
                self.presentMainWindow(section: .aiEngine)
            }
        }
    }

    @MainActor
    private func handleBootstrapStateChange(_ state: BootstrapState) {
        let currentID = textModelID
        let previous = lastObservedModelReadyState[currentID] ?? .unknown
        let current = state.modelReady(for: currentID)
        if case .working = previous, case .ok = current {
            postTranslatorReadyNotification()
        }
        // Any model that just became ready can satisfy an engine preset —
        // e.g. a slot stuck on a broken factory default heals the moment
        // gpt-oss:20b / Gemma finishes installing (or is discovered already
        // installed on first refresh).
        let anyBecameReady = state.modelReady.contains { id, status in
            status.isTerminalOK && !(lastObservedModelReadyState[id]?.isTerminalOK ?? false)
        }
        for (id, status) in state.modelReady {
            lastObservedModelReadyState[id] = status
        }
        // A pull the user started from the AI Engine setup card just finished —
        // promote it to the everyday-text default, once. Runs before the
        // preset so an explicit pull wins the text slot.
        if let pendingID = pendingOllamaAutoSelectID,
           case .ok = state.modelReady(for: pendingID) {
            pendingOllamaAutoSelectID = nil
            applyModelSelection(pendingID, for: .textActions)
        }
        if anyBecameReady {
            applyEnginePreset(.ollama)
        }
        updateMenuState()
        mainWindowController?.bridge.refreshFromHost()
    }

    @MainActor
    private func postTranslatorReadyNotification() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                Self.deliverTranslatorReadyNotification()
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted {
                        Self.deliverTranslatorReadyNotification()
                    }
                }
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated private static func deliverTranslatorReadyNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Nugumi is ready"
        content.body = "The translator finished downloading. Press your shortcut or select text to start."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "nugumi.translator.ready.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// Launching the app again from /Applications while it's already running
    /// lands here (macOS sends a reopen event to the running instance). With
    /// the menu bar icon hidden this is the only way back into the app, so
    /// always surface a window: onboarding if the tour is still up, otherwise
    /// the main window.
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let onboardingWindowController {
            onboardingWindowController.presentAndActivate()
        } else {
            presentMainWindow()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
        }
        petController?.close()
        modifierDetectors.forEach { $0.stop() }
        modifierDetectors.removeAll()
        globalHotKeys.forEach { $0.unregister() }
        accessibilityTrustTimer?.invalidate()
        accessibilityTrustTimer = nil
        screenRecordingTrustTimer?.invalidate()
        screenRecordingTrustTimer = nil
    }

    private func setupStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.length = 24
        if let button = statusItem.button {
            button.title = ""
            button.image = makeStatusBarIcon(for: floatingDefaultMode)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.toolTip = "Nugumi"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        self.statusItem = statusItem
    }

    @MainActor
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isContextClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isContextClick, let button = statusItem?.button {
            let menu = makeStatusBarMenu()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
        } else {
            openMainWindow()
        }
    }

    @MainActor
    private func makeStatusBarMenu() -> NSMenu {
        let menu = NSMenu()
        if isRunningFromAppBundle {
            let updates = NSMenuItem(title: "Check for updates...", action: #selector(checkForUpdates), keyEquivalent: "")
            updates.target = self
            menu.addItem(updates)
        }
        let contact = NSMenuItem(title: "Contact me...", action: #selector(contactSupport), keyEquivalent: "")
        contact.target = self
        menu.addItem(contact)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Nugumi", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    /// The Nugumi pixel character with no background, rendered in its own colours
    /// (so the eyes and nose stay visible — a template would flatten it to a blob).
    private func makeStatusBarIcon(for mode: FloatingButtonDefaultMode) -> NSImage {
        let renderSize = NSSize(width: 42, height: 34)
        let mascot = PetMascotView(frame: NSRect(origin: .zero, size: renderSize))
        mascot.wantsLayer = false  // draw straight via draw(_:) so off-window cacheDisplay is reliable
        mascot.apply(state: .idle, mode: mode.translationMode)
        guard let rep = mascot.bitmapImageRepForCachingDisplay(in: mascot.bounds) else {
            return NSApp.applicationIconImage
        }
        mascot.cacheDisplay(in: mascot.bounds, to: rep)

        let targetHeight: CGFloat = 20
        let image = NSImage(size: NSSize(width: renderSize.width * targetHeight / renderSize.height, height: targetHeight))
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }

    private func refreshStatusBarIcon() {
        statusItem?.button?.image = makeStatusBarIcon(for: floatingDefaultMode)
    }

    private func startMouseMonitor() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseUp]) { [weak self] event in
            guard let self else { return }
            let mouseLocation = NSEvent.mouseLocation
            if event.type == .leftMouseDown {
                self.lastLeftMouseDownLocation = mouseLocation
                if self.isScreenshotTranslationRunning {
                    self.screenshotDragStartLocation = mouseLocation
                    self.screenshotDragEndLocation = nil
                }
                return
            }

            if event.type == .leftMouseDragged {
                if self.isScreenshotTranslationRunning {
                    self.updateScreenshotDrag(to: mouseLocation)
                }
                return
            }

            if self.isScreenshotTranslationRunning {
                if event.type == .leftMouseUp {
                    self.updateScreenshotDrag(to: mouseLocation)
                }
                return
            }

            self.handleMouseUp(event)
        }
    }

    private func startKeyboardMonitor() {
        // Global, listen-only — Cmd+A still propagates to the focused app so
        // its native select-all fires. We just want to know when it happened
        // so we can read the resulting selection and show the translate UI.
        keyboardMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard modifiers == .command, event.keyCode == UInt16(kVK_ANSI_A) else {
                return
            }
            self.handleSelectAll()
        }
    }

    private func handleSelectAll() {
        guard selectionDisplayMode != .off else { return }
        guard accessibilityIsTrusted() else { return }

        // Cmd+A inside Nugumi's own panels means "select the prompt input",
        // not "translate everything" — drop those events.
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let frontmostBundleID = frontmostApp?.bundleIdentifier
        if frontmostBundleID == Bundle.main.bundleIdentifier {
            return
        }
        let frontmostAppName = frontmostApp?.localizedName ?? frontmostBundleID ?? "this app"

        // The target app updates its AX selection state after macOS dispatches
        // the Cmd+A keystroke. Mirror the mouse-up gating delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            let preferClipboard = !self.selectionReader.isLikelyEditableElementAtMouseLocation()
            self.selectionReader.readSelectedTextContext(
                preferClipboard: preferClipboard,
                allowClipboardFallback: true
            ) { [weak self] selection in
                guard let self else { return }

                guard let selection, !selection.text.isEmpty else {
                    self.noteUnreadableSelection(
                        bundleID: frontmostBundleID,
                        appName: frontmostAppName
                    )
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    self.petController?.clearReady()
                    return
                }

                self.clearUnreadableSelectionCounter(bundleID: frontmostBundleID)

                let cleanedSelection = TextNormalizer.cleanedSelection(selection.text)
                guard !cleanedSelection.isEmpty,
                      TextNormalizer.looksMeaningful(cleanedSelection)
                else {
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    self.petController?.clearReady()
                    return
                }

                let anchor = self.selectAllAnchorPoint(from: selection.selectionRect)
                self.showTranslateButton(
                    for: cleanedSelection,
                    near: anchor,
                    selectionRect: selection.selectionRect,
                    panelSide: .right
                )
            }
        }
    }

    private func selectAllAnchorPoint(from rect: NSRect?) -> NSPoint {
        // Cmd+A has no mouse-based anchor. Prefer the bottom-right corner of
        // the reported selection rect; fall back to current pointer position.
        if let rect, rect.width > 0, rect.height > 0 {
            return NSPoint(x: rect.maxX, y: rect.minY)
        }
        return NSEvent.mouseLocation
    }

    @MainActor
    private func applySelectionDisplayMode() {
        switch selectionDisplayMode {
        case .floatingBar:
            petController?.close()
            petController = nil
        case .off:
            petController?.close()
            petController = nil
            translateButtonController?.close()
            translateButtonController = nil
        case .pet:
            translateButtonController?.close()
            translateButtonController = nil
            if petController == nil {
                petController = PetController(initialMode: floatingDefaultMode.translationMode)
            }
            petController?.show()
        }

        updateMenuState()
    }

    private func handleMouseUp(_ event: NSEvent) {
        guard accessibilityIsTrusted() else {
            return
        }

        // The shortcut recorder is up. Any synthesized ⌘+C we'd post during
        // the clipboard fallback below would land in Nugumi (now frontmost)
        // and the recorder field would capture it as the user's shortcut —
        // see KeyboardShortcutPoster.postCommandShortcut. Hard-skip while the
        // recorder is open.
        if shortcutRecorderWindowController != nil {
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        if let controller = translationPanelController,
           controller.isVisible,
           controller.panelFrame.insetBy(dx: -4, dy: -4).contains(mouseLocation) {
            return
        }

        // Capture the frontmost app at gesture time, not at completion time —
        // the user may have switched apps during the 80ms+AX-read window, and
        // we want to attribute the unreadable-selection signal to the app
        // where the drag actually happened.
        let isGesture = isLikelySelectionGesture(event)
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let frontmostBundleID = frontmostApp?.bundleIdentifier
        let frontmostAppName = frontmostApp?.localizedName ?? frontmostBundleID ?? "this app"

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            // The async window is long enough for the user to have brought
            // Nugumi to the front (e.g. opened the menu to set a shortcut).
            // Re-check before posting any synthetic keystrokes.
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
                return
            }
            if self.shortcutRecorderWindowController != nil {
                return
            }
            let preferClipboard = self.shouldAttemptClipboardSelectionFallback(for: event)

            // Clipboard fallback after a failed AX read covers apps that
            // expose a text-area-ish AX role (so `preferClipboard` is false)
            // but don't actually publish `kAXSelectedTextAttribute` —
            // KakaoTalk chat bubbles being the canonical example. Only allow
            // it when the user clearly meant to select something; otherwise
            // a stray click would synthesize Cmd+C for nothing.
            self.selectionReader.readSelectedTextContext(
                preferClipboard: preferClipboard,
                allowClipboardFallback: isGesture
            ) { [weak self] selection in
                guard let self else { return }

                guard let selection, !selection.text.isEmpty else {
                    if isGesture {
                        self.noteUnreadableSelection(
                            bundleID: frontmostBundleID,
                            appName: frontmostAppName
                        )
                    }
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    self.petController?.clearReady()
                    return
                }

                // The app exposed *some* selection text — even if we end up
                // discarding it as not meaningful below, that's a "user
                // selected garbage" case, not an "app blocks access" case.
                if isGesture {
                    self.clearUnreadableSelectionCounter(bundleID: frontmostBundleID)
                }

                let cleanedSelection = TextNormalizer.cleanedSelection(selection.text)
                guard !cleanedSelection.isEmpty,
                      TextNormalizer.looksMeaningful(cleanedSelection)
                else {
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    self.petController?.clearReady()
                    return
                }

                self.showTranslateButton(
                    for: cleanedSelection,
                    near: mouseLocation,
                    selectionRect: selection.selectionRect,
                    panelSide: self.panelSideForSelectionEnding(at: mouseLocation)
                )
            }
        }
    }

    private func panelSideForSelectionEnding(at mouseLocation: NSPoint) -> TranslationPanelController.Side {
        panelSideForDrag(from: lastLeftMouseDownLocation, to: mouseLocation)
    }

    private func panelSideForScreenshotEnding(at mouseLocation: NSPoint) -> TranslationPanelController.Side {
        screenshotPanelSide ?? panelSideForDrag(from: screenshotDragStartLocation, to: mouseLocation)
    }

    private func panelSideForDrag(from startLocation: NSPoint?, to endLocation: NSPoint) -> TranslationPanelController.Side {
        guard let startLocation else { return .right }

        let dx = endLocation.x - startLocation.x
        let dy = endLocation.y - startLocation.y
        // Need a meaningful horizontal drag — vertical or tiny drags
        // give no reliable direction signal, so default to .right.
        guard abs(dx) >= 5, abs(dx) > abs(dy) else { return .right }
        return dx > 0 ? .right : .left
    }

    private func updateScreenshotDrag(to mouseLocation: NSPoint) {
        screenshotDragEndLocation = mouseLocation
        screenshotPanelSide = panelSideForDrag(from: screenshotDragStartLocation, to: mouseLocation)
    }

    @MainActor
    private func startScreenshotDragTracking() {
        resetScreenshotDragTracking()
        let tracker = ScreenshotDragTracker { [weak self] startLocation, endLocation, panelSide in
            guard let self else { return }
            if let startLocation {
                self.screenshotDragStartLocation = startLocation
            }
            if let endLocation {
                self.screenshotDragEndLocation = endLocation
            }
            if let panelSide {
                self.screenshotPanelSide = panelSide
            }
        }
        screenshotDragTracker = tracker
        tracker.enable()
    }

    @MainActor
    private func resetScreenshotDragTracking() {
        screenshotDragTracker?.disable()
        screenshotDragTracker = nil
        screenshotDragStartLocation = nil
        screenshotDragEndLocation = nil
        screenshotPanelSide = nil
    }

    private func shouldAttemptClipboardSelectionFallback(for event: NSEvent) -> Bool {
        guard isLikelySelectionGesture(event) else {
            return false
        }

        return !selectionReader.isLikelyEditableElementAtMouseLocation()
    }

    private func isLikelySelectionGesture(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseUp else {
            return false
        }

        if event.clickCount >= 2 {
            return true
        }

        guard let downLocation = lastLeftMouseDownLocation else {
            return false
        }

        let upLocation = NSEvent.mouseLocation
        let distance = hypot(upLocation.x - downLocation.x, upLocation.y - downLocation.y)
        return distance >= 15
    }

    private func clearUnreadableSelectionCounter(bundleID: String?) {
        guard let bundleID else { return }
        unreadableSelectionFailureCounts[bundleID] = 0
    }

    private func noteUnreadableSelection(bundleID: String?, appName: String) {
        guard selectionDisplayMode != .off else { return }
        guard let bundleID, bundleID != Bundle.main.bundleIdentifier else { return }
        // UNUserNotificationCenter.current() aborts in non-bundle contexts
        // (`swift run`). Skipping here also avoids polluting the persistent
        // "already shown" set with bundles seen only during dev, which would
        // suppress the hint forever in the user-facing .app build.
        guard isRunningFromAppBundle else { return }

        let next = (unreadableSelectionFailureCounts[bundleID] ?? 0) + 1
        unreadableSelectionFailureCounts[bundleID] = next

        guard next >= Self.unreadableSelectionFailureThreshold else { return }

        let defaults = UserDefaults.standard
        let key = Self.unreadableSelectionHintShownDefaultsKey
        var shown = Set(defaults.stringArray(forKey: key) ?? [])
        guard !shown.contains(bundleID) else { return }
        shown.insert(bundleID)
        defaults.set(Array(shown).sorted(), forKey: key)

        Self.deliverUnreadableSelectionHint(appName: appName)
    }

    nonisolated private static func deliverUnreadableSelectionHint(appName: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                break
            default:
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Nugumi can't read text in \(appName)"
            content.body = "This app doesn't expose its selection to other apps. Try Screenshot Translation instead."
            let request = UNNotificationRequest(
                identifier: "nugumi.selection.unreadable.\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
    }

    @MainActor
    private func showTranslateButton(
        for selectedText: String,
        near screenPoint: NSPoint,
        selectionRect: NSRect? = nil,
        panelSide: TranslationPanelController.Side = .right
    ) {
        translationPanelController?.close()
        translateButtonController?.close()
        petController?.clearReady()

        guard selectionDisplayMode != .off else {
            return
        }

        let primaryMode = floatingDefaultMode.translationMode

        if selectionDisplayMode == .pet {
            if petController == nil {
                petController = PetController(initialMode: primaryMode)
            }
            petController?.show()
            petController?.showReady(
                selectedText: selectedText,
                initialMode: primaryMode,
                onTranslate: { [weak self] text in
                    self?.translate(
                        text,
                        near: screenPoint,
                        selectionRect: selectionRect,
                        panelSide: panelSide,
                        keepPetReadyUntilPanelCloses: true
                    )
                },
                onRewrite: { [weak self] text in
                    self?.rewriteSelectedDraftText(
                        text,
                        near: screenPoint,
                        selectionRect: selectionRect,
                        panelSide: panelSide,
                        keepPetReadyUntilPanelCloses: true
                    )
                },
                onSmartReply: { [weak self] text in
                    self?.replyToSelection(
                        text,
                        near: screenPoint,
                        selectionRect: selectionRect,
                        panelSide: panelSide,
                        keepPetReadyUntilPanelCloses: true
                    )
                }
            )
            return
        }

        let controller = FloatingTranslateButtonController(
            screenPoint: screenPoint,
            selectedText: selectedText,
            initialMode: primaryMode,
            onTranslate: { [weak self] text in
                self?.translateButtonController?.close()
                self?.translateButtonController = nil
                self?.translate(
                    text,
                    near: screenPoint,
                    selectionRect: selectionRect,
                    panelSide: panelSide
                )
            },
            onRewrite: { [weak self] text in
                self?.rewriteSelectedDraftText(
                    text,
                    near: screenPoint,
                    selectionRect: selectionRect,
                    panelSide: panelSide
                )
            },
            onSmartReply: { [weak self] text in
                self?.translateButtonController?.close()
                self?.translateButtonController = nil
                self?.replyToSelection(
                    text,
                    near: screenPoint,
                    selectionRect: selectionRect,
                    panelSide: panelSide
                )
            }
        )

        translateButtonController = controller
        controller.show()
    }

    @MainActor
    private func rewriteSelectedDraftText(
        _ text: String,
        near screenPoint: NSPoint,
        selectionRect: NSRect? = nil,
        panelSide: TranslationPanelController.Side = .right,
        keepPetReadyUntilPanelCloses: Bool = false
    ) {
        lastReplacementSourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        let cleanedDraft = TextNormalizer.cleanedDraftMessage(text)
        guard !cleanedDraft.isEmpty else {
            translateButtonController?.close()
            translateButtonController = nil
            petController?.clearReady()
            presentSelectionTranslationError("Select text first, then run Rewrite my text.")
            return
        }

        let language = draftTargetLanguage
        switch replacementMode {
        case .instantInsert:
            runInstantTranslation(cleanedDraft, language: language, near: screenPoint)
        case .showPanel:
            translateButtonController?.close()
            translateButtonController = nil
            translate(
                cleanedDraft,
                near: screenPoint,
                targetLanguage: language,
                mode: .draftMessage,
                useCache: false,
                usageKind: .draftMessage,
                selectionRect: selectionRect,
                panelSide: panelSide,
                keepPetReadyUntilPanelCloses: keepPetReadyUntilPanelCloses,
                onReplace: { [weak self] translation in
                    self?.replaceCurrentSelection(with: translation)
                },
                replaceShortcutSourcePID: lastReplacementSourcePID
            )
        }
    }

    @MainActor
    private func replyToSelection(
        _ text: String,
        near screenPoint: NSPoint,
        selectionRect: NSRect? = nil,
        panelSide: TranslationPanelController.Side = .right,
        keepPetReadyUntilPanelCloses: Bool = false
    ) {
        translate(
            text,
            near: screenPoint,
            targetLanguage: draftTargetLanguage,
            mode: .smartReply,
            useCache: false,
            usageKind: .smartReply,
            selectionRect: selectionRect,
            panelSide: panelSide,
            keepPetReadyUntilPanelCloses: keepPetReadyUntilPanelCloses
        )
    }

    @MainActor
    private func translate(
        _ text: String,
        near screenPoint: NSPoint,
        targetLanguage explicitTargetLanguage: TranslationLanguage? = nil,
        mode: TranslationMode = .selection,
        useCache: Bool = true,
        usageKind: UsageStatsEventKind = .selection,
        selectionRect: NSRect? = nil,
        panelSide: TranslationPanelController.Side = .right,
        keepPetReadyUntilPanelCloses: Bool = false,
        onReplace: ((String) -> Void)? = nil,
        replaceShortcutSourcePID: pid_t? = nil
    ) {
        if let setupError = translationErrorIfBootstrapNeedsSetup() {
            handleTranslationFailure(setupError)
            return
        }

        let language = explicitTargetLanguage ?? targetLanguage
        let currentThinkingLevel = textThinkingLevel
        let currentAppCategory = AppCategoryClassifier.frontmostCategory()
        let currentComposition = compositionSettings(for: mode, appCategory: currentAppCategory)
        let anchor: TranslationPanelController.Anchor =
            selectionRect.map(TranslationPanelController.Anchor.selection)
                ?? .point(screenPoint, panelSide: panelSide)
        let controller = TranslationPanelController(
            anchor: anchor,
            sourceText: text,
            targetLanguage: language,
            resultLabel: mode.resultLabel,
            loadingPlaceholder: mode.loadingPlaceholder,
            onTargetLanguageSelected: { [weak self] selectedLanguage in
                self?.retranslateCurrentPanel(
                    text,
                    targetLanguage: selectedLanguage,
                    mode: mode,
                    thinkingLevel: currentThinkingLevel,
                    appCategory: currentAppCategory,
                    composition: currentComposition,
                    useCache: useCache,
                    usageKind: usageKind
                )
            },
            onReplace: onReplace,
            replaceShortcutSourcePID: replaceShortcutSourcePID,
            onClose: { [weak self] in
                self?.translationPanelController = nil
                self?.petController?.clearReady()
            }
        )
        translationPanelController?.close()
        translationPanelController = controller
        if keepPetReadyUntilPanelCloses {
            holdPetReadyUntilActivePanelCloses(mode: mode)
        }
        let requestID = controller.showLoading()
        runTranslation(
            text,
            targetLanguage: language,
            mode: mode,
            thinkingLevel: currentThinkingLevel,
            appCategory: currentAppCategory,
            composition: currentComposition,
            useCache: useCache,
            usageKind: usageKind,
            controller: controller,
            requestID: requestID
        )
    }

    @MainActor
    private func compositionSettings(for mode: TranslationMode, appCategory: AppCategory) -> CompositionSettings? {
        // TEMP DIAGNOSTIC (voice-sample issue) — remove once resolved.
        CodexDebugLog.append("[voice-debug] mode=\(mode) category=\(appCategory) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil") savedSampleChars=\(emailVoiceSample.count)")
        guard mode.usesCompositionSettings else {
            // Translate/selection ignores writing style, cleanup, snippets, and
            // voice sample. The only composition input it honors is the global
            // Gen Z toggle, so synthesize a minimal carrier — and only when that
            // toggle is on, so default (off) behavior stays exactly as before.
            guard genZModeEnabled else { return nil }
            return CompositionSettings(style: .casual, cleanup: .none, snippets: [], genZ: true, voiceSample: nil)
        }
        let voiceSample = appCategory == .email
            ? emailVoiceSample.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return CompositionSettings(
            style: writingStyle(for: appCategory),
            cleanup: cleanupLevel,
            snippets: snippetsStore.usableSnippets(),
            genZ: genZModeEnabled,
            voiceSample: voiceSample.isEmpty ? nil : voiceSample
        )
    }

    @MainActor
    private func holdPetReadyUntilActivePanelCloses(mode: TranslationMode) {
        guard selectionDisplayMode == .pet else {
            return
        }

        if petController == nil {
            petController = PetController(initialMode: mode)
        }
        petController?.show()
        petController?.holdReadyUntilPanelCloses(mode: mode)
    }

    @MainActor
    private func retranslateCurrentPanel(
        _ text: String,
        targetLanguage language: TranslationLanguage,
        mode: TranslationMode,
        thinkingLevel: ThinkingLevel,
        appCategory: AppCategory,
        composition: CompositionSettings?,
        useCache: Bool,
        usageKind: UsageStatsEventKind
    ) {
        guard let controller = translationPanelController else {
            return
        }

        let requestID = controller.showLoading(targetLanguage: language)
        runTranslation(
            text,
            targetLanguage: language,
            mode: mode,
            thinkingLevel: thinkingLevel,
            appCategory: appCategory,
            composition: composition,
            useCache: useCache,
            usageKind: usageKind,
            controller: controller,
            requestID: requestID
        )
    }

    @MainActor
    private func runTranslation(
        _ text: String,
        targetLanguage language: TranslationLanguage,
        mode: TranslationMode,
        thinkingLevel: ThinkingLevel,
        appCategory: AppCategory,
        composition: CompositionSettings?,
        useCache: Bool,
        usageKind: UsageStatsEventKind,
        controller: TranslationPanelController,
        requestID: UUID
    ) {
        if let busyError = translationErrorIfBootstrapBusy() {
            controller.showError(Self.translationPanelErrorMessage(for: busyError), requestID: requestID)
            return
        }

        if useCache, let cachedTranslation = translationCache.translation(for: text, targetLanguage: language, thinkingLevel: thinkingLevel) {
            recordTranslation(source: text, result: cachedTranslation, kind: usageKind, targetLanguage: language)
            analyticsClient.trackCompletedUsage(
                kind: usageKind,
                targetLanguageID: language.id,
                modelID: textModelID
            )
            controller.showTranslation(cachedTranslation, requestID: requestID)
            return
        }

        let backend = currentBackend
        Task {
            do {
                let translated = try await backend.translate(
                    text,
                    images: [],
                    to: language,
                    mode: mode,
                    appCategory: appCategory,
                    composition: composition,
                    thinkingLevel: thinkingLevel
                ) { partialTranslation in
                    Task { @MainActor in
                        controller.showTranslation(partialTranslation, requestID: requestID)
                    }
                }
                await MainActor.run {
                    if useCache {
                        self.translationCache.store(translated, for: text, targetLanguage: language, thinkingLevel: thinkingLevel)
                    }
                    self.recordTranslation(source: text, result: translated, kind: usageKind, targetLanguage: language)
                    self.analyticsClient.trackCompletedUsage(
                        kind: usageKind,
                        targetLanguageID: language.id,
                        modelID: self.textModelID
                    )
                    controller.showTranslation(translated, requestID: requestID)
                }
            } catch {
                await MainActor.run {
                    if self.handleTranslationFailure(error, controller: controller) {
                        return
                    }
                    self.analyticsClient.track(.errorOccurred, properties: [
                        "error_type": Self.analyticsErrorType(error),
                        "error_context": "translation"
                    ])
                    controller.showError(Self.translationPanelErrorMessage(for: error), requestID: requestID)
                }
            }
        }
    }

    @MainActor
    @discardableResult
    private func handleTranslationFailure(_ error: Error, controller: TranslationPanelController? = nil) -> Bool {
        guard let translationError = error as? TranslationError else { return false }
        switch translationError {
        case .serverUnavailable, .modelMissing, .signInRequired:
            controller?.close()
            bootstrap.refresh()
            presentMainWindow(section: .aiEngine)
            return true
        case .invalidAPIKey(let provider):
            controller?.close()
            if provider == .openAICodex {
                KeychainStore.setCodexCredentials(nil)
            } else {
                KeychainStore.setAPIKey(nil, for: provider)
            }
            bootstrap.refresh()
            presentCredentialPrompt(for: provider) { _ in }
            return true
        case .ollama, .emptyResponse, .modelDownloading, .rateLimited, .cloudError:
            return false
        }
    }

    private static func analyticsErrorType(_ error: Error) -> String {
        if let translationError = error as? TranslationError {
            switch translationError {
            case .ollama: return "ollama"
            case .emptyResponse: return "empty_response"
            case .modelDownloading: return "model_downloading"
            case .serverUnavailable: return "server_unavailable"
            case .modelMissing: return "model_missing"
            case .signInRequired: return "sign_in_required"
            case .invalidAPIKey: return "invalid_api_key"
            case .rateLimited: return "rate_limited"
            case .cloudError: return "cloud_error"
            }
        }
        return String(describing: type(of: error))
    }

    private static func translationPanelErrorMessage(for error: Error) -> String {
        guard let translationError = error as? TranslationError else {
            return "Could not translate this.\n\(error.localizedDescription)"
        }

        switch translationError {
        case .ollama(let message):
            return "Could not translate this.\n\(message)"
        case .emptyResponse:
            return "No translation came back. Try again."
        case .modelDownloading(let detail):
            return "Translator is still downloading.\n\(detail)"
        case .serverUnavailable:
            return "Ollama is not running."
        case .modelMissing:
            return "Translator is not downloaded yet."
        case .signInRequired:
            return "Sign in to Ollama to use the online translator."
        case .invalidAPIKey(let provider):
            return "\(provider.displayName) rejected the API key."
        case .rateLimited(let provider):
            return "\(provider.displayName) rate limit reached. Try again in a minute."
        case .cloudError(let provider, let detail):
            return "\(provider.displayName): \(detail)"
        }
    }

    @MainActor
    private func translationErrorIfBootstrapBusy(for modelID: String? = nil) -> TranslationError? {
        let modelID = modelID ?? textModelID
        if case .working(let detail) = bootstrap.state.modelReady(for: modelID) {
            return .modelDownloading(detail)
        }
        return nil
    }

    @MainActor
    private func translationErrorIfBootstrapNeedsSetup(for modelID: String? = nil) -> TranslationError? {
        let modelID = modelID ?? textModelID
        let model = LLMModel.option(id: modelID)
        if let provider = model.cloudProvider {
            if case .needsAction = bootstrap.state.cloudKey(for: provider) {
                return .invalidAPIKey(provider)
            }
            return nil
        }

        if case .needsAction = bootstrap.state.ollamaInstalled {
            return .serverUnavailable
        }
        if case .needsAction = bootstrap.state.serverRunning {
            return .serverUnavailable
        }
        if case .needsAction = bootstrap.state.ollamaSignedIn,
           model.isCloud {
            return .signInRequired
        }
        if case .needsAction = bootstrap.state.modelReady(for: modelID) {
            return .modelMissing(modelID)
        }
        return nil
    }

    @MainActor
    private func requestAccessibilityPermissionIfNeeded() {
        // prompt:false silently registers Nugumi in System Settings → Privacy &
        // Security → Accessibility (so the TCC entry exists and the user can find
        // the toggle), without surfacing macOS's stock "would like to control this
        // computer using accessibility features" dialog. The friendlier prompt
        // lives in OnboardingWindowController.
        let probe = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false] as CFDictionary
        guard !AXIsProcessTrustedWithOptions(probe) else {
            return
        }
        startAccessibilityTrustWatcher()
    }

    private func accessibilityIsTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    private func startAccessibilityTrustWatcher() {
        guard accessibilityTrustTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }
                if self.accessibilityIsTrusted() {
                    timer.invalidate()
                    self.accessibilityTrustTimer = nil
                    self.trackPermissionGranted(.accessibility)
                    self.updateMenuState()
                    self.presentPermissionsWindowIfNeeded()
                }
            }
        }
        accessibilityTrustTimer = timer
    }

    private func requestScreenRecordingPermissionIfNeeded() {
        // No CGRequestScreenCaptureAccess() at launch — that triggers Apple's
        // stock "would like to record this screen" dialog, which we replace
        // with our own row in OnboardingWindowController. The actual TCC
        // registration happens lazily when the user clicks "Open settings" in
        // that window, or on the first screenshot attempt.
        guard !CGPreflightScreenCaptureAccess() else {
            return
        }
        startScreenRecordingTrustWatcher()
    }

    private func startScreenRecordingTrustWatcher() {
        guard screenRecordingTrustTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }
                if CGPreflightScreenCaptureAccess() {
                    timer.invalidate()
                    self.screenRecordingTrustTimer = nil
                    self.trackPermissionGranted(.screenRecording)
                    self.updateMenuState()
                    self.presentPermissionsWindowIfNeeded()
                }
            }
        }
        screenRecordingTrustTimer = timer
    }

    private func presentPermissionsWindowIfNeeded() {
        presentPermissionsWindow(force: false)
    }

    private func presentPermissionsWindow(force: Bool) {
        let axTrusted = AXIsProcessTrusted()
        let scrTrusted = CGPreflightScreenCaptureAccess()
        guard force
            || !(axTrusted && scrTrusted)
            || !OnboardingWindowController.hasCompletedFeatureTour
            // Initial setup unfinished (the post-Screen-Recording restart
            // lands here): reopen onboarding so the engine choice still
            // happens.
            || !OnboardingModel.mainWindowEverAutoShown
            || OnboardingModel.devPageOverride != nil
        else { return }
        if let onboardingWindowController {
            onboardingWindowController.presentAndActivate()
            return
        }

        if !OnboardingWindowController.hasCompletedFeatureTour {
            analyticsClient.trackOnboardingStartedIfNeeded(properties: permissionStatusProperties(
                accessibilityTrusted: axTrusted,
                screenRecordingTrusted: scrTrusted
            ))
        }
        if !(axTrusted && scrTrusted) {
            analyticsClient.trackPermissionsPromptedIfNeeded(properties: permissionStatusProperties(
                accessibilityTrusted: axTrusted,
                screenRecordingTrusted: scrTrusted
            ))
        }
        let controller = OnboardingWindowController(
            mode: force ? .review : .firstRun,
            onPickEngine: { [weak self] choice in
                guard let self else { return }
                self.presentMainWindow(section: .aiEngine)
                self.mainWindowController?.bridge.engineSetupFocus = choice
            },
            onTourFinished: { [weak self] skipped in
                self?.analyticsClient.trackOnboardingCompletedIfNeeded(skipped: skipped)
            }
        ) { [weak self] in
            guard let self else { return }
            let closedForSystemDialog = self.onboardingWindowController?.closedForSystemDialog ?? false
            self.onboardingWindowController = nil
            // Onboarding is really over (not just hidden for a macOS
            // permission dialog) — now the main window may take the stage.
            if !closedForSystemDialog {
                self.showMainWindowOnFirstRunIfNeeded()
            }
        }
        onboardingWindowController = controller
        controller.presentAndActivate()
    }

    private func trackPermissionGranted(_ permission: PermissionKind, source: String = "watcher") {
        let axTrusted = AXIsProcessTrusted()
        let scrTrusted = CGPreflightScreenCaptureAccess()
        var properties = permissionStatusProperties(
            accessibilityTrusted: axTrusted,
            screenRecordingTrusted: scrTrusted
        )
        properties["permission"] = permission.analyticsValue
        properties["source"] = source
        analyticsClient.trackPermissionGrantedIfNeeded(
            permission: permission.analyticsValue,
            properties: properties
        )
        if axTrusted && scrTrusted {
            analyticsClient.trackPermissionsCompletedIfNeeded(properties: properties)
        }
    }

    /// Granting Screen Recording force-relaunches the app, killing the trust
    /// watchers before they can report. Recover at launch: any permission
    /// that is granted but was never tracked gets its one-shot event here.
    private func reconcilePermissionAnalyticsAtLaunch() {
        if AXIsProcessTrusted() {
            trackPermissionGranted(.accessibility, source: "launch")
        }
        if CGPreflightScreenCaptureAccess() {
            trackPermissionGranted(.screenRecording, source: "launch")
        }
    }

    private func permissionStatusProperties(accessibilityTrusted: Bool, screenRecordingTrusted: Bool) -> [String: String] {
        [
            "accessibility_status": accessibilityTrusted ? "granted" : "missing",
            "screen_recording_status": screenRecordingTrusted ? "granted" : "missing"
        ]
    }

    private func updateMenuState() {
        guard let menu = statusItem?.menu else {
            return
        }

        let trusted = accessibilityIsTrusted()
        menu.item(withTag: MenuItemTag.permissionNotice.rawValue)?.isHidden = trusted
        menu.item(withTag: MenuItemTag.accessibilitySettings.rawValue)?.isHidden = trusted
        menu.item(withTag: MenuItemTag.permissionSeparator.rawValue)?.isHidden = trusted

        let bootstrapReady = bootstrap.isReady(for: textModelID)
        menu.item(withTag: MenuItemTag.bootstrapNotice.rawValue)?.isHidden = bootstrapReady
        menu.item(withTag: MenuItemTag.bootstrapAction.rawValue)?.title = bootstrapReady
            ? "Setup..."
            : "Open setup..."
        menu.item(withTag: MenuItemTag.bootstrapSeparator.rawValue)?.isHidden = bootstrapReady
        menu.item(withTag: MenuItemTag.checkForUpdates.rawValue)?.isHidden = !isRunningFromAppBundle
        if let translateSelectionItem = menu.item(withTag: MenuItemTag.translateSelection.rawValue) {
            translateSelectionItem.title = "Rewrite my text in \(draftTargetLanguage.displayName)..."
            applyShortcut(for: .translateSelection, to: translateSelectionItem)
            translateSelectionItem.isEnabled = trusted
        }
        if let screenshotItem = menu.item(withTag: MenuItemTag.screenshotArea.rawValue) {
            let idleTitle: String
            switch floatingDefaultMode {
            case .translate:
                idleTitle = "Translate screen area to \(targetLanguage.displayName)..."
            case .smartReply:
                idleTitle = "Reply to screen area in \(draftTargetLanguage.displayName)..."
            }
            screenshotItem.title = isScreenshotTranslationRunning
                ? "Selecting screen area..."
                : idleTitle
            applyShortcut(for: .screenshotArea, to: screenshotItem)
            screenshotItem.isEnabled = !isScreenshotTranslationRunning
        }
        if let selectionItem = menu.item(withTag: MenuItemTag.translateOrReplySelection.rawValue) {
            switch floatingDefaultMode {
            case .translate:
                selectionItem.title = "Translate selected text to \(targetLanguage.displayName)..."
            case .smartReply:
                selectionItem.title = "Reply to selected text in \(draftTargetLanguage.displayName)..."
            }
            applyShortcut(for: .translateOrReply, to: selectionItem)
            selectionItem.isEnabled = trusted
        }

        if let invisibilityItem = menu.item(withTag: MenuItemTag.invisibilityMode.rawValue) {
            invisibilityItem.state = invisibilityModeEnabled ? .on : .off
            let chord = shortcut(for: .toggleInvisibility)
            invisibilityItem.keyEquivalent = chord.menuKeyEquivalent
            invisibilityItem.keyEquivalentModifierMask = chord.keyEquivalentModifierMask
        }
    }

    private func applyShortcut(for action: GlobalShortcutAction, to item: NSMenuItem) {
        let shortcut = shortcut(for: action)
        item.keyEquivalent = shortcut.menuKeyEquivalent
        item.keyEquivalentModifierMask = shortcut.keyEquivalentModifierMask
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @MainActor
    @objc private func openOnboardingWindow() {
        presentMainWindow(section: .aiEngine)
    }

    @MainActor
    @objc private func openPermissionsOnboardingWindow() {
        presentPermissionsWindow(force: true)
    }

    @MainActor
    @objc private func openSnippetsWindow() {
        if let snippetsWindowController {
            snippetsWindowController.presentAndFocus()
            return
        }
        let controller = SnippetsWindowController(store: snippetsStore) { [weak self] in
            self?.snippetsWindowController = nil
        }
        snippetsWindowController = controller
        controller.presentAndFocus()
    }

    @MainActor
    @objc private func openMainWindow() {
        presentMainWindow()
    }

    /// Opens (or focuses) the main window, optionally jumping to a section. This
    /// is also the entry point for "setup" — the AI Engine section now hosts the
    /// full backend setup flow that used to live in a standalone window.
    @MainActor
    private func presentMainWindow(section: MainWindowSection? = nil) {
        let controller: MainWindowController
        if let mainWindowController {
            controller = mainWindowController
        } else {
            controller = MainWindowController(host: self) { [weak self] in
                self?.mainWindowController = nil
            }
            mainWindowController = controller
        }
        // Programmatic jumps to AI Engine always mean "set up a provider" —
        // land on the Providers tab. Sidebar clicks keep the Models tab.
        if section == .aiEngine {
            controller.bridge.aiEngineTab = 1
        }
        controller.presentAndFocus(section: section)
    }

    @MainActor
    @objc private func translateScreenshotAreaFromMenu() {
        startScreenshotTranslation()
    }

    @MainActor
    @objc private func translateSelectedTextFromMenu() {
        startSelectedTextTranslationForReplacement()
    }

    @objc private func translateOrReplySelectionFromMenu() {
        startSelectionTranslateOrReply()
    }

    @objc private func contactSupport() {
        let metadata = supportMetadata()
        let subject = "Nugumi bug or request"
        let body = """
        Hey Vadim,

        <tell me about your bug or request>

        --

        \(metadata)
        """

        var components = URLComponents(string: "https://mail.google.com/mail/")!
        components.queryItems = [
            URLQueryItem(name: "view", value: "cm"),
            URLQueryItem(name: "fs", value: "1"),
            URLQueryItem(name: "to", value: "tsoivadim97@gmail.com"),
            URLQueryItem(name: "su", value: subject),
            URLQueryItem(name: "body", value: body)
        ]

        if let url = components.url, NSWorkspace.shared.open(url) {
            return
        }

        let errorAlert = NSAlert()
        errorAlert.messageText = "Could not open Gmail"
        errorAlert.informativeText = "Please email Vadim directly at tsoivadim97@gmail.com."
        errorAlert.alertStyle = .warning
        errorAlert.runModal()
    }

    private func supportMetadata() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let architecture = nativeArchitecture
        let screenCount = NSScreen.screens.count

        return """
        App: Nugumi \(version)
        Build: \(build)
        macOS: \(osVersion)
        Mac: \(hardwareModel()) (\(architecture))
        Number of screens: \(screenCount)
        Triggered from: menu bar
        """
    }

    private var nativeArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown Mac"
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
            return "unknown Mac"
        }

        return String(cString: buffer)
    }

    @MainActor
    private func startSelectionTranslateOrReply() {
        guard accessibilityIsTrusted() else {
            requestAccessibilityPermissionIfNeeded()
            presentPermissionsWindowIfNeeded()
            return
        }

        translateButtonController?.close()
        translateButtonController = nil
        petController?.clearReady()

        let mode = floatingDefaultMode

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }

            self.selectionReader.readSelectedTextContext(allowClipboardFallback: true) { [weak self] selection in
                guard let self else { return }

                let shortcutDisplay = self.shortcut(for: .translateOrReply).displayString

                guard let selection else {
                    self.presentSelectionTranslationError("Select text first, then press \(shortcutDisplay).")
                    return
                }

                let mouseLocation = NSEvent.mouseLocation
                let panelSide = self.panelSideForSelectionEnding(at: mouseLocation)

                switch mode {
                case .smartReply:
                    let cleaned = TextNormalizer.cleanedSelection(selection.text)
                    guard !cleaned.isEmpty else {
                        self.presentSelectionTranslationError("Select text first, then press \(shortcutDisplay).")
                        return
                    }
                    self.replyToSelection(
                        cleaned,
                        near: mouseLocation,
                        selectionRect: selection.selectionRect,
                        panelSide: panelSide
                    )
                case .translate:
                    let cleaned = TextNormalizer.cleanedSelection(selection.text)
                    guard !cleaned.isEmpty else {
                        self.presentSelectionTranslationError("Select text first, then press \(shortcutDisplay).")
                        return
                    }
                    self.translate(
                        cleaned,
                        near: mouseLocation,
                        mode: .selection,
                        usageKind: .selection,
                        selectionRect: selection.selectionRect,
                        panelSide: panelSide
                    )
                }
            }
        }
    }

    @MainActor
    private func startSelectedTextTranslationForReplacement() {
        guard accessibilityIsTrusted() else {
            requestAccessibilityPermissionIfNeeded()
            presentPermissionsWindowIfNeeded()
            return
        }


        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }

            self.selectionReader.readSelectedTextContext(allowClipboardFallback: true) { [weak self] selection in
                guard let self else { return }

                guard let selection else {
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    self.petController?.clearReady()
                    self.presentSelectionTranslationError("Select text first, then press \(self.shortcut(for: .translateSelection).displayString).")
                    return
                }

                let cleanedDraft = TextNormalizer.cleanedDraftMessage(selection.text)
                guard !cleanedDraft.isEmpty else {
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    self.petController?.clearReady()
                    self.presentSelectionTranslationError("Select text first, then press \(self.shortcut(for: .translateSelection).displayString).")
                    return
                }

                let mouseLocation = NSEvent.mouseLocation
                self.rewriteSelectedDraftText(
                    cleanedDraft,
                    near: mouseLocation,
                    selectionRect: selection.selectionRect,
                    panelSide: self.panelSideForSelectionEnding(at: mouseLocation),
                    keepPetReadyUntilPanelCloses: true
                )
            }
        }
    }

    @MainActor
    private func runInstantTranslation(_ text: String, language: TranslationLanguage, near screenPoint: NSPoint) {
        if let setupError = translationErrorIfBootstrapNeedsSetup() {
            handleTranslationFailure(setupError)
            return
        }

        if let busyError = translationErrorIfBootstrapBusy() {
            presentSelectionTranslationError(
                busyError.localizedDescription,
                title: "Translator is still downloading"
            )
            return
        }

        let currentThinkingLevel = textThinkingLevel
        let currentAppCategory = AppCategoryClassifier.frontmostCategory()
        let currentComposition = compositionSettings(for: .draftMessage, appCategory: currentAppCategory)

        let loadingBar = showInstantTranslationLoading(near: screenPoint)

        let client = currentBackend
        Task { [weak self] in
            do {
                let translated = try await client.translate(
                    text,
                    images: [],
                    to: language,
                    mode: .draftMessage,
                    appCategory: currentAppCategory,
                    composition: currentComposition,
                    thinkingLevel: currentThinkingLevel
                ) { _ in }
                await MainActor.run {
                    guard let self else { return }
                    self.recordTranslation(source: text, result: translated, kind: .draftMessage, targetLanguage: language)
                    self.analyticsClient.trackCompletedUsage(
                        kind: .draftMessage,
                        targetLanguageID: language.id,
                        modelID: self.textModelID
                    )
                    self.hideInstantTranslationLoading(loadingBar)
                    self.replaceCurrentSelection(with: translated)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.hideInstantTranslationLoading(loadingBar)
                    let routedToOnboarding = self.handleTranslationFailure(error)
                    if !routedToOnboarding {
                        self.analyticsClient.track(.errorOccurred, properties: [
                            "error_type": Self.analyticsErrorType(error),
                            "error_context": "instant_rewrite"
                        ])
                        self.presentSelectionTranslationError(
                            error.localizedDescription,
                            title: "Translation failed"
                        )
                    }
                }
            }
        }
    }

    @MainActor
    private func showInstantTranslationLoading(near screenPoint: NSPoint) -> FloatingTranslateButtonController? {
        switch selectionDisplayMode {
        case .pet:
            if petController == nil {
                petController = PetController(initialMode: .draftMessage)
            }
            petController?.showThinking()
            return nil
        case .floatingBar:
            // Reuse the bar that's already on screen so it morphs in place
            // instead of flickering — its panel stays at the same origin.
            let bar: FloatingTranslateButtonController
            if let existing = translateButtonController {
                bar = existing
                translateButtonController = nil
            } else {
                bar = FloatingTranslateButtonController(
                    screenPoint: screenPoint,
                    selectedText: "",
                    initialMode: .selection,
                    onTranslate: { _ in },
                    onRewrite: { _ in },
                    onSmartReply: { _ in }
                )
                bar.show()
            }
            bar.setLoading()
            floatingLoadingBar?.close()
            floatingLoadingBar = bar
            return bar
        case .off:
            return nil
        }
    }

    @MainActor
    private func hideInstantTranslationLoading(_ loadingBar: FloatingTranslateButtonController?) {
        petController?.clearThinking()
        guard let loadingBar else { return }
        loadingBar.close()
        if floatingLoadingBar === loadingBar {
            floatingLoadingBar = nil
        }
    }

    @MainActor
    private func replaceCurrentSelection(with translation: String) {
        let cleanTranslation = TextNormalizer.cleanedTranslation(translation)
        guard !cleanTranslation.isEmpty else {
            return
        }

        let sourcePID = lastReplacementSourcePID
        lastReplacementSourcePID = nil

        // Tear down panel + interceptors first so they can't intercept the
        // synthesized Cmd+V or leave the source app's text view in a stale
        // resign-key state.
        translationPanelController?.close()
        translationPanelController = nil

        let performPaste: @MainActor () -> Void = { [weak self] in
            PasteboardTextInserter.replaceCurrentSelection(with: cleanTranslation)
            self?.usageStatsStore.recordReplacement(text: cleanTranslation)
        }

        if let pid = sourcePID, let runningApp = NSRunningApplication(processIdentifier: pid) {
            // Always reactivate source — even if frontmost == source — because
            // some apps (notably Electron-based ones) drop their text view's
            // selection when their window briefly resigned key while the panel
            // was up.
            runningApp.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                performPaste()
            }
        } else {
            performPaste()
        }
    }

    @MainActor
    private func startScreenshotTranslation() {
        guard !isScreenshotTranslationRunning else {
            return
        }

        isScreenshotTranslationRunning = true
        startScreenshotDragTracking()
        updateMenuState()
        translateButtonController?.close()
        translateButtonController = nil
        petController?.clearReady()
        translationPanelController?.close()
        translationPanelController = nil

        Task { [weak self] in
            do {
                let screenshotURL = try await ScreenshotCapture.captureInteractiveArea()
                defer {
                    try? FileManager.default.removeItem(at: screenshotURL)
                }

                let recognizedText = try await ImageTextRecognizer.recognizeText(in: screenshotURL)
                await MainActor.run {
                    guard let self else { return }
                    self.isScreenshotTranslationRunning = false
                    self.updateMenuState()

                    let sourceText = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !TextNormalizer.cleanedSelection(sourceText).isEmpty else {
                        self.resetScreenshotDragTracking()
                        self.presentScreenshotTranslationError(ScreenshotTranslationError.noTextRecognized)
                        return
                    }

                    let mouseLocation = NSEvent.mouseLocation
                    let panelSide = self.panelSideForScreenshotEnding(at: mouseLocation)
                    self.resetScreenshotDragTracking()
                    let mode = self.floatingDefaultMode.translationMode
                    let usageKind: UsageStatsEventKind
                    let language: TranslationLanguage
                    switch mode {
                    case .smartReply:
                        usageKind = .smartReply
                        language = self.draftTargetLanguage
                    case .selection, .draftMessage:
                        usageKind = .screenArea
                        language = self.targetLanguage
                    }
                    self.translate(
                        sourceText,
                        near: mouseLocation,
                        targetLanguage: language,
                        mode: mode,
                        useCache: mode == .selection,
                        usageKind: usageKind,
                        panelSide: panelSide,
                        keepPetReadyUntilPanelCloses: true
                    )
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isScreenshotTranslationRunning = false
                    self.resetScreenshotDragTracking()
                    self.updateMenuState()
                    guard !ScreenshotTranslationError.isCancellation(error) else {
                        return
                    }
                    self.presentScreenshotTranslationError(error)
                }
            }
        }
    }

    @MainActor
    private func presentScreenshotTranslationError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)

        if let screenshotError = error as? ScreenshotTranslationError,
           case .screenRecordingPermissionDenied = screenshotError {
            let response = NugumiAlertController(
                title: "Screen recording required",
                message: screenshotError.localizedDescription,
                primaryButtonTitle: "Open settings",
                secondaryButtonTitle: "Quit Nugumi"
            ).showModal()
            switch response {
            case .alertFirstButtonReturn:
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                NSWorkspace.shared.open(url)
            case .alertSecondButtonReturn:
                NSApp.terminate(nil)
            default:
                break
            }
            return
        }

        _ = NugumiAlertController(
            title: "Screenshot translation failed",
            message: error.localizedDescription,
            primaryButtonTitle: "OK"
        ).showModal()
    }

    @MainActor
    private func presentSelectionTranslationError(_ message: String, title: String = "No text selected") {
        NSApp.activate(ignoringOtherApps: true)
        _ = NugumiAlertController(
            title: title,
            message: message,
            primaryButtonTitle: "OK"
        ).showModal()
    }

    @MainActor
    private func presentCredentialPrompt(for provider: CloudProvider, onSave: @escaping (Bool) -> Void) {
        if provider == .openAICodex {
            Task { @MainActor in
                let outcome = await CodexLoginAlert.present()
                switch outcome {
                case .success:
                    self.bootstrap.refresh()
                    self.applyEnginePreset(.cloud(.openAICodex))
                    onSave(true)
                case .cancelled:
                    onSave(false)
                case .failed(let message):
                    self.presentSelectionTranslationError(message, title: "ChatGPT sign-in failed")
                    onSave(false)
                }
            }
        } else {
            presentAPIKeySheet(for: provider, onSave: onSave)
        }
    }

    /// "Sign out" / "Remove key" on a provider card. Confirms, wipes the
    /// credentials, then re-points any model slot that just went dead at a
    /// still-connected engine so the app never sits on a broken selection.
    @MainActor
    private func disconnectCloudProvider(_ provider: CloudProvider) {
        NSApp.activate(ignoringOtherApps: true)
        let isOAuth = provider.usesOAuth
        let response = NugumiAlertController(
            title: isOAuth ? "Sign out of \(provider.displayName)?" : "Remove \(provider.displayName) API key?",
            message: isOAuth
                ? "Nugumi will forget this account. Models from \(provider.displayName) stop working until you sign in again."
                : "The key is deleted from this Mac. Models from \(provider.displayName) stop working until you add a key again.",
            primaryButtonTitle: isOAuth ? "Sign out" : "Remove key",
            secondaryButtonTitle: "Cancel"
        ).showModal()
        guard response == .alertFirstButtonReturn else { return }

        if provider == .openAICodex {
            KeychainStore.setCodexCredentials(nil)
        } else {
            KeychainStore.setAPIKey(nil, for: provider)
        }
        bootstrap.refresh()
        healModelSlots()
        updateMenuState()
        mainWindowController?.bridge.refreshFromHost()
    }

    /// Walks the engines in rough popularity order and lets each one's preset
    /// claim any broken slot (`applyEnginePreset` never touches a working
    /// selection, so the first still-connected engine wins).
    @MainActor
    private func healModelSlots() {
        let engines: [EngineModelPreset] = [
            .cloud(.openAICodex), .ollama, .cloud(.openAI), .cloud(.anthropic), .cloud(.gemini)
        ]
        for engine in engines {
            applyEnginePreset(engine)
        }
    }

    @MainActor
    func runCloudTest(for provider: CloudProvider) async -> CloudTestResult {
        let model: LLMModel
        let client: any LLMBackend
        switch provider {
        case .openAICodex:
            guard let m = LLMModel.codexModels.first else {
                return .failure("No Codex models known yet — sign in first.")
            }
            guard provider.hasCredentials else {
                return .failure("Not signed in to ChatGPT.")
            }
            model = m
            client = OpenAICodexClient(apiModelID: m.apiModelID)
        case .openAI, .anthropic, .gemini:
            // Merged list, not the static curated one: if the provider has
            // retired the first curated model, the picker hides it — the
            // connectivity test must not keep hitting that dead id.
            guard let m = LLMModel.cloudModels(for: provider).first else {
                return .failure("No model registered for \(provider.displayName).")
            }
            guard let apiKey = KeychainStore.apiKey(for: provider), !apiKey.isEmpty else {
                return .failure("No API key saved.")
            }
            model = m
            client = OpenAIChatClient(provider: provider, apiKey: apiKey, model: m.apiModelID)
        }
        do {
            let translated = try await client.translate(
                "Hello, this is a test sentence.",
                images: [],
                to: targetLanguage,
                mode: .selection,
                appCategory: .other,
                composition: nil,
                thinkingLevel: textThinkingLevel,
                onPartial: { _ in }
            )
            let preview = String(translated.prefix(160))
            return .success(preview: "Model: \(model.shortName)\n\n\(preview)")
        } catch let error as TranslationError {
            return .failure(error.errorDescription ?? "Unknown error.")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    @MainActor
    private func applyModelSelection(_ modelID: String, for scope: ModelUseScope) {
        setModelID(modelID, for: scope)
        analyticsClient.track(.modelChanged, properties: [
            "model_id": modelID,
            "model_scope": scope.rawValue,
            "source": "user"
        ])
        translationCache = TranslationCache()
        onModelSelectionChanged(for: scope)
        updateMenuState()
        mainWindowController?.bridge.refreshFromHost()
    }

    /// An engine just connected: point each scope at the engine's preset
    /// model. A slot is only touched when its current model is broken (its
    /// provider has no credentials / the local model isn't installed) or is
    /// still the untouched factory default — a working user choice is never
    /// replaced. The preset itself must be usable right now, so a half-set-up
    /// engine never grabs a slot.
    @MainActor
    private func applyEnginePreset(_ engine: EngineModelPreset) {
        var applied = false
        for scope in ModelUseScope.allCases {
            guard let presetID = engine.modelID(for: scope),
                  presetID != modelID(for: scope),
                  isModelUsableNow(presetID)
            else { continue }
            let untouchedDefault = UserDefaults.standard.string(forKey: scope.defaultsKey) == nil
            guard untouchedDefault || !isModelUsableNow(modelID(for: scope)) else { continue }
            setModelID(presetID, for: scope)
            analyticsClient.track(.modelChanged, properties: [
                "model_id": presetID,
                "model_scope": scope.rawValue,
                "source": "preset"
            ])
            applied = true
        }
        guard applied else { return }
        translationCache = TranslationCache()
        updateMenuState()
        mainWindowController?.bridge.refreshFromHost()
    }

    /// True when the model can serve a request right now: its cloud provider
    /// has credentials, or the local model is installed and the server runs.
    private func isModelUsableNow(_ modelID: String) -> Bool {
        let model = LLMModel.option(id: modelID)
        if let provider = model.cloudProvider {
            return provider.hasCredentials
        }
        return bootstrap.isReady(for: modelID)
    }

    @MainActor
    private func presentAPIKeySheet(for provider: CloudProvider, errorMessage: String? = nil, onSave: @escaping (Bool) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let baseMessage = "Your key is stored locally on this Mac. Nugumi sends your selected text to \(provider.displayName) for translation."
        let fullMessage = errorMessage.map { "⚠️ \($0)\n\n\(baseMessage)" } ?? baseMessage
        let controller = NugumiInputAlertController(
            title: "Enter your \(provider.displayName) API key",
            message: fullMessage,
            placeholder: "sk-...",
            initialValue: KeychainStore.apiKey(for: provider),
            primaryButtonTitle: "Save",
            secondaryButtonTitle: "Get a key…",
            tertiaryButtonTitle: "Cancel"
        )
        let result = controller.showModal()
        switch result.response {
        case .alertFirstButtonReturn:
            guard !result.text.isEmpty else {
                onSave(false)
                return
            }
            Task { @MainActor in
                let outcome = await APIKeyValidator.validate(result.text, for: provider)
                switch outcome {
                case .valid:
                    KeychainStore.setAPIKey(result.text, for: provider)
                    self.bootstrap.refresh()
                    self.applyEnginePreset(.cloud(provider))
                    onSave(true)
                case .invalid(let reason):
                    self.presentAPIKeySheet(for: provider, errorMessage: reason, onSave: onSave)
                case .networkUnreachable(let detail):
                    // Network problem — save anyway so user isn't stuck offline.
                    KeychainStore.setAPIKey(result.text, for: provider)
                    self.bootstrap.refresh()
                    self.applyEnginePreset(.cloud(provider))
                    self.presentSelectionTranslationError("Couldn't reach \(provider.displayName) to verify the key (\(detail)). Saved it locally.", title: "Key saved without verification")
                    onSave(true)
                }
            }
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(provider.apiKeyHelpURL)
            onSave(false)
        default:
            onSave(false)
        }
    }

    @MainActor
    private func presentShortcutRecorder(for action: GlobalShortcutAction) {
        // Suspend every double-tap detector so the recorder owns flagsChanged
        // events while the panel is up; otherwise the very modifier the user
        // is trying to bind would also fire its currently-bound action.
        modifierDetectors.forEach { $0.isEnabled = false }
        shortcutRecorderWindowController?.close()
        let controller = ShortcutRecorderWindowController(
            action: action,
            currentShortcut: shortcut(for: action),
            onShortcut: { [weak self] shortcut in
                let didSet = self?.setKeyboardShortcut(shortcut, for: action) ?? false
                self?.mainWindowController?.bridge.refreshFromHost()
                return didSet
            },
            onClose: { [weak self] in
                self?.modifierDetectors.forEach { $0.isEnabled = true }
                self?.shortcutRecorderWindowController = nil
            }
        )
        shortcutRecorderWindowController = controller
        controller.present()
    }

    @MainActor
    private func setKeyboardShortcut(_ shortcut: GlobalShortcut, for action: GlobalShortcutAction) -> Bool {
        for otherAction in GlobalShortcutAction.allCases where otherAction != action {
            if self.shortcut(for: otherAction) == shortcut {
                return false
            }
        }

        GlobalShortcutStore.set(shortcut, for: action)
        setupGlobalHotKeys()
        updateMenuState()
        return true
    }

    @MainActor
    @objc private func resetKeyboardShortcuts() {
        GlobalShortcutStore.resetToDefaults()
        setupGlobalHotKeys()
        updateMenuState()
    }

    @MainActor
    @objc private func resetSettings() {
        let response = NugumiAlertController(
            title: "Reset settings?",
            message: "This restores languages, main mode, display, output, AI mode, and keyboard shortcuts. Snippets, dictionary, your email voice sample, and usage stats stay unchanged.",
            primaryButtonTitle: "Reset",
            secondaryButtonTitle: "Cancel"
        ).showModal()
        guard response == .alertFirstButtonReturn else {
            return
        }

        resetSettingsToDefaults()
    }

    @MainActor
    private func resetSettingsToDefaults() {
        let previousTextModelID = textModelID
        let previousAskModelID = askNugumiModelID
        let defaults = UserDefaults.standard
        [
            "targetLanguageID",
            "draftTargetLanguageID",
            "floatingButtonDefaultMode",
            "selectionDisplayMode",
            ModelUseScope.textActions.defaultsKey,
            ModelUseScope.askNugumi.defaultsKey,
            ModelUseScope.textActions.thinkingDefaultsKey,
            ModelUseScope.askNugumi.thinkingDefaultsKey,
            "selectedOllamaModel",
            "thinkingLevel",
            "cleanupLevel",
            "genZMode",
            "replacementMode",
            InvisibilityState.defaultsKey,
            InvisibilityState.firstRunShownKey,
            usageStatsExpandedKey
        ].forEach { defaults.removeObject(forKey: $0) }

        for category in AppCategory.allCases {
            defaults.removeObject(forKey: "writingStyle.\(category.rawValue)")
        }

        GlobalShortcutStore.resetToDefaults(defaults: defaults)
        shortcutRecorderWindowController?.close()
        translationCache = TranslationCache()
        translationPanelController?.close()
        translationPanelController = nil
        petController?.setActionMode(floatingDefaultMode.translationMode)
        refreshStatusBarIcon()
        applySelectionDisplayMode()
        setupGlobalHotKeys()
        statusItem?.isVisible = true
        InvisibilityState.applyToAllOpenWindows()

        if textModelID != previousTextModelID {
            onModelSelectionChanged(for: .textActions)
        }
        if askNugumiModelID != previousAskModelID {
            onModelSelectionChanged(for: .askNugumi)
        }

        updateMenuState()
        mainWindowController?.bridge.refreshFromHost()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// Builds the application's main menu. An accessory (LSUIElement) app gets no
    /// menu bar by default, so the standard text-editing key equivalents
    /// (⌘C / ⌘V / ⌘X / ⌘A / ⌘Z) never reach the focused text field — they are
    /// delivered through the Edit menu. The menu surfaces only while Nugumi is the
    /// active app. ⌘Q is deliberately bound to "Close Window" rather than Quit:
    /// Nugumi lives in the menu bar, so closing the window must not kill it — users
    /// quit via the status-bar "Quit Nugumi" item.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // The first submenu is always treated as the application menu; the system
        // substitutes the app name for its title.
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Hide Nugumi",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                        action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        // ⌘Q closes the front window (routed through the responder chain) instead
        // of terminating — the accessory app keeps running in the menu bar.
        appMenu.addItem(withTitle: "Close Window",
                        action: #selector(NSWindow.performClose(_:)), keyEquivalent: "q")

        // Edit menu — actions target nil so they dispatch down the responder chain
        // to the first-responder text view, enabling copy/paste/etc. everywhere.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    @MainActor
    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updaterController?.checkForUpdates(nil)
    }
}

extension NugumiApp: SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        "https://raw.githubusercontent.com/ChoiVadim/nugumi/main/appcast.xml"
    }
}

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

struct SelectedTextContext {
    let text: String
    let selectionRect: NSRect?
}

final class SelectionReader {
    func readSelectedText(
        preferClipboard: Bool = false,
        allowClipboardFallback: Bool,
        completion: @escaping (String?) -> Void
    ) {
        readSelectedTextContext(
            preferClipboard: preferClipboard,
            allowClipboardFallback: allowClipboardFallback
        ) { selection in
            completion(selection?.text)
        }
    }

    func readSelectedTextContext(
        preferClipboard: Bool = false,
        allowClipboardFallback: Bool,
        completion: @escaping (SelectedTextContext?) -> Void
    ) {
        if preferClipboard {
            ClipboardSelectionReader.readSelectedText { [weak self] clipboardText in
                if let clipboardText, !clipboardText.isEmpty {
                    completion(SelectedTextContext(text: clipboardText, selectionRect: nil))
                    return
                }
                completion(self?.readSelectedTextContext())
            }
            return
        }

        if let selection = readSelectedTextContext() {
            completion(selection)
            return
        }

        guard allowClipboardFallback else {
            completion(nil)
            return
        }

        ClipboardSelectionReader.readSelectedText { selectedText in
            guard let selectedText else {
                completion(nil)
                return
            }

            completion(SelectedTextContext(text: selectedText, selectionRect: nil))
        }
    }

    func isLikelyEditableElementAtMouseLocation() -> Bool {
        guard let element = elementAtMouseLocation() ?? focusedElement() else {
            return false
        }

        var currentElement: AXUIElement? = element
        for _ in 0..<6 {
            guard let element = currentElement else {
                return false
            }

            if let role = role(of: element), Self.editableTextRoles.contains(role) {
                return true
            }

            currentElement = parent(of: element)
        }

        return false
    }

    func readSelectedText() -> String? {
        readSelectedTextContext()?.text
    }

    func readSelectedTextContext() -> SelectedTextContext? {
        guard let focusedElement = focusedElement() else {
            return nil
        }

        guard let text = selectedText(from: focusedElement) else {
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let rect = selectedTextRange(from: focusedElement)
            .flatMap { selectionBounds(from: focusedElement, range: $0) }

        return SelectedTextContext(
            text: trimmed,
            selectionRect: rect
        )
    }

    private static let editableTextRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField"
    ]

    private func focusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        guard focusedResult == .success,
              let focusedElement = focusedValue,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return (focusedElement as! AXUIElement)
    }

    private func elementAtMouseLocation() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        let mouseLocation = NSEvent.mouseLocation
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(mouseLocation.x),
            Float(mouseLocation.y),
            &element
        )

        guard result == .success else {
            return nil
        }

        return element
    }

    private func role(of element: AXUIElement) -> String? {
        var roleValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleValue
        )

        guard result == .success else {
            return nil
        }

        return roleValue as? String
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        var parentValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXParentAttribute as CFString,
            &parentValue
        )

        guard result == .success,
              let parentValue,
              CFGetTypeID(parentValue) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return (parentValue as! AXUIElement)
    }

    private func selectedText(from element: AXUIElement) -> String? {
        var selectedTextValue: CFTypeRef?
        let selectedTextResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextValue
        )

        if selectedTextResult == .success, let selectedText = selectedTextValue as? String {
            return selectedText
        }

        return selectedTextViaRange(from: element)
    }

    private func selectedTextViaRange(from element: AXUIElement) -> String? {
        guard let range = selectedTextRange(from: element) else {
            return nil
        }

        var textValue: CFTypeRef?
        let textResult = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &textValue
        )

        guard textResult == .success, let fullText = textValue as? String else {
            return nil
        }

        let utf16 = fullText.utf16
        guard range.location >= 0,
              range.length >= 0,
              range.location + range.length <= utf16.count
        else {
            return nil
        }

        let utf16Start = utf16.index(utf16.startIndex, offsetBy: range.location)
        let utf16End = utf16.index(utf16.startIndex, offsetBy: range.location + range.length)
        guard let start = utf16Start.samePosition(in: fullText),
              let end = utf16End.samePosition(in: fullText)
        else {
            return nil
        }

        return String(fullText[start..<end])
    }

    private func selectedTextRange(from element: AXUIElement) -> CFRange? {
        var rangeValue: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        )

        guard rangeResult == .success,
              let rangeValue,
              CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let axRangeValue = rangeValue as! AXValue
        var range = CFRange()
        guard AXValueGetType(axRangeValue) == .cfRange,
              AXValueGetValue(axRangeValue, .cfRange, &range),
              range.location >= 0,
              range.length > 0
        else {
            return nil
        }

        return range
    }

    private func selectionBounds(from element: AXUIElement, range: CFRange) -> NSRect? {
        var mutableRange = range
        guard let rangeAXValue = AXValueCreate(.cfRange, &mutableRange) else {
            return nil
        }

        var boundsValue: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeAXValue,
            &boundsValue
        )

        guard result == .success,
              let boundsValue,
              CFGetTypeID(boundsValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let axValue = boundsValue as! AXValue
        var rect = CGRect.zero
        guard AXValueGetType(axValue) == .cgRect,
              AXValueGetValue(axValue, .cgRect, &rect),
              rect.width > 0, rect.height > 0,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite
        else {
            return nil
        }

        return SelectionReader.convertAXRectToCocoa(rect)
    }

    // AX uses top-left global coordinates; NSScreen uses bottom-left.
    // Build an AX-space frame for each display so selection panels stay near
    // the selected text on horizontal and vertical multi-monitor layouts.
    private static func convertAXRectToCocoa(_ axRect: CGRect) -> NSRect? {
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
                ?? NSScreen.screens.first
        else {
            return nil
        }

        let axMidPoint = CGPoint(x: axRect.midX, y: axRect.midY)
        let containingScreen = NSScreen.screens.first { screen in
            axFrame(for: screen, primaryScreen: primary).contains(axMidPoint)
        } ?? primary
        let containingAXFrame = axFrame(for: containingScreen, primaryScreen: primary)
        let flippedY = containingScreen.frame.maxY - (axRect.maxY - containingAXFrame.minY)
        return NSRect(x: axRect.origin.x, y: flippedY, width: axRect.width, height: axRect.height)
    }

    private static func axFrame(for screen: NSScreen, primaryScreen: NSScreen) -> CGRect {
        CGRect(
            x: screen.frame.minX,
            y: primaryScreen.frame.maxY - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
    }

}

enum ClipboardSelectionReader {
    private static let pollingInterval: TimeInterval = 0.02
    private static let pollingTimeout: TimeInterval = 0.5
    private static let lateRestoreGrace: TimeInterval = 0.5

    static func readSelectedText(completion: @escaping (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let originalChangeCount = pasteboard.changeCount

        postCommandC()

        let deadline = Date().addingTimeInterval(pollingTimeout)
        pollForPasteboardChange(
            pasteboard: pasteboard,
            originalChangeCount: originalChangeCount,
            deadline: deadline,
            snapshot: snapshot,
            completion: completion
        )
    }

    private static func pollForPasteboardChange(
        pasteboard: NSPasteboard,
        originalChangeCount: Int,
        deadline: Date,
        snapshot: PasteboardSnapshot,
        completion: @escaping (String?) -> Void
    ) {
        if pasteboard.changeCount != originalChangeCount {
            let copiedText = pasteboard.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            snapshot.restore(to: pasteboard)
            let meaningful = copiedText.flatMap { TextNormalizer.looksMeaningful($0) ? $0 : nil }
            completion(meaningful)
            return
        }

        if Date() >= deadline {
            monitorLatePasteboardChange(
                pasteboard: pasteboard,
                originalChangeCount: originalChangeCount,
                deadline: Date().addingTimeInterval(lateRestoreGrace),
                snapshot: snapshot
            )
            completion(nil)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pollingInterval) {
            pollForPasteboardChange(
                pasteboard: pasteboard,
                originalChangeCount: originalChangeCount,
                deadline: deadline,
                snapshot: snapshot,
                completion: completion
            )
        }
    }

    private static func postCommandC() {
        KeyboardShortcutPoster.postCommandShortcut(keyCode: CGKeyCode(kVK_ANSI_C))
    }

    private static func monitorLatePasteboardChange(
        pasteboard: NSPasteboard,
        originalChangeCount: Int,
        deadline: Date,
        snapshot: PasteboardSnapshot
    ) {
        if pasteboard.changeCount != originalChangeCount {
            snapshot.restore(to: pasteboard)
            return
        }

        guard Date() < deadline else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pollingInterval) {
            monitorLatePasteboardChange(
                pasteboard: pasteboard,
                originalChangeCount: originalChangeCount,
                deadline: deadline,
                snapshot: snapshot
            )
        }
    }
}

enum KeyboardShortcutPoster {
    static func postCommandShortcut(keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        postKey(CGKeyCode(kVK_Command), keyDown: true, flags: .maskCommand, source: source)
        postKey(keyCode, keyDown: true, flags: .maskCommand, source: source)
        postKey(keyCode, keyDown: false, flags: .maskCommand, source: source)
        postKey(CGKeyCode(kVK_Command), keyDown: false, flags: [], source: source)
    }

    private static func postKey(
        _ keyCode: CGKeyCode,
        keyDown: Bool,
        flags: CGEventFlags,
        source: CGEventSource?
    ) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
}

private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let capturedItems = (pasteboard.pasteboardItems ?? []).map { item in
            var capturedTypes: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    capturedTypes[type] = data
                }
            }
            return capturedTypes
        }

        return PasteboardSnapshot(items: capturedItems)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { capturedTypes in
            let item = NSPasteboardItem()
            for (type, data) in capturedTypes {
                item.setData(data, forType: type)
            }
            return item
        }

        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }
}

enum PasteboardTextInserter {
    static func replaceCurrentSelection(with text: String) {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let replacementChangeCount = pasteboard.changeCount

        postCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            guard pasteboard.changeCount == replacementChangeCount else {
                return
            }
            snapshot.restore(to: pasteboard)
        }
    }

    private static func postCommandV() {
        KeyboardShortcutPoster.postCommandShortcut(keyCode: CGKeyCode(kVK_ANSI_V))
    }
}

enum ScreenshotTranslationError: LocalizedError {
    case captureCancelled
    case captureFailed(Int32)
    case captureFailedDetail(String)
    case noTextRecognized
    case screenRecordingPermissionDenied

    var errorDescription: String? {
        switch self {
        case .captureCancelled:
            "Screenshot selection was cancelled."
        case .captureFailed(let status):
            "Screenshot capture failed with exit code \(status)."
        case .captureFailedDetail(let message):
            "Screenshot capture failed: \(message)"
        case .noTextRecognized:
            "No readable text was found in the selected area."
        case .screenRecordingPermissionDenied:
            "Nugumi needs Screen Recording permission to capture screenshots. Open settings to enable it, then choose Quit Nugumi and reopen Nugumi for the change to take effect."
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        guard let screenshotError = error as? ScreenshotTranslationError else {
            return false
        }

        if case .captureCancelled = screenshotError {
            return true
        }
        return false
    }
}

struct AskNugumiScreenCapture {
    let image: ImageInput
    let imagePixelSize: CGSize
    // AppKit global coordinates in points.
    let screenFrame: CGRect
    let visibleFrame: CGRect
}

enum ScreenshotCapture {
    @MainActor
    static func captureActiveScreen(containing point: NSPoint = NSEvent.mouseLocation) async throws -> AskNugumiScreenCapture {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenshotTranslationError.screenRecordingPermissionDenied
        }

        let screen = NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let screen else {
            throw ScreenshotTranslationError.captureFailedDetail("No screen is available.")
        }

        guard let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw ScreenshotTranslationError.captureFailedDetail("Could not capture the active screen.")
        }
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame

        let imagePayload = try await Task.detached(priority: .userInitiated) {
            guard let captured = CGDisplayCreateImage(screenID) else {
                throw ScreenshotTranslationError.captureFailedDetail("Could not capture the active screen.")
            }

            // Retina/5K screenshots as lossless PNG routinely exceed the
            // 5 MB cloud-backend limit. Cloud vision models (OpenAI 4o/4.1,
            // etc.) fit images to 2048² before tiling, so downscaling here
            // is lossless w.r.t. the model and JPEG keeps payload small.
            let cgImage = ScreenshotCapture.downscaledForVision(captured)
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let jpegProps: [NSBitmapImageRep.PropertyKey: Any] = [.compressionFactor: 0.85]
            let encoded: (data: Data, mediaType: String)
            if let jpeg = bitmap.representation(using: .jpeg, properties: jpegProps) {
                encoded = (jpeg, "image/jpeg")
            } else if let png = bitmap.representation(using: .png, properties: [:]) {
                encoded = (png, "image/png")
            } else {
                throw ScreenshotTranslationError.captureFailedDetail("Could not encode the active screen.")
            }

            return (
                image: ImageInput(data: encoded.data, mediaType: encoded.mediaType),
                pixelSize: CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
            )
        }.value

        return AskNugumiScreenCapture(
            image: imagePayload.image,
            imagePixelSize: imagePayload.pixelSize,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )
    }

    // Matches the tile boundary cloud vision models snap to; sending larger
    // is bandwidth waste plus risks tripping client-side size guards.
    private static let visionMaxEdge: CGFloat = 2048

    fileprivate static func downscaledForVision(_ image: CGImage) -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let longest = max(width, height)
        guard longest > visionMaxEdge else { return image }
        let scale = visionMaxEdge / longest
        let targetWidth = Int((width * scale).rounded())
        let targetHeight = Int((height * scale).rounded())
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? image
    }

    static func captureInteractiveArea() async throws -> URL {
        // Permission is requested once at launch (requestScreenRecordingPermissionIfNeeded),
        // which is what registers Nugumi in System Settings. Calling CGRequestScreenCaptureAccess
        // here would stack Apple's system prompt on top of our NugumiAlertController.
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenshotTranslationError.screenRecordingPermissionDenied
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let outputURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("nugumi-screenshot-\(UUID().uuidString)")
                    .appendingPathExtension("png")

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-i", "-x", outputURL.path]
                let stderrPipe = Pipe()
                process.standardError = stderrPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let stderrText = String(data: stderrData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let fileExists = FileManager.default.fileExists(atPath: outputURL.path)

                    if !fileExists {
                        // If `screencapture` produced no file and the system
                        // says the app isn't trusted for screen capture, the
                        // failure is almost certainly a permission denial —
                        // independent of how Apple phrased the stderr message.
                        let permissionDenied = !CGPreflightScreenCaptureAccess()
                            || stderrText.localizedCaseInsensitiveContains("could not create image")
                        if stderrText.isEmpty && !permissionDenied {
                            continuation.resume(throwing: ScreenshotTranslationError.captureCancelled)
                        } else if permissionDenied {
                            continuation.resume(throwing: ScreenshotTranslationError.screenRecordingPermissionDenied)
                        } else {
                            continuation.resume(throwing: ScreenshotTranslationError.captureFailedDetail(stderrText))
                        }
                        return
                    }

                    if process.terminationStatus != 0 {
                        continuation.resume(throwing: ScreenshotTranslationError.captureFailed(process.terminationStatus))
                        return
                    }

                    guard let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
                          let fileSize = attributes[.size] as? NSNumber,
                          fileSize.intValue > 0
                    else {
                        continuation.resume(throwing: ScreenshotTranslationError.captureCancelled)
                        return
                    }

                    continuation.resume(returning: outputURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

}

enum ImageTextRecognizer {
    private struct RecognizedLine {
        let text: String
        let boundingBox: CGRect
    }

    static func recognizeText(in imageURL: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    request.automaticallyDetectsLanguage = true

                    let supportedLanguages = (try? request.supportedRecognitionLanguages()) ?? []
                    if !supportedLanguages.isEmpty {
                        request.recognitionLanguages = supportedLanguages
                    }

                    let handler = VNImageRequestHandler(url: imageURL, options: [:])
                    try handler.perform([request])

                    let lines = (request.results ?? []).compactMap { observation -> RecognizedLine? in
                        guard let candidate = observation.topCandidates(1).first else {
                            return nil
                        }

                        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else {
                            return nil
                        }

                        return RecognizedLine(text: text, boundingBox: observation.boundingBox)
                    }

                    let rowTolerance: CGFloat = 0.025
                    let orderedLines = lines.sorted { lhs, rhs in
                        let lhsMidY = lhs.boundingBox.midY
                        let rhsMidY = rhs.boundingBox.midY

                        if abs(lhsMidY - rhsMidY) <= rowTolerance {
                            return lhs.boundingBox.minX < rhs.boundingBox.minX
                        }

                        return lhsMidY > rhsMidY
                    }

                    let recognizedText = Self.joinedTextPreservingParagraphs(
                        from: orderedLines,
                        rowTolerance: rowTolerance
                    )
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                    guard !recognizedText.isEmpty else {
                        continuation.resume(throwing: ScreenshotTranslationError.noTextRecognized)
                        return
                    }

                    continuation.resume(returning: recognizedText)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Joins OCR lines using their geometry. Same-row lines join with a space.
    /// Stacked lines use `\n` for ordinary line wraps and `\n\n` when the
    /// vertical gap between them is meaningfully larger than the median line
    /// height — that gap corresponds to a deliberate paragraph break in the
    /// source. Without this signal the downstream LLM cannot distinguish a
    /// word-wrap from a paragraph boundary and collapses everything into one
    /// block.
    private static func joinedTextPreservingParagraphs(
        from lines: [RecognizedLine],
        rowTolerance: CGFloat
    ) -> String {
        guard let first = lines.first else { return "" }
        guard lines.count > 1 else { return first.text }

        let heights = lines.map(\.boundingBox.height).sorted()
        let medianHeight = heights[heights.count / 2]
        let paragraphGapThreshold = max(medianHeight * 0.65, 0.005)

        var result = first.text
        for index in 1..<lines.count {
            let previous = lines[index - 1]
            let current = lines[index]
            let sameRow = abs(previous.boundingBox.midY - current.boundingBox.midY) <= rowTolerance
            if sameRow {
                result += " " + current.text
                continue
            }

            let gap = previous.boundingBox.minY - current.boundingBox.maxY
            let separator = gap > paragraphGapThreshold ? "\n\n" : "\n"
            result += separator + current.text
        }
        return result
    }
}

final class ScreenshotDragTracker {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var startLocation: NSPoint?
    private var lastLocation: NSPoint?
    private var currentPanelSide: TranslationPanelController.Side?
    private let onUpdate: @MainActor (NSPoint?, NSPoint?, TranslationPanelController.Side?) -> Void

    init(onUpdate: @escaping @MainActor (NSPoint?, NSPoint?, TranslationPanelController.Side?) -> Void) {
        self.onUpdate = onUpdate
    }

    func enable() {
        guard eventTap == nil else { return }

        let mask =
            CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }

                let tracker = Unmanaged<ScreenshotDragTracker>.fromOpaque(userInfo).takeUnretainedValue()
                tracker.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPointer
        ) else {
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        runLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func disable() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        startLocation = nil
        lastLocation = nil
        currentPanelSide = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let location = event.location
        switch type {
        case .leftMouseDown:
            startLocation = location
            lastLocation = location
            currentPanelSide = nil
            notify(startLocation: location, endLocation: nil, panelSide: nil)
        case .leftMouseDragged, .leftMouseUp:
            let referenceLocation = startLocation ?? lastLocation
            if let panelSide = Self.meaningfulPanelSideForDrag(from: referenceLocation, to: location) {
                currentPanelSide = panelSide
            }
            notify(startLocation: startLocation, endLocation: location, panelSide: currentPanelSide)
            lastLocation = location
            if type == .leftMouseUp {
                startLocation = nil
                lastLocation = nil
            }
        default:
            break
        }
    }

    private func notify(
        startLocation: NSPoint?,
        endLocation: NSPoint?,
        panelSide: TranslationPanelController.Side?
    ) {
        Task { @MainActor in
            onUpdate(startLocation, endLocation, panelSide)
        }
    }

    private static func meaningfulPanelSideForDrag(
        from startLocation: NSPoint?,
        to endLocation: NSPoint
    ) -> TranslationPanelController.Side? {
        guard let startLocation else { return nil }

        let dx = endLocation.x - startLocation.x
        let dy = endLocation.y - startLocation.y
        guard abs(dx) >= 5, abs(dx) > abs(dy) else { return nil }
        return dx > 0 ? .right : .left
    }

    deinit {
        disable()
    }
}

final class TabKeyInterceptor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let onTab: @MainActor () -> Void

    init(onTab: @escaping @MainActor () -> Void) {
        self.onTab = onTab
    }

    func enable() {
        guard eventTap == nil else { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo, type == .keyDown else {
                    return Unmanaged.passUnretained(event)
                }

                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                guard keyCode == Int64(kVK_Tab) else {
                    return Unmanaged.passUnretained(event)
                }

                let modifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
                guard event.flags.intersection(modifierMask).isEmpty else {
                    return Unmanaged.passUnretained(event)
                }

                let interceptor = Unmanaged<TabKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
                Task { @MainActor in
                    interceptor.onTab()
                }
                return nil
            },
            userInfo: selfPointer
        ) else {
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        runLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func disable() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    deinit {
        disable()
    }
}

final class CommandCopyInterceptor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let consumesEvent: Bool
    private let onCopy: @MainActor () -> Void

    init(consumesEvent: Bool = true, onCopy: @escaping @MainActor () -> Void) {
        self.consumesEvent = consumesEvent
        self.onCopy = onCopy
    }

    func enable() {
        guard eventTap == nil else { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: consumesEvent ? .defaultTap : .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo, type == .keyDown else {
                    return Unmanaged.passUnretained(event)
                }

                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                guard keyCode == Int64(kVK_ANSI_C) else {
                    return Unmanaged.passUnretained(event)
                }

                let modifiers = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
                guard modifiers == .maskCommand else {
                    return Unmanaged.passUnretained(event)
                }

                let interceptor = Unmanaged<CommandCopyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
                Task { @MainActor in
                    interceptor.onCopy()
                }
                return interceptor.consumesEvent ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: selfPointer
        ) else {
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        runLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func disable() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    deinit {
        disable()
    }
}

final class ReturnKeyInterceptor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let sourcePID: pid_t
    private let onReturn: @MainActor () -> Void

    init(sourcePID: pid_t, onReturn: @escaping @MainActor () -> Void) {
        self.sourcePID = sourcePID
        self.onReturn = onReturn
    }

    func enable() {
        guard eventTap == nil else { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo, type == .keyDown else {
                    return Unmanaged.passUnretained(event)
                }

                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                guard keyCode == Int64(kVK_Return) || keyCode == Int64(kVK_ANSI_KeypadEnter) else {
                    return Unmanaged.passUnretained(event)
                }

                let modifiers = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
                guard modifiers == [] else {
                    return Unmanaged.passUnretained(event)
                }

                let interceptor = Unmanaged<ReturnKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()

                // Only steal Return when the user is still in the source app
                // where the selection lives. Otherwise let it through so it
                // doesn't hijack typing in other apps.
                let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
                guard frontmost == interceptor.sourcePID else {
                    return Unmanaged.passUnretained(event)
                }

                Task { @MainActor in
                    interceptor.onReturn()
                }
                return nil
            },
            userInfo: selfPointer
        ) else {
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        runLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func disable() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    deinit {
        disable()
    }
}

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
    var drawsBubble = true {
        didSet { needsDisplay = true }
    }
    var isError = false {
        didSet { needsDisplay = true }
    }
    var bubbleFrame: NSRect = .zero {
        didSet { needsDisplay = true }
    }
    var targetMarkerPoint: NSPoint? {
        didSet { needsDisplay = true }
    }
    /// Direction (radians) the pixel arrow points — pet → destination.
    var targetMarkerAngle: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    private var targetMarkerFrame = 0

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
        // is wired in. Lets targetMarkerView keep its non-interactive behavior.
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

    func advanceTargetMarkerBlink() {
        guard targetMarkerPoint != nil else { return }
        targetMarkerFrame = (targetMarkerFrame + 1) % 60
        needsDisplay = true
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

        if drawsBubble {
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

        if let targetMarkerPoint {
            drawTargetMarker(center: targetMarkerPoint, unit: unit)
        }
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

    // Arrow sprite, pointing +x (right): rectangular stem on the left, a
    // triangular head tapering to a point on the right. Equal-width rows so
    // it aligns; '#' = fill. Border is synthesized as a 1-cell outline so the
    // pixel edge matches the dialog bubble's dark-bordered look.
    private static let arrowSpriteRows = [
        "....#...",
        "....##..",
        "#######.",
        "########",
        "#######.",
        "....##..",
        "....#...",
    ]
    private static let arrowCoreCell = (col: 1, row: 3) // lighter accent pixel

    private func drawTargetMarker(center: NSPoint, unit: CGFloat) {
        let isBrightFrame = targetMarkerFrame < 34
        // Brighter than the old dot, same footprint.
        let border = NSColor(
            srgbRed: 0.05, green: 0.24, blue: 0.22,
            alpha: isBrightFrame ? 0.98 : 0.82
        )
        let fill = NSColor(
            srgbRed: 17.0 / 255.0,
            green: 118.0 / 255.0,
            blue: 110.0 / 255.0,
            alpha: isBrightFrame ? 1.0 : 0.72
        )
        let core = NSColor(
            srgbRed: 0.90, green: 0.98, blue: 0.96,
            alpha: isBrightFrame ? 0.95 : 0.55
        )
        let shadow = NSColor(calibratedWhite: 0.0, alpha: isBrightFrame ? 0.20 : 0.09)

        // Dedicated unit so the arrow keeps the old dot's ~15px footprint
        // (it must not look bigger) while leaving rotation room in the panel.
        _ = unit
        let arrowUnit: CGFloat = 1.8

        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        transform.rotate(byRadians: targetMarkerAngle)
        transform.concat()
        // Local space: sprite centered on (0,0), now rotated toward target.
        drawArrowSprite(unit: arrowUnit, offset: NSPoint(x: arrowUnit, y: -arrowUnit),
                        border: shadow, fill: shadow, core: shadow)
        drawArrowSprite(unit: arrowUnit, offset: .zero,
                        border: border, fill: fill, core: core)
        context.restoreGraphicsState()
    }

    private func drawArrowSprite(
        unit: CGFloat,
        offset: NSPoint,
        border: NSColor,
        fill: NSColor,
        core: NSColor
    ) {
        let rows = Self.arrowSpriteRows
        let rowCount = rows.count
        let colCount = rows.map(\.count).max() ?? 0
        // Center the grid on the origin (sprite center).
        let centerCol = CGFloat(colCount - 1) / 2
        let centerRow = CGFloat(rowCount - 1) / 2

        func cell(_ col: Int, _ row: Int) -> NSRect {
            // Flip row so the grid reads top-to-bottom but draws y-up.
            NSRect(
                x: offset.x + (CGFloat(col) - centerCol) * unit,
                y: offset.y + (centerRow - CGFloat(row)) * unit,
                width: unit,
                height: unit
            )
        }

        var filled = Set<[Int]>()
        for (r, line) in rows.enumerated() {
            for (c, ch) in line.enumerated() where ch == "#" {
                filled.insert([c, r])
            }
        }

        // 1-cell dark outline around the whole shape.
        border.setFill()
        let neighbors = [-1, 0, 1]
        for key in filled {
            for dx in neighbors {
                for dy in neighbors where !(dx == 0 && dy == 0) {
                    let n = [key[0] + dx, key[1] + dy]
                    if !filled.contains(n) {
                        NSBezierPath(rect: cell(n[0], n[1])).fill()
                    }
                }
            }
        }

        // Fill, then the single lighter accent pixel.
        fill.setFill()
        for key in filled {
            NSBezierPath(rect: cell(key[0], key[1])).fill()
        }
        core.setFill()
        NSBezierPath(rect: cell(Self.arrowCoreCell.col, Self.arrowCoreCell.row)).fill()
    }
}

@MainActor
final class PetController: NSObject, NSTextFieldDelegate {
    private let panel: NSPanel
    private let containerView: NSView
    private let promptPanel: NSPanel
    private let promptContainerView: NSView
    private let targetMarkerPanel: NSPanel
    private let petView: PetMascotView
    private let appIconView: NSImageView
    private let promptBubbleView: PetPromptBubbleView
    private let targetMarkerView: PetPromptBubbleView
    private let promptTextField: AskPromptTextField
    private let answerScrollView: NSScrollView
    private let answerTextView: NSTextView
    private let continueButton = NSButton()
    private var workspaceObserver: NSObjectProtocol?
    private var trackingTimer: Timer?
    private var throwTimer: Timer?
    private var throwVelocity: NSPoint = .zero
    private var tabInterceptor: TabKeyInterceptor?
    private var selectedText: String?
    private var onTranslate: ((String) -> Void)?
    private var onRewrite: ((String) -> Void)?
    private var onSmartReply: ((String) -> Void)?
    private var onPromptSubmit: ((String) -> Void)?
    private var onPromptClose: (() -> Void)?
    var onContinue: (() -> Void)?
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
    private var currentAnswerMarkerTarget: NSPoint?
    private var pointingTarget: NSPoint?
    private var pendingPointArrival: (() -> Void)?
    private var pointingArrivalFallbackTimer: Timer?
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
    private static let pointingArrivalFallbackDelay: TimeInterval = 1.6
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

    /// Screen-space center of the pet panel. The floating target pointer
    /// launches from here so it visibly travels from the character.
    var petAnchorPoint: NSPoint {
        NSPoint(x: panel.frame.midX, y: panel.frame.midY)
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
        let initialMarkerPanelSize = AskNugumiTargetMarkerMetrics.paddedFrame(centeredAt: .zero).size
        targetMarkerPanel = PetPanel(
            contentRect: NSRect(origin: origin, size: initialMarkerPanelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
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
        targetMarkerView = PetPromptBubbleView(frame: NSRect(origin: .zero, size: initialMarkerPanelSize))
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

        targetMarkerPanel.level = .floating
        targetMarkerPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        InvisibilityState.apply(to: targetMarkerPanel)
        targetMarkerPanel.isReleasedWhenClosed = false
        targetMarkerPanel.isOpaque = false
        targetMarkerPanel.backgroundColor = .clear
        targetMarkerPanel.hasShadow = false
        targetMarkerPanel.hidesOnDeactivate = false
        targetMarkerPanel.ignoresMouseEvents = true

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

        targetMarkerView.drawsBubble = false
        targetMarkerView.autoresizingMask = [.width, .height]
        targetMarkerView.targetMarkerPoint = NSPoint(
            x: targetMarkerView.bounds.midX,
            y: targetMarkerView.bounds.midY
        )
        targetMarkerPanel.contentView = targetMarkerView

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
            self.invokeCurrentMode()
        }
        petView.onRightClick = { [weak self] in
            self?.invokeRewriteMode()
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
        targetMarkerPanel.close()
    }

    func showPrompt(
        onSubmit: @escaping (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        cancelPointingAnimation()
        selectedText = nil
        self.onTranslate = nil
        self.onRewrite = nil
        self.onSmartReply = nil
        onPromptSubmit = onSubmit
        onPromptClose = onClose
        currentMode = .draftMessage
        isReadyLockedUntilPanelCloses = false
        isThinking = false
        isPromptOpen = true
        isPromptLoading = false
        isAnswerOpen = false
        currentAnswerMarkerTarget = nil
        hideTargetMarker()
        panel.ignoresMouseEvents = false
        petView.allowsClickWhenNotReady = true
        tabInterceptor?.disable()
        tabInterceptor = nil
        appIconView.isHidden = true
        petView.apply(state: .idle, mode: currentMode)

        promptBuffer = ""
        promptTextField.isEnabled = true
        configurePromptTextFieldForInput()
        renderPromptText()
        promptBubbleView.isError = false
        promptBubbleView.targetMarkerPoint = nil
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
        currentAnswerMarkerTarget = nil
        hideTargetMarker()
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
        currentAnswerMarkerTarget = nil
        hideTargetMarker()
        isThinking = false
        panel.ignoresMouseEvents = false
        petView.allowsClickWhenNotReady = true
        promptTextField.isEnabled = true
        configurePromptTextFieldForInput()
        promptBubbleView.isError = true
        promptBubbleView.targetMarkerPoint = nil
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

    func showAnswer(_ message: String, emotion: AskNugumiEmotion?, markerTarget: NSPoint? = nil) {
        let cleanMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanMessage.isEmpty else { return }

        cancelPointingAnimation()
        selectedText = nil
        onTranslate = nil
        onRewrite = nil
        onSmartReply = nil
        onPromptSubmit = nil
        onPromptClose = nil
        isReadyLockedUntilPanelCloses = false
        isThinking = false
        isPromptOpen = false
        isPromptLoading = false
        isAnswerOpen = true
        currentAnswerMarkerTarget = nil
        promptBuffer = ""

        panel.ignoresMouseEvents = false
        petView.allowsClickWhenNotReady = true
        tabInterceptor?.disable()
        tabInterceptor = nil
        appIconView.isHidden = true
        promptBubbleView.isError = false
        configureAnswerTextView(with: cleanMessage)

        let presentation = answerPresentationFrame(
            for: currentAnswerLayout,
            markerTarget: markerTarget
        )
        currentAnswerLayout = presentation.layout
        panel.setFrameOrigin(presentation.petOrigin)
        promptPanel.setFrame(presentation.frame, display: true)
        currentAnswerMarkerTarget = presentation.markerTarget
        showPromptViews()
        promptPanel.alphaValue = 1
        show()
        promptPanel.orderFrontRegardless()
        let petCenter = NSPoint(
            x: presentation.petOrigin.x + Self.panelSize.width / 2,
            y: presentation.petOrigin.y + Self.panelSize.height / 2
        )
        showTargetMarker(
            frame: presentation.markerFrame,
            target: presentation.markerTarget,
            fromPetCenter: petCenter
        )
        panel.orderFrontRegardless()
        petView.apply(state: .talking, mode: currentMode, emotion: .neutral)
        petView.onDoubleClick = { [weak self] in
            self?.closePromptFromUser()
        }
        petView.onDragRequested = { [weak self] startLocation in
            self?.beginBubbleDrag(initialMouseLocation: startLocation)
        }
    }

    func moveToAnswerTarget(
        _ destination: NSPoint,
        markerTarget: NSPoint,
        message: String,
        emotion: AskNugumiEmotion?
    ) {
        let targetOrigin = Self.originNearPoint(destination, size: Self.panelSize)
        let distance = hypot(targetOrigin.x - panel.frame.origin.x, targetOrigin.y - panel.frame.origin.y)
        guard distance > Self.pointingArrivalThreshold else {
            showAnswer(message, emotion: emotion, markerTarget: markerTarget)
            return
        }

        cancelPointingAnimation()
        selectedText = nil
        onTranslate = nil
        onRewrite = nil
        onSmartReply = nil
        isReadyLockedUntilPanelCloses = false
        isThinking = false
        isPromptOpen = false
        isPromptLoading = false
        isAnswerOpen = false
        currentAnswerMarkerTarget = nil
        hideTargetMarker()
        panel.ignoresMouseEvents = true
        tabInterceptor?.disable()
        tabInterceptor = nil
        appIconView.isHidden = true
        promptPanel.orderOut(nil)
        pointingTarget = destination
        pendingPointArrival = { [weak self] in
            self?.showAnswer(message, emotion: emotion, markerTarget: markerTarget)
        }
        schedulePointingArrivalFallback()
        petView.apply(state: .run, mode: currentMode)
        show()
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
        clearPrompt(animate: true)
        onClose?()
    }

    private func clearPrompt(animate: Bool) {
        guard isPromptVisible || onPromptSubmit != nil || onPromptClose != nil else { return }
        stopThrow()
        isPromptOpen = false
        isPromptLoading = false
        isAnswerOpen = false
        currentAnswerMarkerTarget = nil
        hideTargetMarker()
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
        hideTargetMarker()
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

    private func answerPresentationFrame(
        for layout: AskNugumiAnswerBubbleLayout,
        markerTarget: NSPoint?
    ) -> (
        frame: NSRect,
        petOrigin: NSPoint,
        layout: AskNugumiAnswerBubbleLayout,
        markerFrame: NSRect?,
        markerTarget: NSPoint?
    ) {
        let promptPresentation = promptPresentationAnchoredToPet(
            size: layout.panelSize,
            bubbleFrame: layout.bubbleFrame
        )
        let markerPresentation = AskNugumiPetAnswerTargetPanelMetrics.presentation(
            bubblePanelFrame: promptPresentation.promptFrame,
            markerTarget: markerTarget
        )

        return (
            markerPresentation.bubblePanelFrame,
            promptPresentation.petOrigin,
            layout,
            markerPresentation.markerPanelFrame,
            markerPresentation.localMarkerTarget
        )
    }

    private func showTargetMarker(frame: NSRect?, target: NSPoint?, fromPetCenter petCenter: NSPoint) {
        guard let frame, let target else {
            hideTargetMarker()
            return
        }

        let destCenter = NSPoint(x: frame.midX, y: frame.midY)
        targetMarkerView.frame = NSRect(origin: .zero, size: frame.size)
        targetMarkerView.targetMarkerPoint = target
        targetMarkerView.targetMarkerAngle = atan2(
            destCenter.y - petCenter.y,
            destCenter.x - petCenter.x
        )

        // Launch centered on the pet, then glide to the destination so the
        // arrow visibly travels from the character to the target.
        let startFrame = NSRect(
            x: petCenter.x - frame.width / 2,
            y: petCenter.y - frame.height / 2,
            width: frame.width,
            height: frame.height
        )
        targetMarkerPanel.setFrame(startFrame, display: true)
        targetMarkerPanel.alphaValue = 1
        targetMarkerPanel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.46
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            targetMarkerPanel.animator().setFrame(frame, display: true)
        }
    }

    private func hideTargetMarker() {
        targetMarkerPanel.orderOut(nil)
        targetMarkerPanel.alphaValue = 1
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
            promptBubbleView.targetMarkerPoint = nil
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
            promptBubbleView.targetMarkerPoint = nil
            promptTextField.frame = currentPromptInputLayout.textFrame
        }
    }

    func showReady(
        selectedText: String,
        initialMode: TranslationMode,
        onTranslate: @escaping (String) -> Void,
        onRewrite: @escaping (String) -> Void,
        onSmartReply: @escaping (String) -> Void
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
        clearPrompt(animate: true)
        cancelPointingAnimation()
        self.selectedText = selectedText
        self.onTranslate = onTranslate
        self.onRewrite = onRewrite
        self.onSmartReply = onSmartReply
        currentMode = initialMode
        isReadyLockedUntilPanelCloses = false
        panel.ignoresMouseEvents = false
        petView.apply(state: .ready, mode: currentMode)
        appIconView.isHidden = true
        enableTabInterceptor()
        show()
    }

    func holdReadyUntilPanelCloses(mode: TranslationMode? = nil) {
        cancelPointingAnimation()
        if let mode {
            currentMode = mode
        }
        selectedText = nil
        onTranslate = nil
        onRewrite = nil
        onSmartReply = nil
        isReadyLockedUntilPanelCloses = true
        panel.ignoresMouseEvents = true
        tabInterceptor?.disable()
        tabInterceptor = nil
        petView.apply(state: .ready, mode: currentMode)
        appIconView.isHidden = true
    }

    func clearReady() {
        guard !PetSelectionStatusPolicy.shouldPreserveCurrentStatus(
            isThinking: isThinking,
            isPromptVisible: isPromptVisible
        ) else { return }
        cancelPointingAnimation()
        selectedText = nil
        onTranslate = nil
        onRewrite = nil
        onSmartReply = nil
        isReadyLockedUntilPanelCloses = false
        panel.ignoresMouseEvents = true
        tabInterceptor?.disable()
        tabInterceptor = nil
        petView.apply(state: .idle, mode: currentMode)
        refreshStyleBadge()
    }

    func showThinking() {
        if isPromptOpen {
            clearPrompt(animate: false)
        }
        cancelPointingAnimation()
        isThinking = true
        selectedText = nil
        onTranslate = nil
        onRewrite = nil
        onSmartReply = nil
        isReadyLockedUntilPanelCloses = false
        panel.ignoresMouseEvents = !isPromptLoading
        petView.allowsClickWhenNotReady = isPromptLoading
        tabInterceptor?.disable()
        tabInterceptor = nil
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

    func pointTemporarily(at destination: NSPoint, holdDuration: TimeInterval = 3.0) {
        pointingReturnTimer?.invalidate()
        pendingPointArrival = nil
        pointingTarget = destination
        selectedText = nil
        onTranslate = nil
        onRewrite = nil
        onSmartReply = nil
        isReadyLockedUntilPanelCloses = false
        isThinking = false
        panel.ignoresMouseEvents = true
        tabInterceptor?.disable()
        tabInterceptor = nil
        appIconView.isHidden = true
        petView.apply(state: .run, mode: currentMode)
        show()

        let timer = Timer(timeInterval: holdDuration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pointingTarget = nil
                self?.pointingReturnTimer = nil
                self?.refreshStyleBadge()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointingReturnTimer = timer
    }

    private func cancelPointingAnimation() {
        pointingReturnTimer?.invalidate()
        pointingReturnTimer = nil
        pointingArrivalFallbackTimer?.invalidate()
        pointingArrivalFallbackTimer = nil
        pointingTarget = nil
        pendingPointArrival = nil
    }

    private func schedulePointingArrivalFallback() {
        pointingArrivalFallbackTimer?.invalidate()
        let timer = Timer(timeInterval: Self.pointingArrivalFallbackDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.completePendingPointArrival()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointingArrivalFallbackTimer = timer
    }

    private func completePendingPointArrival() {
        guard let pendingPointArrival else { return }
        pointingArrivalFallbackTimer?.invalidate()
        pointingArrivalFallbackTimer = nil
        pointingTarget = nil
        self.pendingPointArrival = nil
        pendingPointArrival()
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
        if isAnswerOpen {
            promptBubbleView.advanceTargetMarkerBlink()
            targetMarkerView.advanceTargetMarkerBlink()
        }
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
            let hasPendingArrival = pendingPointArrival != nil
            let didArrive = distance <= Self.pointingArrivalThreshold
            petView.apply(state: didArrive ? .ready : .run, mode: currentMode)
            if didArrive, hasPendingArrival {
                completePendingPointArrival()
            }
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

    private func enableTabInterceptor() {
        tabInterceptor?.disable()
        let interceptor = TabKeyInterceptor { [weak self] in
            self?.toggleMode()
        }
        tabInterceptor = interceptor
        interceptor.enable()
    }

    private func toggleMode() {
        currentMode = currentMode == .smartReply ? .selection : .smartReply
        petView.apply(state: selectedText == nil && !isReadyLockedUntilPanelCloses ? .idle : .ready, mode: currentMode)
    }

    private func invokeCurrentMode() {
        guard let selectedText, !isReadyLockedUntilPanelCloses else { return }

        switch currentMode {
        case .selection:
            onTranslate?(selectedText)
        case .draftMessage:
            onRewrite?(selectedText)
        case .smartReply:
            onSmartReply?(selectedText)
        }
    }

    private func invokeRewriteMode() {
        guard let selectedText,
              !isReadyLockedUntilPanelCloses,
              currentMode == .selection
        else { return }

        onRewrite?(selectedText)
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
    /// view's mouseDown. The target marker is intentionally NOT translated:
    /// it anchors to whatever on-screen object the answer is about, so the
    /// user can drag the bubble to a readable spot without the pointer
    /// losing its target. The caller supplies the initial screen-space mouse
    /// location captured at mouseDown so drag-vs-click detection upstream
    /// doesn't shift the anchor.
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

@MainActor
final class PetMascotView: NSView {
    enum State: Equatable {
        case idle
        case run
        case ready
        case thinking
        case talking
        case flying
    }

    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onRightClick: (() -> Void)?
    var onDragRequested: ((NSPoint) -> Void)?
    var allowsClickWhenNotReady = false

    private var state: State = .idle
    private var mode: TranslationMode = .selection
    private var emotion: AskNugumiEmotion = .neutral
    private var animationFrame = 0
    /// Writing register dressed onto the character: formal = top hat + mustache,
    /// casual = cap, polite = bare (no accessory).
    private var writingStyle: WritingStyle = .polite

    func setWritingStyle(_ style: WritingStyle) {
        guard writingStyle != style else { return }
        writingStyle = style
        needsDisplay = true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        toolTip = "Nugumi"
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        // Double-click always wins over single-click handling and short-
        // circuits drag detection — this is how Ask gets dismissed now.
        if event.clickCount >= 2, let onDoubleClick {
            onDoubleClick()
            return
        }

        // With a drag handler installed, peek the first follow-up event to
        // decide: a movement before mouseUp means the user wants to drag,
        // an immediate mouseUp means it was a plain click.
        if let onDragRequested {
            let startLocation = NSEvent.mouseLocation
            while true {
                let next = NSApp.nextEvent(
                    matching: [.leftMouseDragged, .leftMouseUp],
                    until: .distantFuture,
                    inMode: .eventTracking,
                    dequeue: true
                )
                guard let next else { return }
                if next.type == .leftMouseUp {
                    if state == .ready || allowsClickWhenNotReady {
                        onClick?()
                    }
                    return
                }
                // First .leftMouseDragged — hand off to the drag handler
                // using the location captured at mouseDown.
                NSCursor.closedHand.push()
                onDragRequested(startLocation)
                NSCursor.pop()
                return
            }
        }

        guard state == .ready || allowsClickWhenNotReady else { return }
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard state == .ready else { return }
        onRightClick?()
    }

    func apply(state: State, mode: TranslationMode, emotion: AskNugumiEmotion = .neutral) {
        let didChange = self.state != state || self.mode != mode || self.emotion != emotion
        self.state = state
        self.mode = mode
        self.emotion = emotion
        toolTip = tooltip(for: state, mode: mode)
        if didChange {
            needsDisplay = true
        }
    }

    func advanceAnimationFrame() {
        animationFrame = (animationFrame + 1) % 240
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let context = NSGraphicsContext.current
        let previousAntialiasing = context?.shouldAntialias
        context?.shouldAntialias = false
        defer {
            if let previousAntialiasing {
                context?.shouldAntialias = previousAntialiasing
            }
        }

        let rows = spriteRows()
        let cellSize: CGFloat = 2
        let maxColumns = rows.map(\.count).max() ?? 0
        let spriteSize = NSSize(width: CGFloat(maxColumns) * cellSize, height: CGFloat(rows.count) * cellSize)
        let spriteYOffset = spriteYOffset()
        let origin = NSPoint(
            x: floor((bounds.width - spriteSize.width) / 2),
            y: floor((bounds.height - spriteSize.height) / 2) + 1 + spriteYOffset
        )

        let accessory = styleAccessoryCells(rowCount: rows.count, faceOffset: currentFaceOffset())

        // Combined silhouette of body + accessory, used to stamp a thin dark rim
        // so the pale character stays legible on light backgrounds.
        var occupied = Set<MascotCell>()
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, pixel) in row.enumerated() where color(for: pixel) != nil {
                occupied.insert(MascotCell(col: columnIndex, row: rowIndex))
            }
        }
        for cell in accessory.behind + accessory.front {
            occupied.insert(MascotCell(col: cell.col, row: cell.row))
        }

        drawPixelShadow(origin: origin)
        drawSpriteOutline(occupied, origin: origin, cellSize: cellSize, rowCount: rows.count)
        // z-order, back to front: tail, cap crown, body (ears), visor.
        drawPixelTail(origin: origin, cellSize: cellSize)
        drawAccessoryCells(accessory.behind, origin: origin, cellSize: cellSize, rowCount: rows.count)
        drawPixelRows(rows, origin: origin, cellSize: cellSize)
        drawAccessoryCells(accessory.front, origin: origin, cellSize: cellSize, rowCount: rows.count)
        if state == .ready {
            drawPixelActionBadge()
        }
        if state == .thinking {
            drawThinkingBadge()
        }
    }

    private struct MascotCell: Hashable { let col: Int; let row: Int }

    private func mascotCellRect(col: Int, row: Int, origin: NSPoint, cellSize: CGFloat, rowCount: Int) -> NSRect {
        NSRect(
            x: origin.x + CGFloat(col) * cellSize,
            y: origin.y + CGFloat(rowCount - row - 1) * cellSize,
            width: cellSize,
            height: cellSize
        )
    }

    /// One soft cell in every empty 4-neighbor of the silhouette → a 1-cell rim.
    /// A muted, semi-transparent slate (not hard black) so it reads as a gentle
    /// edge on light backgrounds without looking like a heavy outline.
    private func drawSpriteOutline(_ occupied: Set<MascotCell>, origin: NSPoint, cellSize: CGFloat, rowCount: Int) {
        NSColor(srgbRed: 0.40, green: 0.43, blue: 0.49, alpha: 0.6).setFill()
        for cell in occupied {
            let neighbors = [
                MascotCell(col: cell.col - 1, row: cell.row),
                MascotCell(col: cell.col + 1, row: cell.row),
                MascotCell(col: cell.col, row: cell.row - 1),
                MascotCell(col: cell.col, row: cell.row + 1),
            ]
            for n in neighbors where !occupied.contains(n) {
                NSBezierPath(rect: mascotCellRect(col: n.col, row: n.row, origin: origin, cellSize: cellSize, rowCount: rowCount)).fill()
            }
        }
    }

    /// Pixel cells for the current register's accessory, split by z-order.
    /// `behind` paints under the body sprite (so the ears stay in front of the
    /// cap's crown), `front` paints over it. `row` is measured from the sprite
    /// top (row 0); negative rows sit just above the head.
    private func styleAccessoryCells(
        rowCount: Int,
        faceOffset: Int
    ) -> (behind: [(col: Int, row: Int, color: NSColor)], front: [(col: Int, row: Int, color: NSColor)]) {
        switch writingStyle {
        case .polite:
            return ([], [])
        case .formal:
            let hat = NSColor(srgbRed: 0.16, green: 0.17, blue: 0.21, alpha: 1)
            let band = NSColor(srgbRed: 0.55, green: 0.16, blue: 0.20, alpha: 1)
            var cells: [(col: Int, row: Int, color: NSColor)] = []
            // Top hat: wide brim, red hatband, narrow crown above. The hat is
            // fixed to the head; only the mustache tracks the face's idle drift.
            // The brim overlaps the head's top row so the hat sits flush — one
            // row higher leaves a 1px gap of background between hat and head.
            for c in 4...11 { cells.append((c, 2, hat)) }      // brim
            for c in 5...10 { cells.append((c, 1, band)) }     // hatband
            for c in 5...10 { cells.append((c, 0, hat)) }      // crown
            for c in 5...10 { cells.append((c, -1, hat)) }     // crown top
            // Tidy mustache centered under the nose, shifted with the face.
            for c in [5, 6, 8, 9] { cells.append((c + faceOffset, 8, hat)) }
            return ([], cells)
        case .casual:
            let cap = NSColor(srgbRed: 0.20, green: 0.52, blue: 0.50, alpha: 1)
            let capDark = NSColor(srgbRed: 0.13, green: 0.40, blue: 0.39, alpha: 1)
            // Baseball cap: rounded crown sitting up-right, a flat visor
            // jutting left. The crown goes BEHIND the body so the ears poke
            // out in front of it; the visor stays on top, sticking out over
            // the left ear.
            var crown: [(col: Int, row: Int, color: NSColor)] = []
            for c in 6...10 { crown.append((c, 0, cap)) }      // crown top
            for c in 5...11 { crown.append((c, 1, cap)) }      // crown
            for c in 5...12 { crown.append((c, 2, cap)) }      // crown base (right side)
            // Two-row visor angled down-left: light top surface continuous
            // with the crown, dark underside shifted one cell out — reads as
            // a proper peak instead of a dark blob.
            var visor: [(col: Int, row: Int, color: NSColor)] = []
            for c in 1...4 { visor.append((c, 2, cap)) }       // top surface
            for c in 0...3 { visor.append((c, 3, capDark)) }   // underside / tip
            return (crown, visor)
        }
    }

    private func drawAccessoryCells(_ cells: [(col: Int, row: Int, color: NSColor)], origin: NSPoint, cellSize: CGFloat, rowCount: Int) {
        for cell in cells {
            cell.color.setFill()
            NSBezierPath(rect: mascotCellRect(col: cell.col, row: cell.row, origin: origin, cellSize: cellSize, rowCount: rowCount)).fill()
        }
    }

    private func spriteYOffset() -> CGFloat {
        switch state {
        case .idle:
            return animationFrame % 90 >= 72 ? 0.5 : 0
        case .run:
            return (animationFrame / 4) % 2 == 0 ? 1 : 0
        case .ready:
            return animationFrame % 64 < 8 ? 0.75 : 0
        case .thinking:
            let phase = animationFrame % 32
            if phase < 8 { return 0 }
            if phase < 16 { return 0.5 }
            if phase < 24 { return 1 }
            return 0.5
        case .talking:
            // Body holds still — only the mouth (sprite swap) and tail
            // (drawPixelTail) animate while answering.
            return 0
        case .flying:
            // Rapid wobble — sells the "thrown" feeling. Two pixels of
            // amplitude, ~3-frame period (~100ms at 30fps).
            return CGFloat((animationFrame / 3) % 3) - 1
        }
    }

    private func idleFaceOffset() -> Int {
        switch (animationFrame / 32) % 4 {
        case 1:
            return -1
        case 3:
            return 1
        default:
            return 0
        }
    }

    /// Horizontal drift of the face this frame — the mustache rides along so it
    /// stays under the nose. Only the neutral idle animation shifts the face.
    private func currentFaceOffset() -> Int {
        state == .idle && emotion == .neutral ? idleFaceOffset() : 0
    }

    private func spriteRows() -> [String] {
        switch state {
        case .idle:
            if emotion != .neutral {
                return emotionSpriteRows(emotion)
            }
            return spriteRows(faceOffset: idleFaceOffset(), noseWidth: 1)
        case .run:
            if (animationFrame / 5) % 2 == 0 {
                return [
                    "................",
                    "..WG........GW..",
                    ".GWWW......WWWG.",
                    ".GWWWWWWWWWWWWG.",
                    "GWWWWWWWWWWWWWWG",
                    "WWWWKKWWWWKKWWWW",
                    "WWWWKKWWWWKKWWWW",
                    "GWWWWWWPWWWWWWWG",
                    "WWGWWWWWWWWWWGWW",
                    ".GWWWWWWWWWWWWG.",
                    "...WW......WWW..",
                    "................"
                ]
            } else {
                return [
                    "................",
                    "..WG........GW..",
                    ".GWWW......WWWG.",
                    ".GWWWWWWWWWWWWG.",
                    "GWWWWWWWWWWWWWWG",
                    "WWWWKKWWWWKKWWWW",
                    "WWWWKKWWWWKKWWWW",
                    "GWWWWWWPWWWWWWWG",
                    "WWGWWWWWWWWWWGWW",
                    ".GWWWWWWWWWWWWG.",
                    "..WWW......WW...",
                    "................"
                ]
            }
        case .ready:
            return spriteRows(faceOffset: 0, noseWidth: 1)
        case .thinking:
            return spriteRows(faceOffset: 0, noseWidth: 1)
        case .talking:
            // Eyes, nose, ears, body — frozen. Identical to a calm idle pose
            // (faceOffset=0, neutral). Only the mouth (this row swap) and the
            // tail (drawPixelTail) move while the answer is shown.
            let mouthOpen = (animationFrame / 10) % 2 == 1
            return mouthOpen ? talkingSpriteRows() : spriteRows(faceOffset: 0, noseWidth: 1)
        case .flying:
            return flyingSpriteRows()
        }
    }

    private func flyingSpriteRows() -> [String] {
        // Shocked-in-flight expression: wide 3-pixel eyes, plain nose, no
        // mouth. The bigger eyes carry the "thrown!" feeling on their own.
        [
            "................",
            "..WG........GW..",
            ".GWWW......WWWG.",
            ".GWWWWWWWWWWWWG.",
            "GWWWWWWWWWWWWWWG",
            "WWWKKKWWWWKKKWWW",
            "WWWKKKWWWWKKKWWW",
            "GWWWWWWPWWWWWWWG",
            "WWGWWWWWWWWWWGWW",
            ".GWWWWWWWWWWWWG.",
            "...WW......WW...",
            "................"
        ]
    }

    private func talkingSpriteRows() -> [String] {
        // Neutral centered head with a single-pixel mouth at row 8, col 9 —
        // diagonally below-right of the nose (col 7), with col 8 as a 1-pixel
        // horizontal gap. Reads as a small mouth, not a nose drip.
        var rows = spriteRows(faceOffset: 0, noseWidth: 1)
        var chars = Array(rows[8])
        if chars.count > 9 {
            chars[9] = "K"
            rows[8] = String(chars)
        }
        return rows
    }

    private func emotionSpriteRows(_ emotion: AskNugumiEmotion) -> [String] {
        switch emotion {
        case .neutral:
            return spriteRows(faceOffset: 0, noseWidth: 1)
        case .happy:
            return spriteRows(
                eyeRow: "WWWKWWWWWWKWWWWW",
                noseRow: "GWWWWWPPWWWWWWWG"
            )
        case .surprised:
            return spriteRows(
                eyeRow: "WWWWKKWWWWKKWWWW",
                noseRow: "GWWWWWKKWWWWWWWG"
            )
        case .confused:
            return spriteRows(
                eyeRow: "WWWKKWWWWWKWWWWW",
                noseRow: "GWWWWWWPWWWWWWWG"
            )
        case .concerned:
            return spriteRows(
                eyeRow: "WWWWKWWWWWWKWWWW",
                noseRow: "GWWWWKKWWWWWWWWG"
            )
        }
    }

    private func spriteRows(eyeRow: String, noseRow: String) -> [String] {
        [
            "................",
            "..WG........GW..",
            ".GWWW......WWWG.",
            ".GWWWWWWWWWWWWG.",
            "GWWWWWWWWWWWWWWG",
            eyeRow,
            eyeRow,
            noseRow,
            "WWGWWWWWWWWWWGWW",
            ".GWWWWWWWWWWWWG.",
            "...WW......WW...",
            "................"
        ]
    }

    private func spriteRows(faceOffset: Int, noseWidth: Int) -> [String] {
        let eyeRow: String
        let noseRow: String
        switch faceOffset {
        case ..<0:
            eyeRow = "WWWKKWWWWKKWWWWW"
            noseRow = noseWidth == 1 ? "GWWWWWPWWWWWWWWG" : "GWWWWWPPWWWWWWWG"
        case 1...:
            eyeRow = "WWWWWKKWWWWKKWWW"
            noseRow = noseWidth == 1 ? "GWWWWWWWPWWWWWWG" : "GWWWWWWPPWWWWWWG"
        default:
            eyeRow = "WWWWKKWWWWKKWWWW"
            noseRow = noseWidth == 1 ? "GWWWWWWPWWWWWWWG" : "GWWWWWPPWWWWWWG."
        }

        return spriteRows(eyeRow: eyeRow, noseRow: noseRow)
    }

    private func drawPixelRows(_ rows: [String], origin: NSPoint, cellSize: CGFloat) {
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, pixel) in row.enumerated() {
                guard let color = color(for: pixel) else { continue }
                color.setFill()
                let rect = NSRect(
                    x: origin.x + CGFloat(columnIndex) * cellSize,
                    y: origin.y + CGFloat(rows.count - rowIndex - 1) * cellSize,
                    width: cellSize,
                    height: cellSize
                )
                NSBezierPath(rect: rect).fill()
            }
        }
    }

    private func drawPixelTail(origin: NSPoint, cellSize: CGFloat) {
        let cells: [(Int, Int)]
        switch state {
        case .idle:
            switch (animationFrame / 24) % 3 {
            case 0:
                cells = [(7, 9), (7, 10), (8, 11), (9, 12), (10, 12)]
            case 1:
                cells = [(7, 9), (8, 10), (8, 11), (8, 12), (9, 12)]
            default:
                cells = [(7, 9), (8, 10), (7, 11), (6, 12), (5, 12)]
            }
        case .run:
            if (animationFrame / 5) % 2 == 0 {
                cells = [(7, 9), (7, 10), (8, 11), (10, 12), (11, 12)]
            } else {
                cells = [(8, 9), (8, 10), (7, 11), (5, 12), (4, 12)]
            }
        case .ready, .thinking, .talking:
            switch (animationFrame / 16) % 2 {
            case 0:
                cells = [(7, 9), (8, 10), (8, 11), (9, 12), (10, 12)]
            default:
                cells = [(7, 9), (7, 10), (8, 11), (8, 12), (9, 12)]
            }
        case .flying:
            // Tail flails fast — switches every 3 frames (~100ms) between
            // hard-left and hard-right wags.
            switch (animationFrame / 3) % 2 {
            case 0:
                cells = [(7, 9), (8, 10), (9, 11), (10, 12), (11, 12)]
            default:
                cells = [(7, 9), (6, 10), (5, 11), (4, 12), (3, 12)]
            }
        }

        let tailColor = NSColor(srgbRed: 0.93, green: 0.94, blue: 0.90, alpha: 1.0)
        let tailShade = NSColor(srgbRed: 0.68, green: 0.72, blue: 0.73, alpha: 1.0)
        for (index, cell) in cells.enumerated() {
            (index == cells.count - 1 ? tailShade : tailColor).setFill()
            let rect = NSRect(
                x: origin.x + CGFloat(cell.0) * cellSize,
                y: origin.y + CGFloat(cell.1) * cellSize,
                width: cellSize,
                height: cellSize
            )
            NSBezierPath(rect: rect).fill()
        }
    }

    private func drawPixelShadow(origin: NSPoint) {
        NSColor(calibratedWhite: 0.0, alpha: 0.18).setFill()
        NSBezierPath(rect: NSRect(x: origin.x + 4, y: origin.y - 1, width: 22, height: 2)).fill()
        NSBezierPath(rect: NSRect(x: origin.x + 8, y: origin.y - 3, width: 14, height: 2)).fill()
    }

    private func drawPixelActionBadge() {
        switch mode {
        case .selection:
            drawTranslateBadge()
        case .draftMessage:
            drawRewriteBadge()
        case .smartReply:
            drawReplyBadge()
        }
    }

    private func badgeOrigin(width: CGFloat, height: CGFloat) -> NSPoint {
        NSPoint(x: bounds.width - width, y: bounds.height - height)
    }

    private func drawTranslateBadge() {
        let frame = NSRect(origin: badgeOrigin(width: 19, height: 14), size: NSSize(width: 19, height: 14))

        let context = NSGraphicsContext.current
        let previousAntialiasing = context?.shouldAntialias
        context?.shouldAntialias = true
        defer {
            if let previousAntialiasing {
                context?.shouldAntialias = previousAntialiasing
            }
        }

        NSColor(calibratedWhite: 0.0, alpha: 0.25).setFill()
        NSBezierPath(roundedRect: NSRect(x: frame.minX + 2, y: frame.minY - 1, width: 15, height: 3), xRadius: 1.5, yRadius: 1.5).fill()

        let borderColor = NSColor(srgbRed: 0.42, green: 0.46, blue: 0.47, alpha: 1.0)
        let shape = NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3)
        borderColor.setFill()
        shape.fill()

        let inner = frame.insetBy(dx: 1.5, dy: 1.5)
        let leftRect = NSRect(x: inner.minX, y: inner.minY, width: inner.width * 0.52, height: inner.height)
        let rightRect = NSRect(x: leftRect.maxX, y: inner.minY, width: inner.maxX - leftRect.maxX, height: inner.height)

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor(srgbRed: 0.02, green: 0.55, blue: 0.76, alpha: 1.0).setFill()
        NSBezierPath(rect: leftRect).fill()
        NSColor(srgbRed: 0.80, green: 0.86, blue: 0.87, alpha: 1.0).setFill()
        NSBezierPath(rect: rightRect).fill()
        NSGraphicsContext.restoreGraphicsState()

        drawBadgeText("A", color: .white, fontSize: 8.5, in: NSRect(x: inner.minX - 0.5, y: inner.minY + 0.5, width: leftRect.width, height: inner.height))
        drawBadgeText("文", color: NSColor(srgbRed: 0.19, green: 0.34, blue: 0.39, alpha: 1.0), fontSize: 8, in: NSRect(x: rightRect.minX - 0.5, y: rightRect.minY + 0.5, width: rightRect.width + 1, height: rightRect.height))
    }

    private func drawRewriteBadge() {
        let frame = NSRect(origin: badgeOrigin(width: 18, height: 15), size: NSSize(width: 18, height: 15))

        let context = NSGraphicsContext.current
        let previousAntialiasing = context?.shouldAntialias
        context?.shouldAntialias = true
        defer {
            if let previousAntialiasing {
                context?.shouldAntialias = previousAntialiasing
            }
        }

        NSColor(calibratedWhite: 0.0, alpha: 0.25).setFill()
        NSBezierPath(roundedRect: NSRect(x: frame.minX + 2, y: frame.minY - 1, width: 14, height: 3), xRadius: 1.5, yRadius: 1.5).fill()

        let outline = NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3)
        NSColor(srgbRed: 0.42, green: 0.46, blue: 0.47, alpha: 1.0).setFill()
        outline.fill()

        let inner = frame.insetBy(dx: 1.7, dy: 1.7)
        NSColor(srgbRed: 0.98, green: 0.98, blue: 0.96, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: inner, xRadius: 2, yRadius: 2).fill()
        drawBadgeText("✎", color: NSColor(srgbRed: 0.14, green: 0.18, blue: 0.20, alpha: 1.0), fontSize: 10.5, in: NSRect(x: inner.minX, y: inner.minY + 0.5, width: inner.width, height: inner.height))
    }

    private func drawReplyBadge() {
        let origin = badgeOrigin(width: 18, height: 16)
        let bubbleRect = NSRect(x: origin.x, y: origin.y + 3, width: 18, height: 13)

        let context = NSGraphicsContext.current
        let previousAntialiasing = context?.shouldAntialias
        context?.shouldAntialias = true
        defer {
            if let previousAntialiasing {
                context?.shouldAntialias = previousAntialiasing
            }
        }

        NSColor(calibratedWhite: 0.0, alpha: 0.22).setFill()
        NSBezierPath(roundedRect: NSRect(x: origin.x + 2, y: origin.y + 1, width: 14, height: 3), xRadius: 1.5, yRadius: 1.5).fill()

        let outline = NSBezierPath(roundedRect: bubbleRect, xRadius: 3, yRadius: 3)
        outline.move(to: NSPoint(x: bubbleRect.midX - 2, y: bubbleRect.minY + 1))
        outline.line(to: NSPoint(x: bubbleRect.midX, y: origin.y))
        outline.line(to: NSPoint(x: bubbleRect.midX + 2, y: bubbleRect.minY + 1))
        outline.close()
        NSColor(srgbRed: 0.42, green: 0.46, blue: 0.47, alpha: 1.0).setFill()
        outline.fill()

        let fill = NSBezierPath(roundedRect: bubbleRect.insetBy(dx: 1.7, dy: 1.7), xRadius: 2, yRadius: 2)
        NSColor(srgbRed: 0.98, green: 0.98, blue: 0.96, alpha: 1.0).setFill()
        fill.fill()
        let tailFill = NSBezierPath()
        tailFill.move(to: NSPoint(x: bubbleRect.midX - 1.2, y: bubbleRect.minY + 2))
        tailFill.line(to: NSPoint(x: bubbleRect.midX, y: origin.y + 2))
        tailFill.line(to: NSPoint(x: bubbleRect.midX + 1.2, y: bubbleRect.minY + 2))
        tailFill.close()
        tailFill.fill()

        NSColor(srgbRed: 0.12, green: 0.13, blue: 0.13, alpha: 1.0).setFill()
        for x in [bubbleRect.minX + 5, bubbleRect.midX, bubbleRect.maxX - 5] {
            NSBezierPath(ovalIn: NSRect(x: x - 1.1, y: bubbleRect.midY - 1.1, width: 2.2, height: 2.2)).fill()
        }
    }

    private func drawThinkingBadge() {
        let origin = badgeOrigin(width: 18, height: 16)
        let bubbleRect = NSRect(x: origin.x, y: origin.y + 3, width: 18, height: 13)

        let context = NSGraphicsContext.current
        let previousAntialiasing = context?.shouldAntialias
        context?.shouldAntialias = true
        defer {
            if let previousAntialiasing {
                context?.shouldAntialias = previousAntialiasing
            }
        }

        NSColor(calibratedWhite: 0.0, alpha: 0.22).setFill()
        NSBezierPath(roundedRect: NSRect(x: origin.x + 2, y: origin.y + 1, width: 14, height: 3), xRadius: 1.5, yRadius: 1.5).fill()

        let outline = NSBezierPath(roundedRect: bubbleRect, xRadius: 3, yRadius: 3)
        outline.move(to: NSPoint(x: bubbleRect.midX - 2, y: bubbleRect.minY + 1))
        outline.line(to: NSPoint(x: bubbleRect.midX, y: origin.y))
        outline.line(to: NSPoint(x: bubbleRect.midX + 2, y: bubbleRect.minY + 1))
        outline.close()
        NSColor(srgbRed: 0.42, green: 0.46, blue: 0.47, alpha: 1.0).setFill()
        outline.fill()

        let fill = NSBezierPath(roundedRect: bubbleRect.insetBy(dx: 1.7, dy: 1.7), xRadius: 2, yRadius: 2)
        NSColor(srgbRed: 0.98, green: 0.98, blue: 0.96, alpha: 1.0).setFill()
        fill.fill()
        let tailFill = NSBezierPath()
        tailFill.move(to: NSPoint(x: bubbleRect.midX - 1.2, y: bubbleRect.minY + 2))
        tailFill.line(to: NSPoint(x: bubbleRect.midX, y: origin.y + 2))
        tailFill.line(to: NSPoint(x: bubbleRect.midX + 1.2, y: bubbleRect.minY + 2))
        tailFill.close()
        tailFill.fill()

        // Animated dots: cycle one bright dot at a time
        let activeDot = (animationFrame / 8) % 3
        for (index, x) in [bubbleRect.minX + 5, bubbleRect.midX, bubbleRect.maxX - 5].enumerated() {
            let isActive = index == activeDot
            let color = isActive
                ? NSColor(srgbRed: 0.12, green: 0.13, blue: 0.13, alpha: 1.0)
                : NSColor(srgbRed: 0.55, green: 0.57, blue: 0.58, alpha: 1.0)
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 1.1, y: bubbleRect.midY - 1.1, width: 2.2, height: 2.2)).fill()
        }
    }

    private func drawBadgeText(_ text: String, color: NSColor, fontSize: CGFloat, in rect: NSRect) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .black),
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }

    private func color(for pixel: Character) -> NSColor? {
        switch pixel {
        case "W":
            return NSColor(srgbRed: 0.95, green: 0.96, blue: 0.92, alpha: 1)
        case "G":
            return NSColor(srgbRed: 0.70, green: 0.75, blue: 0.76, alpha: 1)
        case "K":
            return NSColor(srgbRed: 0.07, green: 0.09, blue: 0.12, alpha: 1)
        case "P":
            return NSColor(srgbRed: 0.96, green: 0.55, blue: 0.65, alpha: 1)
        case "B":
            return NSColor(srgbRed: 0.97, green: 0.96, blue: 0.86, alpha: 1)
        case "D":
            return NSColor(srgbRed: 0.08, green: 0.16, blue: 0.20, alpha: 1)
        default:
            return nil
        }
    }

    private func tooltip(for state: State, mode: TranslationMode) -> String {
        switch state {
        case .idle, .run:
            return "Nugumi pet"
        case .ready:
            switch mode {
            case .selection:
                return "Translate selection - right-click to Rewrite, Tab to switch to Reply"
            case .draftMessage:
                return "Rewrite my text - Tab to switch to Reply"
            case .smartReply:
                return "Generate reply - Tab to switch back"
            }
        case .thinking:
            return "Thinking…"
        case .talking:
            return "Double-click to close"
        case .flying:
            return "Weeee!"
        }
    }
}

@MainActor
final class FloatingTranslateButtonController {
    private let panel: NSPanel
    private let selectedText: String
    private let onTranslate: (String) -> Void
    private let onRewrite: (String) -> Void
    private let onSmartReply: (String) -> Void
    private let buttonView: FloatingTranslateButtonView
    private var currentMode: TranslationMode
    private var tabInterceptor: TabKeyInterceptor?

    init(
        screenPoint: NSPoint,
        selectedText: String,
        initialMode: TranslationMode,
        onTranslate: @escaping (String) -> Void,
        onRewrite: @escaping (String) -> Void,
        onSmartReply: @escaping (String) -> Void
    ) {
        self.selectedText = selectedText
        self.onTranslate = onTranslate
        self.onRewrite = onRewrite
        self.onSmartReply = onSmartReply
        self.currentMode = initialMode

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
            guard let self else { return }
            self.invokeCurrentMode()
        }
        buttonView.onRightClick = { [weak self] in
            self?.invokeRewriteMode()
        }
    }

    func show() {
        panel.orderFrontRegardless()
        let interceptor = TabKeyInterceptor { [weak self] in
            self?.toggleMode()
        }
        tabInterceptor = interceptor
        interceptor.enable()
    }

    func close() {
        tabInterceptor?.disable()
        tabInterceptor = nil
        panel.close()
    }

    func setLoading() {
        panel.ignoresMouseEvents = true
        tabInterceptor?.disable()
        tabInterceptor = nil
        buttonView.setLoading(true)
    }

    func pointAt(_ targetPoint: NSPoint, visibleFrame: NSRect) {
        let presentation = AskNugumiFloatingTargetPresentationPolicy.presentation(
            targetPoint: targetPoint,
            visibleFrame: visibleFrame
        )
        panel.ignoresMouseEvents = true
        tabInterceptor?.disable()
        tabInterceptor = nil
        buttonView.setTargetArrow(angle: presentation.arrowAngleRadians)
        panel.orderFrontRegardless()

        // Slower glide so the trip from the pet to the target reads clearly,
        // then a pop on arrival so the destination is unmistakable.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.42
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(presentation.panelFrame, display: true)
        }, completionHandler: {
            // AppKit invokes this on the main thread.
            MainActor.assumeIsolated { [weak self] in
                self?.playArrivalPulse()
            }
        })
    }

    /// Quick scale "pop" on the button, centered, after it lands on target.
    private func playArrivalPulse() {
        let base = AskNugumiFloatingTargetPresentationPolicy.buttonSize
        let pad = AskNugumiFloatingTargetPresentationPolicy.shadowPadding
        let center = pad + base / 2
        let grownSide = base * 1.3
        let grown = NSRect(
            x: center - grownSide / 2,
            y: center - grownSide / 2,
            width: grownSide,
            height: grownSide
        )
        let normal = NSRect(x: pad, y: pad, width: base, height: base)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            buttonView.animator().frame = grown
        }, completionHandler: {
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    self.buttonView.animator().frame = normal
                }
            }
        })
    }

    private func toggleMode() {
        currentMode = (currentMode == .smartReply) ? .selection : .smartReply
        buttonView.apply(mode: currentMode)
    }

    private func invokeCurrentMode() {
        switch currentMode {
        case .selection:
            onTranslate(selectedText)
        case .draftMessage:
            onRewrite(selectedText)
        case .smartReply:
            onSmartReply(selectedText)
        }
    }

    private func invokeRewriteMode() {
        guard currentMode == .selection else { return }
        onRewrite(selectedText)
    }
}

/// The Ask Nugumi capsule's glass body. Any click inside it focuses the text
/// field instead of starting a window drag, so the whole pill is clickable.
private final class AskPromptGlassView: NSVisualEffectView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

private final class AskPromptTextField: NSTextField {
    var onEscape: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = AskPromptTextFieldCell(textCell: "")
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

@MainActor
final class AskPromptController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private static let textMovementUserInfoKey = "NSTextMovement"

    private let panel: NSPanel
    private let textField: AskPromptTextField
    private let onSubmit: (String) -> Void
    private let onClose: () -> Void
    private var didClose = false
    private var isSubmitting = false
    private var globalOutsideClickMonitor: Any?
    private var localOutsideClickMonitor: Any?

    var isVisible: Bool { panel.isVisible }

    /// Center of the pill's window in screen coordinates. Used by the
    /// caller to position the substitute floating loading bar at the same
    /// spot when the pill is hidden during an in-flight question.
    var panelCenter: NSPoint {
        NSPoint(x: panel.frame.midX, y: panel.frame.midY)
    }

    init(
        near screenPoint: NSPoint,
        onSubmit: @escaping (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.onSubmit = onSubmit
        self.onClose = onClose

        let layout = AskNugumiFloatingPromptMetrics.layout
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
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textField)
        installOutsideClickMonitors()
    }

    func setLoading() {
        panel.sharingType = .none
        textField.isEnabled = false
        textField.stringValue = ""
        setPlaceholder("Looking...")
    }

    /// Visually removes the pill while keeping the controller (and its
    /// outside-click monitors) alive. `closeIfClickIsOutside` bails on
    /// `panel.isVisible`, so clicks become no-ops until `showError` brings
    /// the panel back via `makeKeyAndOrderFront`.
    func hidePanel() {
        panel.orderOut(nil)
    }

    func showError(_ message: String) {
        isSubmitting = false
        textField.isEnabled = true
        textField.stringValue = ""
        setPlaceholder(message)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textField)
    }

    func close() {
        guard !didClose else { return }
        didClose = true
        removeOutsideClickMonitors()
        panel.close()
        onClose()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, !self.didClose else { return }
            self.didClose = true
            self.removeOutsideClickMonitors()
            self.onClose()
        }
    }

    deinit {
        if let globalOutsideClickMonitor {
            NSEvent.removeMonitor(globalOutsideClickMonitor)
        }
        if let localOutsideClickMonitor {
            NSEvent.removeMonitor(localOutsideClickMonitor)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard textMovement(from: notification) == NSTextMovement.return.rawValue else {
            return
        }
        submit()
    }

    private func buildUI() {
        let layout = AskNugumiFloatingPromptMetrics.layout
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
        setPlaceholder("Ask Nugumi")
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

    private func installOutsideClickMonitors() {
        guard globalOutsideClickMonitor == nil, localOutsideClickMonitor == nil else {
            return
        }

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.closeIfClickIsOutside(event)
        }

        localOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.closeIfClickIsOutside(event)
            return event
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
    }

    private func closeIfClickIsOutside(_ event: NSEvent) {
        guard panel.isVisible else {
            return
        }

        let screenPoint = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        guard !panel.frame.insetBy(dx: -4, dy: -4).contains(screenPoint) else {
            return
        }

        close()
    }

    private static func origin(near point: NSPoint, size: NSSize) -> NSPoint {
        let visibleFrame = NSScreen.visibleFrame(containing: point)
        let edgeMargin = AskNugumiFloatingPromptMetrics.edgeMargin
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

private final class RightClickableButton: NSButton {
    var onRightClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}

private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
final class FloatingTranslateButtonView: NSView {
    var onClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    private let actionButton = RightClickableButton()
    private let progressIndicator = NSProgressIndicator()
    private var currentMode: TranslationMode
    private var isLoading = false

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
        layer.shadowOpacity = 0.38
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: -3)
        layer.shadowPath = CGPath(ellipseIn: bounds, transform: nil)
        layer.masksToBounds = false
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

        actionButton.target = self
        actionButton.action = #selector(buttonTapped)
        actionButton.onRightClick = { [weak self] in
            self?.onRightClick?()
        }
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

    func setTargetArrow(angle: CGFloat) {
        isLoading = false
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        actionButton.isHidden = false
        actionButton.image = Self.targetArrowImage(angle: angle)
        actionButton.title = ""
        actionButton.imagePosition = .imageOnly
        actionButton.toolTip = "Target"
    }

    private func applyModeVisuals() {
        switch currentMode {
        case .selection:
            actionButton.image = nil
            actionButton.title = "あ"
            actionButton.imagePosition = .noImage
            actionButton.toolTip = "Translate selection — right-click to Rewrite, Tab to switch to Reply"
        case .draftMessage:
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            if let image = NSImage(systemSymbolName: "text.insert", accessibilityDescription: "Rewrite my text")
                ?? NSImage(systemSymbolName: "pencil.line", accessibilityDescription: "Rewrite my text") {
                actionButton.image = image.withSymbolConfiguration(config)
                actionButton.title = ""
                actionButton.imagePosition = .imageOnly
            } else {
                actionButton.image = nil
                actionButton.title = "✎"
                actionButton.imagePosition = .noImage
            }
            actionButton.toolTip = "Rewrite my text — Tab to switch to Reply"
        case .smartReply:
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            actionButton.image = NSImage(
                systemSymbolName: "bubble.left.fill",
                accessibilityDescription: "Generate reply or answer"
            )?.withSymbolConfiguration(config)
            actionButton.title = ""
            actionButton.imagePosition = .imageOnly
            actionButton.toolTip = "Generate reply — Tab to switch back"
        }
    }

    @objc private func buttonTapped() {
        onClick?()
    }

    private static func targetArrowImage(angle: CGFloat) -> NSImage {
        let imageSize = NSSize(width: 18, height: 18)
        let image = NSImage(size: imageSize)
        image.lockFocus()
        NSGraphicsContext.saveGraphicsState()

        let transform = NSAffineTransform()
        transform.translateX(by: imageSize.width / 2, yBy: imageSize.height / 2)
        transform.rotate(byRadians: angle)
        transform.concat()

        let shaft = NSBezierPath()
        shaft.lineWidth = 2.2
        shaft.lineCapStyle = .round
        shaft.move(to: NSPoint(x: -5.5, y: 0))
        shaft.line(to: NSPoint(x: 4.3, y: 0))
        NSColor.white.setStroke()
        shaft.stroke()

        let head = NSBezierPath()
        head.move(to: NSPoint(x: 6.2, y: 0))
        head.line(to: NSPoint(x: 0.6, y: 4.3))
        head.line(to: NSPoint(x: 0.6, y: -4.3))
        head.close()
        NSColor.white.setFill()
        head.fill()

        NSGraphicsContext.restoreGraphicsState()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
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
    /// Esc closes the panel whenever Nugumi receives the keystroke (e.g.
    /// right after an Ask Nugumi answer, when the prompt left Nugumi active).
    private var localEscapeKeyMonitor: Any?
    private var commandCopyInterceptor: CommandCopyInterceptor?
    private var returnKeyInterceptor: ReturnKeyInterceptor?
    private var didClose = false
    private let onClose: (() -> Void)?
    private let replaceShortcutSourcePID: pid_t?

    var panelFrame: NSRect { panel.frame }
    var isVisible: Bool { panel.isVisible }

    private let loadingPlaceholder: String

    init(
        anchor: Anchor,
        sourceText: String,
        targetLanguage: TranslationLanguage,
        resultLabel: String? = nil,
        loadingPlaceholder: String = "Translating",
        onTargetLanguageSelected: ((TranslationLanguage) -> Void)? = nil,
        onReplace: ((String) -> Void)? = nil,
        replaceShortcutSourcePID: pid_t? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.loadingPlaceholder = loadingPlaceholder
        self.anchor = anchor
        self.onClose = onClose
        self.replaceShortcutSourcePID = replaceShortcutSourcePID
        let referencePoint = Self.anchorReferencePoint(for: anchor)
        let visibleFrame = NSScreen.visibleFrame(containing: referencePoint)
        let panelHeight = min(
            TranslationContentView.preferredHeight(sourceText: sourceText, resultText: "\(loadingPlaceholder)..."),
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
            onTargetLanguageSelected: onTargetLanguageSelected,
            onReplace: onReplace
        )
        panel = NSPanel(
            contentRect: NSRect(origin: origin, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
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
        contentView.onClose = { [weak self] in self?.close() }
        contentView.onNeedsResize = { [weak self] in
            self?.resizeToFitContent(animated: true)
        }
    }

    deinit {
        removeOutsideClickMonitors()
        removeCommandCopyInterceptor()
        removeReturnKeyInterceptor()
    }

    @discardableResult
    func showLoading(targetLanguage: TranslationLanguage? = nil) -> UUID {
        activeRequestID = UUID()
        if let targetLanguage {
            contentView.setTargetLanguage(targetLanguage)
        }
        contentView.startLoadingAnimation(baseText: loadingPlaceholder)
        resizeToFitContent(animated: false)
        panel.orderFrontRegardless()
        installOutsideClickMonitors()
        installCommandCopyInterceptor()
        installReturnKeyInterceptor()
        return activeRequestID
    }

    func showTranslation(_ text: String, requestID: UUID? = nil) {
        guard requestIsCurrent(requestID) else {
            return
        }

        contentView.setResult(text)
        resizeToFitContent(animated: false)
    }

    func showError(_ message: String, requestID: UUID? = nil) {
        guard requestIsCurrent(requestID) else {
            return
        }

        contentView.setError(message)
        resizeToFitContent(animated: true)
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
        panel.close()
        onClose?()
    }

    private func installOutsideClickMonitors() {
        guard globalOutsideClickMonitor == nil, localOutsideClickMonitor == nil else {
            return
        }

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.closeIfClickIsOutside(event)
        }

        localOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.closeIfClickIsOutside(event)
            return event
        }

        localEscapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.keyCode == UInt16(kVK_Escape),
                  self.panel.isVisible,
                  !self.contentView.isTargetLanguageMenuOpen
            else {
                return event
            }
            self.close()
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
        close()
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

        close()
    }

    private func requestIsCurrent(_ requestID: UUID?) -> Bool {
        guard let requestID else {
            return true
        }

        return requestID == activeRequestID
    }

    private func resizeToFitContent(animated: Bool) {
        let currentFrame = panel.frame
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

private extension NSScreen {
    static func visibleFrame(containing point: NSPoint) -> NSRect {
        NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
    }
}

enum GlassHostStyle {
    case regular
    case clear
}

final class GlassHostView: NSView {
    let contentView = NSView()

    init(frame: NSRect, cornerRadius: CGFloat, tintColor: NSColor?, style: GlassHostStyle) {
        super.init(frame: frame)
        wantsLayer = true
        contentView.frame = bounds
        contentView.autoresizingMask = [.width, .height]

        // Keep this compatible with the current public macOS SDK used by CI/release builds.
        // Referencing NSGlassEffectView directly breaks compilation on Xcode versions whose
        // SDK does not yet define that symbol, even inside an #available(macOS 26.0, *) block.
        let material = NSVisualEffectView(frame: bounds)
        material.autoresizingMask = [.width, .height]
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = cornerRadius
        material.layer?.masksToBounds = true
        addSubview(material)
        material.addSubview(contentView)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

final class GlassChromeOverlayView: NSView {
    var cornerRadius: CGFloat = 22

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor(calibratedWhite: 1.0, alpha: 0.16).setStroke()
        path.lineWidth = 1
        path.stroke()

        let innerRect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let innerPath = NSBezierPath(roundedRect: innerRect, xRadius: max(0, cornerRadius - 1), yRadius: max(0, cornerRadius - 1))
        NSColor(calibratedWhite: 1.0, alpha: 0.06).setStroke()
        innerPath.lineWidth = 1
        innerPath.stroke()
    }
}

final class HairlineSeparatorView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 1.0, alpha: 0.14).setFill()
        bounds.fill()
    }
}

private enum TranslationPanelPalette {
    static let targetTitle = NSColor(calibratedWhite: 1.0, alpha: 0.84)
    static let resultText = NSColor(calibratedWhite: 0.94, alpha: 0.96)
    static let resultLink = NSColor(calibratedWhite: 1.0, alpha: 0.82)
    static let actionIconEnabled = NSColor(calibratedWhite: 1.0, alpha: 0.68)
    static let actionIconDisabled = NSColor(calibratedWhite: 1.0, alpha: 0.30)
    static let sourceAction = NSColor(calibratedWhite: 1.0, alpha: 0.70)
}

final class LanguagePickerButton: NSButton {
    static let titleLeadingInset: CGFloat = 8

    private static let horizontalPadding: CGFloat = 8
    private static let chevronGap: CGFloat = 8
    private static let chevronWidth: CGFloat = 10
    private static let chevronHeight: CGFloat = 16
    private static let chevronBackgroundSize: CGFloat = 18

    private let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    private let titleColor = TranslationPanelPalette.targetTitle

    private var hoverTrackingArea: NSTrackingArea?
    private var displayTitle = ""
    private var isHovered = false
    private var isMenuOpen = false
    private var pickerEnabled = true

    var preferredWidth: CGFloat {
        let titleWidth = ceil((displayTitle as NSString).size(withAttributes: [.font: titleFont]).width)
        let affordanceWidth = pickerEnabled ? Self.chevronGap + Self.chevronBackgroundSize : 0
        let paddedWidth = titleWidth + Self.horizontalPadding * 2 + affordanceWidth
        return min(max(paddedWidth, 64), 220)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isBordered = false
        alignment = .left
        focusRingType = .none
        title = ""
        setButtonType(.momentaryChange)
        applyStyle()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        guard pickerEnabled else {
            return
        }

        isHovered = true
        applyStyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyStyle()
    }

    override func draw(_ dirtyRect: NSRect) {
        let title = NSAttributedString(string: displayTitle, attributes: [
            .font: titleFont,
            .foregroundColor: titleColor,
            .kern: 0
        ])
        let titleSize = title.size()
        let titleOrigin = NSPoint(
            x: Self.horizontalPadding,
            y: floor((bounds.height - titleSize.height) / 2) - 1
        )
        title.draw(at: titleOrigin)

        guard pickerEnabled && (isHovered || isMenuOpen || isHighlighted),
              bounds.width > Self.horizontalPadding * 2 + Self.chevronBackgroundSize
        else {
            return
        }

        drawChevronPair()
    }

    private func drawChevronPair() {
        let backgroundRect = NSRect(
            x: bounds.maxX - Self.horizontalPadding - Self.chevronBackgroundSize,
            y: floor((bounds.height - Self.chevronBackgroundSize) / 2),
            width: Self.chevronBackgroundSize,
            height: Self.chevronBackgroundSize
        )
        NSColor(calibratedWhite: 1.0, alpha: 0.11).setFill()
        NSBezierPath(ovalIn: backgroundRect).fill()

        let origin = NSPoint(
            x: backgroundRect.midX - Self.chevronWidth / 2,
            y: floor((bounds.height - Self.chevronHeight) / 2)
        )
        let midX = origin.x + Self.chevronWidth / 2
        let rightX = origin.x + Self.chevronWidth

        NSColor(calibratedWhite: 1.0, alpha: 0.88).setStroke()

        let up = NSBezierPath()
        up.lineWidth = 2.0
        up.lineCapStyle = .round
        up.lineJoinStyle = .round
        up.move(to: NSPoint(x: origin.x + 1, y: origin.y + 10))
        up.line(to: NSPoint(x: midX, y: origin.y + 14))
        up.line(to: NSPoint(x: rightX - 1, y: origin.y + 10))
        up.stroke()

        let down = NSBezierPath()
        down.lineWidth = 2.0
        down.lineCapStyle = .round
        down.lineJoinStyle = .round
        down.move(to: NSPoint(x: origin.x + 1, y: origin.y + 6))
        down.line(to: NSPoint(x: midX, y: origin.y + 2))
        down.line(to: NSPoint(x: rightX - 1, y: origin.y + 6))
        down.stroke()
    }

    func setTitle(_ title: String, pickerEnabled: Bool) {
        displayTitle = title
        self.pickerEnabled = pickerEnabled
        toolTip = pickerEnabled ? "Choose translation language" : nil
        isEnabled = true
        applyStyle()
        needsLayout = true
    }

    func setMenuOpen(_ isMenuOpen: Bool) {
        self.isMenuOpen = isMenuOpen
        applyStyle()
    }

    private func applyStyle() {
        layer?.cornerRadius = 0
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        layer?.borderColor = NSColor.clear.cgColor
        needsDisplay = true
    }
}

final class SourcePreviewView: NSView {
    private static let moreButtonWidth: CGFloat = 50
    private static let moreGap: CGFloat = 8
    private static let sourceTextYOffset: CGFloat = 2
    private static let moreButtonYOffset: CGFloat = 1

    private let textLabel = NSTextField(labelWithString: "")
    private let moreButton = NSButton(title: "more", target: nil, action: nil)
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false
    private var canExpand = false

    var onMore: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        textLabel.font = NSFont.systemFont(ofSize: TranslationContentView.sourceFontSize, weight: .semibold)
        textLabel.textColor = NSColor(calibratedWhite: 1.0, alpha: 0.90)
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.maximumNumberOfLines = 1
        textLabel.usesSingleLineMode = true
        addSubview(textLabel)

        moreButton.target = self
        moreButton.action = #selector(moreTapped)
        moreButton.isBordered = false
        moreButton.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        moreButton.contentTintColor = TranslationPanelPalette.sourceAction
        moreButton.isHidden = true
        moreButton.toolTip = "Show full source"
        addSubview(moreButton)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateMoreVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateMoreVisibility()
    }

    override func layout() {
        super.layout()
        let buttonVisible = !moreButton.isHidden
        let labelWidth = buttonVisible
            ? max(0, bounds.width - Self.moreButtonWidth - Self.moreGap)
            : bounds.width
        let sourceTextHeight = ceil(textLabel.intrinsicContentSize.height)
        let moreButtonHeight = ceil(moreButton.intrinsicContentSize.height)
        let rowHeight = max(sourceTextHeight, moreButtonHeight)
        let rowY = floor((bounds.height - rowHeight) / 2)
        textLabel.frame = NSRect(
            x: 0,
            y: rowY + Self.sourceTextYOffset,
            width: labelWidth,
            height: rowHeight
        )
        moreButton.frame = NSRect(
            x: bounds.maxX - Self.moreButtonWidth,
            y: rowY + Self.moreButtonYOffset,
            width: Self.moreButtonWidth,
            height: rowHeight
        )
    }

    func configure(text: String, canExpand: Bool) {
        textLabel.stringValue = text
        self.canExpand = canExpand
        updateMoreVisibility()
    }

    private func updateMoreVisibility() {
        moreButton.isHidden = !(canExpand && isHovered)
        needsLayout = true
    }

    @objc private func moreTapped() {
        onMore?()
    }
}

final class TranslationContentView: NSView {
    private enum ResultTone {
        case normal
        case error

        var color: NSColor {
            switch self {
            case .normal:
                return TranslationPanelPalette.resultText
            case .error:
                return NSColor(calibratedRed: 1.0, green: 0.48, blue: 0.30, alpha: 0.96)
            }
        }
    }

    static let bodyWidth: CGFloat = 400
    static let preferredWidth: CGFloat = bodyWidth
    private static let minHeight: CGFloat = 168
    private static let maxHeight: CGFloat = 540
    private static let contentWidth: CGFloat = 364
    static let sourceFontSize: CGFloat = 16
    private static let collapsedSourceBoxHeight: CGFloat = 34
    private static let minimumExpandedSourceBoxHeight: CGFloat = 48
    private static let minimumResultBoxHeight: CGFloat = 58
    private static let maximumSourceBoxHeight: CGFloat = 140
    private static let maximumResultBoxHeight: CGFloat = 340

    private static let panelPaddingX: CGFloat = 18
    private static let panelPaddingTop: CGFloat = 20
    private static let panelPaddingBottom: CGFloat = 18
    private static let labelHeight: CGFloat = 18
    private static let labelToBoxGap: CGFloat = 8
    private static let sourceToDividerGap: CGFloat = 13
    private static let dividerToTargetGap: CGFloat = 16
    private static let dividerHeight: CGFloat = 1
    private static let buttonSize: CGFloat = 18
    private static let resultFontSize: CGFloat = 18
    private static let resultParagraphSpacingFactor: CGFloat = 0.35
    private static let textInsetY: CGFloat = 3
    private static let scrollableTextBottomPadding: CGFloat = 18

    var onClose: (() -> Void)?
    var onNeedsResize: (() -> Void)?

    private let sourceText: String
    private var targetLanguage: TranslationLanguage
    private let resultLabel: String?
    private var resultText = "Translating..."
    private var resultDisplayText = "Translating..."
    private var resultTone: ResultTone = .normal
    private let resultTextView = NSTextView()
    private let sourceTitleLabel = NSTextField(labelWithString: "")
    private let sourcePreviewView = SourcePreviewView(frame: .zero)
    private let targetTitleButton = LanguagePickerButton(frame: .zero)
    private let sourceTextView = NSTextView()
    private let sourceScrollView = NSScrollView()
    private let resultScrollView = NSScrollView()
    private let sourceDivider = HairlineSeparatorView()
    private var panelGlass: GlassHostView?
    private var chromeOverlay: GlassChromeOverlayView?
    private var closeButton: NSButton?
    private var copyButton: NSButton?
    private var replaceButton: NSButton?
    private var sourceExpanded = false
    private var shouldScrollSourceToTop = true
    private var shouldScrollResultToTop = true
    private var anchorYValue: CGFloat
    private let onTargetLanguageSelected: ((TranslationLanguage) -> Void)?
    private let onReplace: ((String) -> Void)?
    private var loadingBaseText: String?
    private var loadingTimer: Timer?
    private var loadingDotCount = 0
    private var isInternalLoadingUpdate = false

    var isTargetLanguageMenuOpen = false

    init(
        sourceText: String,
        targetLanguage: TranslationLanguage,
        resultLabel: String? = nil,
        anchorY: CGFloat,
        onTargetLanguageSelected: ((TranslationLanguage) -> Void)? = nil,
        onReplace: ((String) -> Void)? = nil
    ) {
        self.sourceText = sourceText
        self.targetLanguage = targetLanguage
        self.resultLabel = resultLabel
        self.anchorYValue = anchorY
        self.onTargetLanguageSelected = onTargetLanguageSelected
        self.onReplace = onReplace
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: Self.preferredWidth,
            height: Self.preferredHeight(sourceText: sourceText, resultText: "Translating...")
        ))
        wantsLayer = true
        buildUI()
    }

    required init?(coder: NSCoder) {
        nil
    }

    static func preferredHeight(sourceText: String, resultText: String, sourceExpanded: Bool = false) -> CGFloat {
        let sourceBoxHeight = sourceHeight(for: sourceText, expanded: sourceExpanded)
        let resultBoxHeight = boxHeight(
            for: resultText,
            font: NSFont.systemFont(ofSize: resultFontSize, weight: .semibold),
            width: contentWidth,
            minimum: minimumResultBoxHeight,
            maximum: maximumResultBoxHeight,
            paragraphSpacing: resultFontSize * resultParagraphSpacingFactor
        )

        let fixedHeight = panelPaddingTop
            + labelHeight + labelToBoxGap
            + sourceToDividerGap + dividerHeight + dividerToTargetGap
            + labelHeight + labelToBoxGap
            + panelPaddingBottom
        return min(max(fixedHeight + sourceBoxHeight + resultBoxHeight, minHeight), maxHeight)
    }

    func preferredHeightForCurrentContent() -> CGFloat {
        Self.preferredHeight(sourceText: sourceText, resultText: resultDisplayText, sourceExpanded: sourceExpanded)
    }

    static func anchorY(for screenY: CGFloat, panelOriginY: CGFloat, panelHeight: CGFloat) -> CGFloat {
        min(max(screenY - panelOriginY, 0), panelHeight)
    }

    func setAnchorY(_ anchorY: CGFloat) {
        guard abs(anchorYValue - anchorY) >= 0.5 else {
            return
        }
        anchorYValue = anchorY
        layoutForCurrentSize()
    }

    func setTargetLanguage(_ language: TranslationLanguage) {
        guard resultLabel == nil else {
            return
        }

        targetLanguage = language
        targetTitleButton.setTitle(language.displayName, pickerEnabled: true)
        layoutForCurrentSize()
    }

    private func expandSource() {
        guard !sourceExpanded else {
            return
        }

        sourceExpanded = true
        shouldScrollSourceToTop = true
        onNeedsResize?()
        layoutForCurrentSize()
    }

    private static func boxHeight(
        for text: String,
        font: NSFont,
        width: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat,
        paragraphSpacing: CGFloat = 0
    ) -> CGFloat {
        let height = textHeight(for: text, font: font, width: width, paragraphSpacing: paragraphSpacing) + textInsetY * 2 + 4
        return min(max(height, minimum), maximum)
    }

    private static func sourceHeight(for text: String, expanded: Bool) -> CGFloat {
        guard expanded else {
            return collapsedSourceBoxHeight
        }

        return boxHeight(
            for: text,
            font: NSFont.systemFont(ofSize: sourceFontSize, weight: .semibold),
            width: contentWidth,
            minimum: minimumExpandedSourceBoxHeight,
            maximum: maximumSourceBoxHeight
        )
    }

    private static func singleLineWidth(for text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func collapsedSourceText(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func layoutScrollableTextView(
        _ textView: NSTextView,
        inside scrollView: NSScrollView,
        scrollFrame: NSRect,
        rawTextHeight: CGFloat,
        showsOverflowScroller: Bool = true
    ) {
        scrollView.frame = scrollFrame

        let minimumVerticalTextPadding: CGFloat = 4
        let fitsInScrollFrame = rawTextHeight + minimumVerticalTextPadding * 2 <= scrollFrame.height
        let verticalInset: CGFloat
        let textViewHeight: CGFloat
        if fitsInScrollFrame {
            verticalInset = floor(max(2, (scrollFrame.height - rawTextHeight) / 2))
            textViewHeight = scrollFrame.height
        } else {
            verticalInset = minimumVerticalTextPadding
            textViewHeight = max(
                scrollFrame.height + 1,
                rawTextHeight + verticalInset * 2 + scrollableTextBottomPadding
            )
        }

        let scrollerInset: CGFloat = 8
        textView.textContainerInset = NSSize(width: 0, height: verticalInset)
        textView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: scrollFrame.width, height: textViewHeight)
        )
        textView.minSize = NSSize(width: 0, height: scrollFrame.height)
        textView.textContainer?.containerSize = NSSize(
            width: max(0, scrollFrame.width - scrollerInset),
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.hasVerticalScroller = showsOverflowScroller && !fitsInScrollFrame
    }

    private static func textHeight(
        for text: String,
        font: NSFont,
        width: CGFloat,
        paragraphSpacing: CGFloat = 0
    ) -> CGFloat {
        let cleanText = text.isEmpty ? " " : text
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.paragraphSpacing = paragraphSpacing
        let storage = NSTextStorage(string: cleanText, attributes: [
            .font: font,
            .paragraphStyle: paragraph
        ])
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        return ceil(layoutManager.usedRect(for: container).height)
    }

    private static func renderedMarkdownText(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let rendered = (try? AttributedString(markdown: text, options: options))
            .map { NSMutableAttributedString($0) }
            ?? NSMutableAttributedString(string: text)

        guard rendered.length > 0 else {
            return rendered
        }

        let fullRange = NSRange(location: 0, length: rendered.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.paragraphSpacing = font.pointSize * resultParagraphSpacingFactor
        rendered.addAttributes([
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ], range: fullRange)

        var fontRuns: [(NSRange, NSFont)] = []
        rendered.enumerateAttribute(.inlinePresentationIntent, in: fullRange) { value, range, _ in
            guard let intent = (value as? NSNumber)?.intValue else {
                return
            }

            if let styledFont = markdownFont(for: intent, baseFont: font) {
                fontRuns.append((range, styledFont))
            }
        }
        for (range, styledFont) in fontRuns {
            rendered.addAttribute(.font, value: styledFont, range: range)
        }

        var linkRuns: [NSRange] = []
        rendered.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            if value != nil {
                linkRuns.append(range)
            }
        }
        for range in linkRuns {
            rendered.addAttributes([
                .foregroundColor: TranslationPanelPalette.resultLink,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: range)
        }

        return rendered
    }

    private static func markdownFont(for intent: Int, baseFont: NSFont) -> NSFont? {
        let emphasized = 1
        let stronglyEmphasized = 2
        let code = 4

        if intent & code != 0 {
            return NSFont.monospacedSystemFont(ofSize: baseFont.pointSize * 0.94, weight: .regular)
        }

        var font = baseFont
        var changed = false
        if intent & stronglyEmphasized != 0 {
            font = NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold)
            changed = true
        }
        if intent & emphasized != 0 {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            changed = true
        }
        return changed ? font : nil
    }

    private func buildUI() {
        let panelGlass = GlassHostView(
            frame: NSRect(x: 0, y: 0, width: Self.bodyWidth, height: bounds.height),
            cornerRadius: 22,
            tintColor: NSColor(calibratedRed: 0.10, green: 0.095, blue: 0.045, alpha: 0.72),
            style: .regular
        )
        panelGlass.autoresizingMask = [.height]
        addSubview(panelGlass)
        let content = panelGlass.contentView
        self.panelGlass = panelGlass

        configureSectionLabel(
            sourceTitleLabel,
            text: "Source",
            color: NSColor(calibratedWhite: 1.0, alpha: 0.74)
        )
        content.addSubview(sourceTitleLabel)

        closeButton = makeIconButton(
            symbolName: "xmark",
            accessibilityDescription: "Close",
            pointSize: 10,
            target: self,
            action: #selector(closeTapped),
            to: content
        )

        configureScrollView(sourceScrollView)
        configureTextView(
            sourceTextView,
            text: sourceText,
            font: NSFont.systemFont(ofSize: Self.sourceFontSize, weight: .semibold),
            color: NSColor(calibratedWhite: 1.0, alpha: 0.90)
        )
        sourceScrollView.documentView = sourceTextView
        sourceScrollView.isHidden = true
        sourcePreviewView.onMore = { [weak self] in
            self?.expandSource()
        }
        content.addSubview(sourcePreviewView)
        content.addSubview(sourceScrollView)
        content.addSubview(sourceDivider)

        targetTitleButton.target = self
        targetTitleButton.action = #selector(showTargetLanguageMenu)
        targetTitleButton.setTitle(resultLabel ?? targetLanguage.displayName, pickerEnabled: resultLabel == nil)
        content.addSubview(targetTitleButton)

        copyButton = makeIconButton(
            symbolName: "doc.on.doc",
            accessibilityDescription: "Copy translation",
            pointSize: 11,
            target: self,
            action: #selector(copyResult),
            to: content
        )
        copyButton?.contentTintColor = TranslationPanelPalette.actionIconEnabled

        if onReplace != nil {
            let replaceButton = makeIconButton(
                symbolName: "text.insert",
                accessibilityDescription: "Replace selected text",
                pointSize: 12,
                target: self,
                action: #selector(replaceSelectedText),
                to: content
            )
            replaceButton.isEnabled = false
            replaceButton.contentTintColor = TranslationPanelPalette.actionIconDisabled
            self.replaceButton = replaceButton
        }

        configureScrollView(resultScrollView)
        configureTextView(
            resultTextView,
            text: resultText,
            font: NSFont.systemFont(ofSize: Self.resultFontSize, weight: .semibold),
            color: ResultTone.normal.color
        )
        resultScrollView.documentView = resultTextView
        content.addSubview(resultScrollView)

        let chromeOverlay = GlassChromeOverlayView(frame: content.bounds)
        chromeOverlay.autoresizingMask = [.width, .height]
        content.addSubview(chromeOverlay)
        self.chromeOverlay = chromeOverlay

        setResult(resultText)
    }

    private func configureScrollView(_ scrollView: NSScrollView) {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScroller?.knobStyle = .light
        scrollView.borderType = .noBorder
    }

    private func configureTextView(_ textView: NSTextView, text: String, font: NSFont, color: NSColor) {
        textView.string = text
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.textColor = color
        textView.font = font
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 0, height: 2)
    }

    @discardableResult
    private func makeIconButton(
        symbolName: String,
        accessibilityDescription: String,
        pointSize: CGFloat,
        target: AnyObject,
        action: Selector,
        to parent: NSView
    ) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription) ?? NSImage()
        let image = baseImage.withSymbolConfiguration(config) ?? baseImage
        let button = FirstMouseButton(image: image, target: target, action: action)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = NSColor(calibratedWhite: 1.0, alpha: 0.55)
        button.toolTip = accessibilityDescription
        parent.addSubview(button)
        return button
    }

    private func configureSectionLabel(_ label: NSTextField, text: String, color: NSColor) {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: color,
            .kern: 0
        ])
        label.attributedStringValue = attributed
    }

    func layoutForCurrentSize() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let bodyHeight = bounds.height
        panelGlass?.frame = NSRect(
            x: 0,
            y: 0,
            width: Self.bodyWidth,
            height: bodyHeight
        )
        chromeOverlay?.frame = NSRect(x: 0, y: 0, width: Self.bodyWidth, height: bodyHeight)

        let sourceBoxHeight = Self.sourceHeight(for: sourceText, expanded: sourceExpanded)
        let fixedHeight = Self.panelPaddingTop
            + Self.labelHeight + Self.labelToBoxGap
            + Self.sourceToDividerGap + Self.dividerHeight + Self.dividerToTargetGap
            + Self.labelHeight + Self.labelToBoxGap
            + Self.panelPaddingBottom
        let availableBoxHeight = max(
            Self.collapsedSourceBoxHeight + Self.minimumResultBoxHeight,
            bounds.height - fixedHeight
        )
        let resolvedSourceBoxHeight = min(
            sourceBoxHeight,
            max(Self.collapsedSourceBoxHeight, availableBoxHeight - Self.minimumResultBoxHeight)
        )
        let resolvedResultBoxHeight = max(Self.minimumResultBoxHeight, availableBoxHeight - resolvedSourceBoxHeight)

        var y = bodyHeight - Self.panelPaddingTop - Self.labelHeight
        sourceTitleLabel.frame = NSRect(
            x: Self.panelPaddingX,
            y: y,
            width: Self.contentWidth - Self.buttonSize - 8,
            height: Self.labelHeight
        )
        closeButton?.frame = NSRect(
            x: Self.bodyWidth - Self.panelPaddingX - Self.buttonSize,
            y: y + (Self.labelHeight - Self.buttonSize) / 2,
            width: Self.buttonSize,
            height: Self.buttonSize
        )

        y -= Self.labelToBoxGap + resolvedSourceBoxHeight
        let sourceScrollFrame = NSRect(
            x: Self.panelPaddingX,
            y: y,
            width: Self.contentWidth,
            height: resolvedSourceBoxHeight
        )
        let collapsedSourceText = Self.collapsedSourceText(sourceText)
        let sourceCanExpand = Self.singleLineWidth(
            for: collapsedSourceText,
            font: NSFont.systemFont(ofSize: Self.sourceFontSize, weight: .semibold)
        ) > Self.contentWidth
            || collapsedSourceText != sourceText.trimmingCharacters(in: .whitespacesAndNewlines)

        sourcePreviewView.frame = sourceScrollFrame
        sourcePreviewView.configure(text: collapsedSourceText, canExpand: sourceCanExpand)
        sourcePreviewView.isHidden = sourceExpanded
        sourceScrollView.isHidden = !sourceExpanded

        if sourceExpanded {
            let sourceRawTextHeight = Self.textHeight(
                for: sourceText,
                font: NSFont.systemFont(ofSize: Self.sourceFontSize, weight: .semibold),
                width: sourceScrollFrame.width
            )
            Self.layoutScrollableTextView(
                sourceTextView,
                inside: sourceScrollView,
                scrollFrame: sourceScrollFrame,
                rawTextHeight: sourceRawTextHeight,
                showsOverflowScroller: true
            )
            if shouldScrollSourceToTop {
                scrollToTop(sourceScrollView)
                shouldScrollSourceToTop = false
            }
        }

        y -= Self.sourceToDividerGap + Self.dividerHeight
        sourceDivider.frame = NSRect(
            x: Self.panelPaddingX,
            y: y,
            width: Self.contentWidth,
            height: Self.dividerHeight
        )

        y -= Self.dividerToTargetGap + Self.labelHeight
        let targetActionButtonCount = replaceButton == nil ? 1 : 2
        let targetActionWidth = CGFloat(targetActionButtonCount) * Self.buttonSize
            + CGFloat(max(0, targetActionButtonCount - 1)) * 8
        let targetTitleLeadingInset = LanguagePickerButton.titleLeadingInset
        targetTitleButton.frame = NSRect(
            x: Self.panelPaddingX - targetTitleLeadingInset,
            y: y + (Self.labelHeight - Self.buttonSize) / 2,
            width: min(
                targetTitleButton.preferredWidth,
                Self.contentWidth - targetActionWidth - 8 + targetTitleLeadingInset
            ),
            height: Self.buttonSize
        )
        copyButton?.frame = NSRect(
            x: Self.bodyWidth - Self.panelPaddingX - Self.buttonSize,
            y: y + (Self.labelHeight - Self.buttonSize) / 2,
            width: Self.buttonSize,
            height: Self.buttonSize
        )
        replaceButton?.frame = NSRect(
            x: Self.bodyWidth - Self.panelPaddingX - Self.buttonSize * 2 - 8,
            y: y + (Self.labelHeight - Self.buttonSize) / 2,
            width: Self.buttonSize,
            height: Self.buttonSize
        )

        y -= Self.labelToBoxGap + resolvedResultBoxHeight
        let resultScrollFrame = NSRect(
            x: Self.panelPaddingX,
            y: y,
            width: Self.contentWidth,
            height: resolvedResultBoxHeight
        )
        let resultRawTextHeight = Self.textHeight(
            for: resultDisplayText,
            font: NSFont.systemFont(ofSize: Self.resultFontSize, weight: .semibold),
            width: resultScrollFrame.width,
            paragraphSpacing: Self.resultFontSize * Self.resultParagraphSpacingFactor
        )
        Self.layoutScrollableTextView(
            resultTextView,
            inside: resultScrollView,
            scrollFrame: resultScrollFrame,
            rawTextHeight: resultRawTextHeight
        )
        if shouldScrollResultToTop {
            scrollToTop(resultScrollView)
            shouldScrollResultToTop = false
        }
    }

    func setResult(_ text: String) {
        setResult(text, tone: .normal)
    }

    func setError(_ text: String) {
        setResult(text, tone: .error)
    }

    private func setResult(_ text: String, tone: ResultTone) {
        if !isInternalLoadingUpdate {
            stopLoadingAnimation()
        }
        let cleanedText = TextNormalizer.cleanedTranslation(text)

        if cleanedText == resultText, tone == resultTone {
            return
        }

        if !cleanedText.hasPrefix(resultText) || tone != resultTone {
            shouldScrollResultToTop = true
        }

        resultTone = tone
        resultTextView.textColor = tone.color
        let renderedText = Self.renderedMarkdownText(
            cleanedText,
            font: resultTextView.font ?? NSFont.systemFont(ofSize: Self.resultFontSize, weight: .regular),
            color: tone.color
        )
        if let textStorage = resultTextView.textStorage {
            textStorage.setAttributedString(renderedText)
        } else {
            resultTextView.string = renderedText.string
        }

        resultText = cleanedText
        resultDisplayText = resultTextView.string
        updateActionButtonStates()
        layoutForCurrentSize()
    }

    func startLoadingAnimation(baseText: String) {
        stopLoadingAnimation()
        loadingBaseText = baseText
        loadingDotCount = 0
        renderLoadingFrame()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickLoadingAnimation() }
        }
        loadingTimer = timer
    }

    func stopLoadingAnimation() {
        loadingTimer?.invalidate()
        loadingTimer = nil
        loadingBaseText = nil
    }

    var isShowingLoadingState: Bool { loadingBaseText != nil }

    private func tickLoadingAnimation() {
        guard loadingBaseText != nil else { return }
        loadingDotCount = (loadingDotCount + 1) % 4
        renderLoadingFrame()
    }

    private func renderLoadingFrame() {
        guard let baseText = loadingBaseText else { return }
        let dots = String(repeating: ".", count: loadingDotCount)
        isInternalLoadingUpdate = true
        setResult("\(baseText)\(dots)")
        isInternalLoadingUpdate = false
    }

    private func scrollToTop(_ scrollView: NSScrollView) {
        guard let documentView = scrollView.documentView else {
            return
        }

        let clipView = scrollView.contentView
        let y = documentView.isFlipped
            ? CGFloat.zero
            : max(0, documentView.bounds.height - clipView.bounds.height)
        clipView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clipView)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutForCurrentSize()
    }

    @objc private func showTargetLanguageMenu() {
        guard resultLabel == nil else {
            return
        }

        let menu = NSMenu()
        for language in TranslationLanguage.all {
            let item = NSMenuItem(
                title: language.displayName,
                action: #selector(selectTemporaryTargetLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = language.id
            item.state = language.id == targetLanguage.id ? .on : .off
            menu.addItem(item)
        }

        isTargetLanguageMenuOpen = true
        targetTitleButton.setMenuOpen(true)
        _ = menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: -4),
            in: targetTitleButton
        )
        targetTitleButton.setMenuOpen(false)
        isTargetLanguageMenuOpen = false
    }

    @objc private func selectTemporaryTargetLanguage(_ sender: NSMenuItem) {
        guard let languageID = sender.representedObject as? String else {
            return
        }

        let language = TranslationLanguage.language(id: languageID)
        guard language != targetLanguage else {
            return
        }

        setTargetLanguage(language)
        onTargetLanguageSelected?(language)
    }

    @objc private func copyResult() {
        copyResultToPasteboard()
        onClose?()
    }

    func copyResultToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultTextView.string, forType: .string)
    }

    @objc private func replaceSelectedText() {
        let replacement = TextNormalizer.cleanedTranslation(resultTextView.string)
        guard !replacement.isEmpty,
              !isShowingLoadingState,
              resultTone != .error
        else {
            return
        }

        onReplace?(replacement)
    }

    func triggerReplaceProgrammatically() {
        replaceSelectedText()
    }

    @objc private func closeTapped() {
        onClose?()
    }

    private func updateActionButtonStates() {
        let result = TextNormalizer.cleanedTranslation(resultTextView.string)
        let canUseResult = !result.isEmpty
            && !isShowingLoadingState
            && resultTone != .error

        copyButton?.isEnabled = canUseResult
        copyButton?.contentTintColor = canUseResult
            ? TranslationPanelPalette.actionIconEnabled
            : TranslationPanelPalette.actionIconDisabled

        guard let replaceButton else {
            return
        }
        replaceButton.isEnabled = canUseResult
        replaceButton.contentTintColor = canUseResult
            ? TranslationPanelPalette.actionIconEnabled
            : TranslationPanelPalette.actionIconDisabled
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

enum TranslationMode {
    case selection
    case draftMessage
    case smartReply

    var usesCompositionSettings: Bool {
        switch self {
        case .selection:
            return false
        case .draftMessage, .smartReply:
            return true
        }
    }

    var resultLabel: String? {
        switch self {
        case .selection, .draftMessage:
            return nil
        case .smartReply:
            return "Reply"
        }
    }

    var loadingPlaceholder: String {
        switch self {
        case .smartReply:
            return "Thinking"
        case .draftMessage:
            return "Rewriting"
        case .selection:
            return "Translating"
        }
    }

    func systemPrompt(
        targetLanguage: TranslationLanguage,
        appCategory: AppCategory,
        composition: CompositionSettings?
    ) -> String {
        switch self {
        case .selection:
            """
            Translate the user's text into plain, accessible \(targetLanguage.promptName) aimed at a curious ~12-year-old reader with no background in the field — accessible, but not babyish or condescending. The goal is to make the content understandable, not to produce a literal word-for-word rendering. This applies whether the source is already in \(targetLanguage.promptName), in another language entirely, or a mix of both.

            Render any foreign-language parts into \(targetLanguage.promptName), then simplify the whole result: break long sentences into shorter ones, replace jargon and rare or technical vocabulary with plain everyday words, unwind passive voice and nested clauses, and prefer concrete wording over abstract phrasing. Where a concept stays abstract after a plain-word swap, anchor it inline with a short concrete example or everyday analogy in parentheses or em-dashes — e.g. "a queue (like the line at a coffee shop — first in, first served)".

            Match output complexity to source complexity. If the source is already a casual, simple message — a chat line, a greeting, a short sentence with no jargon, a menu item, a button label — translate it plainly and stop. Do not force analogies, examples, or expansions onto content that is already simple. The simplification rules are for when there is something genuinely complex to make accessible; short, plain inputs get short, plain outputs. (A single standalone word or term that the user is looking up is the exception — see the Lookup case below.)

            Lookup case — if the source is a single word or a short standalone term (not a sentence, greeting, or casual phrase) and rendering it into \(targetLanguage.promptName) would leave it essentially unchanged — because it is already in \(targetLanguage.promptName), or is a borrowed or technical term with no distinct \(targetLanguage.promptName) translation — then the user has selected it to understand what it means, not to translate it. Do not echo the word back unchanged. Instead, explain it in 1–2 short, plain \(targetLanguage.promptName) sentences: what it means in everyday words, and a quick concrete example if it helps. Keep it simple enough for a curious ~12-year-old. If the word has several common meanings, give the most everyday one first and you may note a field-specific sense in a few words. Do not add a dictionary header, the word itself as a title, pronunciation, or part-of-speech labels — just the plain explanation.

            Treat a single `\\n` as a wrapped line inside one paragraph — join it silently. Treat a blank line (`\\n\\n`) as a deliberate paragraph break that the user wants to keep — render it as a blank line in the output. Clean repeated spaces, OCR artifacts, and hyphenated line wraps. If the source has no paragraph breaks but is long or dense, split the output into readable paragraphs instead of returning one wall of text.

            Keep every fact, name, date, number, quotation, URL, proper noun, and the original paragraph/bullet/list structure exactly. Do not summarize, do not drop content, do not add new claims, opinions, or facts — examples and analogies must only illustrate what is already there, never extend it. If your output differs from a literal translation only by swapping a few synonyms (e.g. "specialized" → "special", "utilize" → "use") or replacing punctuation, you have not simplified — go further: add an illustrative example, restructure the sentence, or name the topic in plainer terms.

            Context — the source text is from \(appCategory.promptHint)\(TranslationMode.genZSection(for: targetLanguage.id, enabled: composition?.genZ ?? false))

            Return only the \(targetLanguage.promptName) output. No preamble, no commentary, no quotes around the output. Never write a wrapper like "Here is the translation:" — output the text directly.
            """
        case .draftMessage:
            if composition?.cleanup == CleanupLevel.none {
                """
                Translate the user's drafted outgoing message into \(targetLanguage.promptName). Preserve the user's phrasing, sentence structure, and word choices as faithfully as the target language allows — even if the result reads slightly stiff or non-idiomatic. Do not polish, smooth, naturalize, or rewrite the draft beyond what literal translation strictly requires. If the draft is already entirely in \(targetLanguage.promptName), return it essentially unchanged; correct only outright errors. If only part of the draft is in \(targetLanguage.promptName) and the rest is in one or more other languages, translate the foreign parts literally into \(targetLanguage.promptName) and keep the \(targetLanguage.promptName) parts verbatim — do not rephrase or re-translate them. Stitch the result into one coherent message, but do not naturalize beyond what is needed to make it grammatical.

                The selected Writing style controls register, honorifics, and formality — apply it for those purposes only, not as a license to rephrase or stylize. Preserve verbatim: emojis, URLs, usernames, product names, numbers, line breaks. If the draft is a fragment, translate the fragment as-is without inventing extra context.

                Emoji shorthand — replace `[X emoji]` patterns with the matching Unicode emoji (`[smile emoji]` → 😊, `[fire emoji]` → 🔥, `[thumbs up emoji]` → 👍, `[crying emoji]` → 😭). Pick the most common, neutral variant when several emojis fit the description. Only expand when the bracketed content reads as an emoji description — leave bracketed dates, citations, code, placeholders, and other non-emoji content untouched (e.g. `[2025-01-01]`, `[1]`, `[redacted]`, `[insert name]` stay as-is).

                Context — the user is composing this message in \(appCategory.promptHint)

                Writing style — \(composition?.style.promptDescription(for: targetLanguage.id) ?? "")\(TranslationMode.genZSection(for: targetLanguage.id, enabled: composition?.genZ ?? false))\(TranslationMode.voiceSampleSection(for: composition?.voiceSample))\(TranslationMode.glossarySection(for: composition?.snippets ?? [], includeSnippets: true))

                Return only the final \(targetLanguage.promptName) message, with no commentary, labels, alternatives, quotes, or explanations.
                """
            } else {
                """
                Translate the user's drafted outgoing message into natural \(targetLanguage.promptName). Infer the user's actual intent, emotion, and social situation, then say it the way a native \(targetLanguage.promptName) speaker would send it in a chat or message. If the draft is already entirely in \(targetLanguage.promptName), do not translate it; lightly rewrite/polish it only when needed so it sounds natural and sendable. If only part of the draft is in \(targetLanguage.promptName) and the rest is in one or more other languages, translate the foreign parts into \(targetLanguage.promptName) and weave everything into one cohesive, natural-sounding message — keep the \(targetLanguage.promptName) portions intact unless they need light polish to flow with the rest. Treat code-switching as the user reaching for words they didn't know in \(targetLanguage.promptName), not as a stylistic choice to preserve.

                The selected Writing style is authoritative. The source draft tells you meaning, intent, emotion, and how direct the user wants to be, but it must not override the selected Writing style. When goals conflict, follow this priority: (1) meaning, (2) selected Writing style, (3) intended directness and emotional signal within that style, (4) cultural naturalness — idioms, honorifics, word order, (5) surface details to preserve verbatim — emojis, URLs, usernames, product names, numbers, line breaks, (6) literal wording (always lowest). If the draft is blunt, keep the result concise and direct, but still use the selected Writing style. Do not pad a curt one-liner into a long paragraph unless the meaning requires it. If the draft is awkward or phrased like a direct translation, smooth it while keeping the same intent. If the draft is a fragment, return a natural sendable fragment without inventing extra context.

                Emoji shorthand — replace `[X emoji]` patterns with the matching Unicode emoji (`[smile emoji]` → 😊, `[fire emoji]` → 🔥, `[thumbs up emoji]` → 👍, `[crying emoji]` → 😭). Pick the most common, neutral variant when several emojis fit the description. Only expand when the bracketed content reads as an emoji description — leave bracketed dates, citations, code, placeholders, and other non-emoji content untouched (e.g. `[2025-01-01]`, `[1]`, `[redacted]`, `[insert name]` stay as-is).

                Context — the user is composing this message in \(appCategory.promptHint)

                Writing style — \(composition?.style.promptDescription(for: targetLanguage.id) ?? "")\(TranslationMode.genZSection(for: targetLanguage.id, enabled: composition?.genZ ?? false))\(TranslationMode.voiceSampleSection(for: composition?.voiceSample))

                Cleanup — \(composition?.cleanup.promptDescription ?? "")\(TranslationMode.glossarySection(for: composition?.snippets ?? [], includeSnippets: true))

                Return only the final \(targetLanguage.promptName) message, with no commentary, labels, alternatives, quotes, or explanations.
                """
            }
        case .smartReply:
            """
            The user has selected text in another app. The text is either (a) a message they received — email, chat message, DM, comment, support ticket, or similar; or (b) a question they need to answer — a quiz item, exam question, multiple-choice question, or open question. Decide which it is from the text itself, then respond appropriately. Write your reply or answer in \(targetLanguage.promptName), regardless of what language the source text is in.

            If it is a received message: write a natural, ready-to-send reply as if the user is sending it now. Match the intent, emotional signal, and approximate length of the original, but use the selected Writing style below for register and formality. Be concise. Don't restate or quote the original. Don't add greetings or sign-offs unless the original suggests them. Don't address the user — produce only the message body they would paste into the reply field.

            If it is a multiple-choice question: identify the correct option and respond with the option letter or number followed by the option text, then a brief one-sentence justification. Example: "B. Mitochondria — they generate most of the cell's ATP."

            If it is an open question: give a clear, direct answer. Keep it short unless the question demands depth.

            Context — the user is replying inside \(appCategory.promptHint)

            Writing style — \(composition?.style.promptDescription(for: targetLanguage.id) ?? "")\(TranslationMode.genZSection(for: targetLanguage.id, enabled: composition?.genZ ?? false))\(TranslationMode.voiceSampleSection(for: composition?.voiceSample))

            Cleanup — \(composition?.cleanup.promptDescription ?? "")\(TranslationMode.glossarySection(for: composition?.snippets ?? [], includeSnippets: true))

            Return only the reply or answer text. No commentary, no labels, no preface, no explanation of what you're doing, no quotes around the answer.
            """
        }
    }

    private static func glossarySection(for snippets: [Snippet], includeSnippets: Bool) -> String {
        let usable = snippets.filter(\.isUsable)
        guard !usable.isEmpty else { return "" }

        let expansions = includeSnippets ? usable.filter { $0.kind == .snippet } : []
        let dictionaryTerms = usable.filter { $0.kind == .dictionaryTerm }
        guard !expansions.isEmpty || !dictionaryTerms.isEmpty else { return "" }

        var sections: [String] = []
        sections.append(#"Glossary — apply these user-saved rules exactly when relevant."#)

        if !expansions.isEmpty {
            let lines = expansions.map { snippet -> String in
                let trigger = promptLine(snippet.trigger)
                let value = promptLine(snippet.value)
                return "- \"\(trigger)\" → \(value)"
            }
            sections.append("Snippets — expand BEFORE rewriting for tone/style. After expansion, treat the expanded text as canonical and do not paraphrase it:\n" + lines.joined(separator: "\n"))
        }

        if !dictionaryTerms.isEmpty {
            let lines = dictionaryTerms.map { "- \(promptLine($0.trigger))" }
            sections.append("Dictionary — preserve these terms verbatim. Never translate, paraphrase, or alter spelling/capitalization:\n" + lines.joined(separator: "\n"))
        }

        return "\n\n" + sections.joined(separator: "\n\n")
    }

    /// Language-specific Gen Z styling block, appended to compose prompts when
    /// the Gen Z toggle is on. Empty string when off (so callsites stay inline).
    private static func genZSection(for languageID: String, enabled: Bool) -> String {
        guard enabled else { return "" }
        return "\n\n" + GenZStyle.promptSection(for: languageID)
    }

    /// The user's email voice sample as a template block. Empty string when
    /// there's no sample (so callsites stay inline). `compositionSettings` only
    /// populates `voiceSample` for the email category, so this is a no-op
    /// everywhere else.
    ///
    /// Division of authority (resolves the sample-vs-Writing-style conflict):
    /// the sample owns STRUCTURE (that there's a greeting, a sign-off carrying the
    /// name, the rhythm) and overrides the draft prompt's chat-style brevity; the
    /// Writing style pill owns REGISTER (formality), overriding the sample's own
    /// formality line by line — so a casual register yields a casual greeting and
    /// sign-off even when the sample is written formally.
    private static func voiceSampleSection(for sample: String?) -> String {
        let trimmed = sample?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "" }
        let instruction = "Voice sample — the example below is the user's own email template. Take its STRUCTURE from it: that the email opens with a greeting, closes with a sign-off carrying the user's name, plus its general rhythm and layout. This structure OVERRIDES any length-matching or brevity guidance above — always produce the full greeting + body + sign-off, even when the user's draft is a single short line or fragment; expand a terse draft into a complete email. The selected Writing style register, however, controls the FORMALITY of every line: render the greeting, body, and sign-off at that register even if the template itself is written more or less formally — e.g. if the register is casual, the greeting and sign-off become casual too, not the formal wording shown in the template. Write the body to convey the current draft's meaning; do not reuse the template's body text. Render everything in the target language. Reproduce the user's name in the signature exactly as written:"
        return "\n\n" + instruction + "\n" + trimmed
    }

    private static func promptLine(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum AppCategory: String, CaseIterable, Codable {
    case personalMessages
    case workMessages
    case email
    case other

    var displayName: String {
        switch self {
        case .personalMessages: return "Personal messages"
        case .workMessages: return "Work messages"
        case .email: return "Email"
        case .other: return "Other"
        }
    }

    var promptHint: String {
        switch self {
        case .personalMessages:
            return "a personal messaging app — chats with friends, family, partner, or close contacts. Short fragments are common, but the writing style setting decides the register."
        case .workMessages:
            return "a workplace messaging app — Slack, Teams, LinkedIn. Colleagues and clients. Conversational but professional; complete thoughts but not stiff."
        case .email:
            return "an email client. Longer-form medium where greetings, full sentences, and sign-offs are normal."
        case .other:
            return "an unspecified app. No strong medium expectation — defer to the user's chosen style."
        }
    }
}

enum WritingStyle: String, CaseIterable, Codable {
    case formal
    case polite
    case casual

    var displayName: String {
        switch self {
        case .formal: return "Formal"
        case .polite: return "Polite"
        case .casual: return "Casual"
        }
    }

    /// Language-neutral description of the register. The per-language
    /// grammatical realization is appended by `promptDescription(for:)`.
    private var registerSummary: String {
        switch self {
        case .formal:
            return "highest formal register — the way you'd write to a senior client, superior, or in a business letter. No exclamation marks unless the source had them. This register overrides any informality implied by the app context."
        case .polite:
            return "polite, friendly register — the way you'd write to a colleague, acquaintance, or in a warm but professional message. This register overrides any informality implied by the app context."
        case .casual:
            return "casual register — the way you'd write to a close friend. Lighter punctuation — periods optional at the ends of short messages. Conversational rhythm."
        }
    }

    /// Per-language grammatical realization of each register, keyed by
    /// `TranslationLanguage.id`. The output language is always known at
    /// prompt-build time, so only the matching language's rule is injected —
    /// keeping the prompt lean. Add a language = add one line per style; a
    /// language absent here falls back to `registerSummary` alone.
    private static let languageRules: [WritingStyle: [String: String]] = [
        .formal: [
            "en": "In English: full sentences, no contractions, deferential tone.",
            "ko": "In Korean: use 합쇼체 (-습니다 / -십시오), never 해요체 and never 반말.",
            "ja": "In Japanese: use です/ます with deferential phrasing.",
            "ru": "In Russian: use Вы with full formal constructions.",
            "de": "In German: use Siezen (Sie/Ihnen) with formal salutations and closings; full sentences, no slangy contractions.",
            "fr": "In French: use vouvoiement (vous) with formal phrasing and closings (e.g. « Je vous prie d'agréer »).",
            "es": "In Spanish: use usted with deferential phrasing and complete sentences.",
            "zh-Hans": "In Chinese: use 您 with respectful set phrases (请, 麻烦您, 敬请) and no slang.",
        ],
        .polite: [
            "en": "In English: complete sentences, contractions OK, warm but professional.",
            "ko": "In Korean: use 해요체 (-아요 / -어요 / -해요), not 합쇼체 and not 반말.",
            "ja": "In Japanese: use です/ます in their everyday softer form.",
            "ru": "In Russian: use Вы with conversational warmth.",
            "de": "In German: use Sie in a warm, friendly tone — still Siezen, but conversational, not stiff.",
            "fr": "In French: use vous in a warm, friendly tone — polite but approachable.",
            "es": "In Spanish: use usted in a warm, friendly tone (or tú where the context is clearly informal).",
            "zh-Hans": "In Chinese: use 您 or 你 with a warm, polite tone and 请 where natural.",
        ],
        .casual: [
            "en": "In English: natural casual capitalization (still capitalize names and sentence starts).",
            "ko": "In Korean: use 반말 (-해, -야, -지), never 해요체 and never 합쇼체.",
            "ja": "In Japanese: use plain form (だ/する).",
            "ru": "In Russian: use ты-forms.",
            "de": "In German: use Duzen (du/dir) with relaxed phrasing and everyday contractions (geht's, hab's).",
            "fr": "In French: use tutoiement (tu) with relaxed everyday phrasing and common contractions (t'as, j'sais).",
            "es": "In Spanish: use tú (or vos where regionally natural), relaxed and conversational.",
            "zh-Hans": "In Chinese: use 你 with relaxed, conversational phrasing and everyday particles (啊, 吧, 呢).",
        ],
    ]

    /// Register description tailored to one target language: the neutral
    /// summary plus that language's specific rule when one exists.
    func promptDescription(for languageID: String) -> String {
        guard let rule = WritingStyle.languageRules[self]?[languageID] else {
            return registerSummary
        }
        return "\(registerSummary) \(rule)"
    }

    /// The style currently in effect for `category`, honoring the user's saved
    /// per-category choice and falling back to the category default.
    static func resolved(for category: AppCategory) -> WritingStyle {
        let key = "writingStyle.\(category.rawValue)"
        if let raw = UserDefaults.standard.string(forKey: key),
           let style = WritingStyle(rawValue: raw) {
            return style
        }
        return category.defaultWritingStyle
    }
}

extension AppCategory {
    /// Default register when the user hasn't picked one for this category.
    var defaultWritingStyle: WritingStyle {
        switch self {
        case .personalMessages: return .casual
        case .workMessages, .other: return .polite
        case .email: return .formal
        }
    }
}

enum CleanupLevel: String, CaseIterable, Codable {
    case none
    case light
    case medium
    case high

    var displayName: String {
        switch self {
        case .none: return "None"
        case .light: return "Light"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var promptDescription: String {
        switch self {
        case .none:
            return "do not polish wording — preserve the source phrasing as faithfully as the target language allows."
        case .light:
            return "fix obvious typos, grammar errors, OCR/line-break artifacts. Do not rewrite for style."
        case .medium:
            return "edit lightly for clarity and flow — fix typos and awkward phrasing, but do not rephrase aggressively."
        case .high:
            return "polish thoroughly for brevity and clarity. Tighten verbose sentences, drop filler words, keep meaning intact."
        }
    }
}

/// Gen Z styling overlay for compose prompts. Activated by the global Gen Z
/// toggle (`CompositionSettings.genZ`). The language-neutral `coreGuidance`
/// always leads — its load-bearing instruction is RESTRAINT (1–2 slang markers
/// max) — followed by one target language's native-youth-slang block.
///
/// Synthesized from 2024–2026 per-language research. Slang churns fast, so each
/// block favors the durable signal (lowercase, dropped end-period, 💀/😭 over 😂,
/// tone) over fleeting vocabulary, and flags terms that already read as cringe.
enum GenZStyle {
    /// UserDefaults key for the global Gen Z toggle — single source of truth.
    static let defaultsKey = "genZMode"
    /// Current state of the global Gen Z toggle. Read wherever the prompt is
    /// assembled (delegate-owned compose path and the Ask client classes alike).
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    static let coreGuidance = """
        Gen Z mode is ON. Rewrite the message the way a Gen Z native (born ~1997–2012) would actually text it to a friend — casual digital register, not formal writing.
        CRITICAL — preserve the user's real meaning, intent, and information exactly. Change only the voice and styling, never what they are saying, and never invent new content.
        The #1 rule is restraint: real Gen Z texts are mostly plain language with at most 1–2 slang markers. Piling on slang is the single biggest tell of an adult faking it, so under-dose rather than over-dose; when unsure, drop the slang and keep only the styling.
        Default to all-lowercase. Drop the period at the end of a message (a trailing period reads cold or passive-aggressive). Keep it short.
        Tone skews ironic, understated, deadpan, hyperbolic-for-jokes, and lightly self-deprecating — never earnest, peppy, or corporate.
        Use the target language's OWN native youth slang below — never translate English slang word-for-word into the target language.
        Still respect the selected register/honorific level (e.g. politeness or formality) while adding the Gen Z flavor.
        """

    static let languageGuidance: [String: String] = [
        "en": enGuide, "ru": ruGuide, "ko": koGuide, "ja": jaGuide,
        "zh-Hans": zhGuide, "es": esGuide, "fr": frGuide, "de": deGuide,
    ]

    /// Core rules plus the target language's specifics (core alone if the
    /// language has no dedicated block).
    static func promptSection(for languageID: String) -> String {
        guard let lang = languageGuidance[languageID] else { return coreGuidance }
        return "\(coreGuidance)\n\n\(lang)"
    }

    private static let enGuide = """
        English (US / global internet). All-lowercase; abbreviate freely: fr (for real), ngl, istg, idk, rn, tbh, lowkey/highkey, ong, deadass, iykyk, atp. Laughter is 💀 or 😭 or 'lmao' — never 😂 (a millennial tell).
        Current vocab: rizz (charm), no cap (no lie), it's giving X (gives off X), ate / understood the assignment (nailed it), cooked (doomed), mid (mediocre), crash out (lose it), delulu (delusional), bet (ok/deal), fire/bussin (great), 'that's so real' (agreement), aura (cool points).
        Cringe — avoid: skibidi, gyatt, sigma, Ohio, rizzler (Gen-Alpha brainrot); and millennial fossils: slay (overused), bae, on fleek, adulting, yas.
        Examples:
        - 'I'm really excited, this is going to be great' → 'ngl im so hyped this is gonna be fire'
        - 'Sorry, I can't make it tonight, I'm exhausted' → 'cant make it tn im so cooked sorry'
        """

    private static let ruGuide = """
        Russian. All-lowercase, no end-period, short fragments; heavy transliterated anglicisms. Laughter: ор / ору / орнул, ахах, пхпх — not 😂. Emoji sparse and ironic: 💀 🥲 🗿.
        Current vocab: база (facts/agreed), вайб (vibe), имба (op/awesome), рофл / рофлить (joke), окак (ironic 'oh wow'), чел (dude), го (let's go), жиза (relatable, postironic), делулу (delusional), скуф (unkempt older guy), слэй (nailed it).
        Tone: deadpan, postironic, understated. Don't overdo краш / кринж / чилить / флексить (now read slightly dated / adult).
        Examples:
        - 'Фильм очень понравился, советую посмотреть' → 'фильм имба реально советую'
        - 'Согласен, ты абсолютно прав' → 'база'
        """

    private static let koGuide = """
        Korean. Lean on 초성체: ㅋㅋㅋ (laugh; more ㅋ = funnier), ㅎㅎ (soft), ㅇㅇ (yes), ㄴㄴ (no), ㅇㅋ (ok), ㄱㄱ (go), ㄱㅅ (thanks), ㅈㅅ (sorry), ㄹㅇ (for real), ㅇㅈ (agreed), ㅁㅊ (omg). Cry with ㅠㅠ / ㅜㅜ. Clip words, drop spacing, use 음슴체 endings (먹음, 웃김, 가는중). Intensify with 개- / 존- / 핵- (개웃김, 존좋).
        Current vocab: 갓생 (grind-life), 찐 (genuine), 폼 미쳤다 (killing it), 현타 (reality crash), 꾸안꾸 (effortless style). Avoid dated: 어쩔티비, 존맛탱/JMT.
        Honorifics: if the input is 해요체, soften with ㅎㅎ / ~용 rather than dropping fully to 반말.
        Examples:
        - '오늘 정말 피곤해, 집에 가서 쉬고 싶어' → '오늘 진짜 개피곤 ㅠㅠ 집가서 눕고싶음'
        - '미안한데 약속에 좀 늦을 것 같아' → 'ㅈㅅㅈㅅ 나 좀 늦을듯 ㅠㅠ'
        """

    private static let jaGuide = """
        Japanese. Short fragments, タメ口, no 「。」 (reads cold). Drop particles (これヤバい). Laughter: 草 / w / wwww (more w = harder). 語尾: clip and stretch (しんど〜, きまず〜), nominalize with 〜み (つらみ, やばみ), 〜すぎ / 〜すぎる. Truncate: りょ→り (ok), とりま (anyway).
        Current vocab: それな (totally), ガチ / ガチで (for real), えぐい (insane), エモい (moving), ワンチャン (maybe), 知らんけど (…idk though — deadpan hedge), 神 (awesome), 推し. Avoid dead slang: ぴえん / ぱおん, マジ卍, あざまる, なう, タピる. Minimal emoji.
        Examples:
        - '今日は疲れたので早く寝ます' → '今日まじ疲れたわ〜もう寝る'
        - 'すごく助かりました、ありがとう' → 'まじ助かった〜ありがと🙏'
        """

    private static let zhGuide = """
        Simplified Chinese (Mainland). Lowercase pinyin-acronyms mixed with characters; repeat for emphasis. Laughter: 哈哈哈哈, 2333, xswl, 笑死 — not 😂.
        Current vocab: 那咋了 (so what / unbothered), emo了 (feeling down), 麻了 (numb / over it), 破防 (defenses broken / moved), 红温 (flushed with anger or embarrassment), 偷感 (acting low-key), 班味 (worn-down work vibe), 邪修 (unorthodox hack), 显眼包 (goofball), city不city (fancy?). Acronyms: yyds (GOAT), xswl (lmao), nbcs (nobody cares), awsl (so cute), u1s1 (real talk), dbq (sorry). Numbers: 666 (sick), 886 (bye), 555 (sob).
        Self-mocking 躺平 / 摆烂 tone. Avoid now-cringe: 绝绝子, 栓Q, overused yyds.
        Examples:
        - '这家餐厅真好吃，我很喜欢' → '这家真的绝了我爱住了哈哈哈哈'
        - '今天工作太累了，想休息' → '今天班味太重直接麻了 只想躺平'
        """

    private static let esGuide = """
        Spanish. Lowercase, drop opening ¿ ¡, no end-period, stretch vowels (siii, holaaa). Laughter: jajaja / jsjs / 💀 / 😭 — not 😂 or xD.
        Prefer PAN-HISPANIC terms (the user's region is usually unknown): cringe, random, crush, shippear, stalkear, mood, literal (intensifier), real / x2 (= same), mid, NPC, POV, red/green flag, modo X; peak term aura / farmear aura (clout). Regional — use only if signaled. Spain: tío/tía, en plan (filler), flipar, rayarse, mazo (= very). Mexico: neta, no manches, qué pedo, equis (= meh), alv. Argentina: che, boludo, re + adj, posta, de una (voseo: sos/tenés). Never mix regions — it reads instantly fake.
        Examples:
        - '¿Viste el video que te mandé? Es muy gracioso' → 'viste el video q te mande?? me morí 💀'
        - 'No quiero salir hoy, estoy muy cansado' → 'nah hoy no tengo ganas de salir estoy muerto'
        """

    private static let frGuide = """
        French. Default tu, never vous with peers (vous + slang = instant fake). All-lowercase; drop accents, apostrophes and the 'ne' (jai pas, jsp). Phonetic: c'est→c, j'ai→g, quoi→koi, t'inquiète→tkt, je sais pas→jsp, j'en peux plus→jpp, beaucoup→bcp. Laughter: mdr / ptdr / mdrrr and 💀 / 😭 — not 😂.
        Current vocab: wesh (yo), frérot / frr (bro), askip (apparently), c'est ouf / de ouf (insane), chelou (sketchy), relou (annoying), seum (bitter), bg (hot), validé (approved), banger, c'est carré (sorted), sah / wallah (i swear), jpp. Hyperbole for funny: 'je suis mort', 'ça m'a tué'. Avoid dated: swag, quoicoubeh, lol.
        Examples:
        - 'Tu es libre ce soir pour qu'on se voie ?' → 'wesh ça dit quoi tas dispo ce soir'
        - 'Je n'en peux plus, ce cours était trop long' → 'jpp ce cours ct giga long 💀'
        """

    private static let deGuide = """
        German. All-lowercase — drop even noun capitals (correct caps read old / try-hard). Default du. Drop the end-period (a lone 'Ok.' reads annoyed; 'ok' / 'kk' is fine). Laughter: 💀 / 😭, 'ich lieg', 'ich kann nicht' — not 😂.
        Current vocab: digga / diggah (bro, the #1 word), alter, bruda, wallah / ich schwör (i swear), lowkey, safe (definitely), mid, no cap, W / L (großes W, nimm das L), krass / geil (still live), 'das crazy', lost, cringe, random, aura. English verbs take German endings: gelikt, gecancelt, geghostet. Avoid corny / Jugendwort-bait: slay, lit, swag, yolo, smash, 'gönn dir', Ehrenmann. Do NOT generate Talahon or amk (slur / obscene).
        Examples:
        - 'Kannst du mir später beim Umzug helfen?' → 'digga hilfst du mir später beim umzug 🙏'
        - 'Der neue Film ist ziemlich mittelmäßig' → 'ngl der neue film war lowkey mid'
        """
}

enum AppCategoryClassifier {
    static let bundleIDMap: [String: AppCategory] = [
        "com.apple.mail": .email,
        "com.microsoft.Outlook": .email,
        "com.readdle.smartemail-Mac": .email,
        "com.superhuman.electron": .email,
        "com.tinyspeck.slackmacgap": .workMessages,
        "com.microsoft.teams2": .workMessages,
        "com.microsoft.teams": .workMessages,
        "com.linkedin.LinkedIn": .workMessages,
        "com.apple.MobileSMS": .personalMessages,
        "com.apple.iChat": .personalMessages,
        "ru.keepcoder.Telegram": .personalMessages,
        "org.telegram.desktop": .personalMessages,
        "net.whatsapp.WhatsApp": .personalMessages,
        // KakaoTalk is deliberately NOT mapped: in Korea it is as much a work
        // channel as a personal one, and personalMessages defaults to casual
        // (반말) — too risky to assume. Unmapped → .other → polite (해요체),
        // safe in both directions. Users can assign it via custom app rules.
        "com.hnc.Discord": .personalMessages,
    ]

    /// User-added app→category assignments. Take precedence over `bundleIDMap`.
    /// Kept in sync by `NugumiApp` from persisted `CustomAppAssignment`s.
    static var userOverrides: [String: AppCategory] = [:]
    /// Built-in `bundleIDMap` apps the user removed — treated as unclassified.
    static var suppressedBuiltIns: Set<String> = []

    static func category(for bundleID: String?) -> AppCategory {
        guard let id = bundleID else { return .other }
        if let override = userOverrides[id] { return override }
        if suppressedBuiltIns.contains(id) { return .other }
        if let mapped = bundleIDMap[id] { return mapped }
        let lower = id.lowercased()
        if lower.contains("mail") || lower.contains("outlook") { return .email }
        if lower.contains("slack") || lower.contains("teams") { return .workMessages }
        return .other
    }

    /// Category of the current frontmost app, by bundle ID.
    static func frontmostCategory() -> AppCategory {
        category(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }
}

/// A user-added app→category assignment, persisted in UserDefaults.
struct CustomAppAssignment: Codable, Equatable {
    let bundleID: String
    let name: String
    let category: AppCategory
}

enum CloudProvider: String, Codable, CaseIterable {
    case openAI
    case openAICodex
    case anthropic
    case gemini

    /// `.openAICodex` uses OAuth (ChatGPT subscription) instead of an API key
    /// — branches that present the API-key sheet must consult this flag.
    var usesOAuth: Bool {
        switch self {
        case .openAICodex: true
        case .openAI, .anthropic, .gemini: false
        }
    }

    var baseURL: URL {
        switch self {
        case .openAI:      URL(string: "https://api.openai.com/v1/chat/completions")!
        case .openAICodex: URL(string: "https://chatgpt.com/backend-api/codex/responses")!
        case .anthropic:   URL(string: "https://api.anthropic.com/v1/chat/completions")!
        case .gemini:      URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
        }
    }

    var keychainService: String { "com.nugumi.app.\(rawValue.lowercased())" }

    /// Single brand label used everywhere the provider is named — the
    /// Cloud access rows and the model picker section headers — so the two
    /// agree. The API-key vs subscription distinction is carried by the
    /// sign-in button ("Add key" vs "Sign in"), not the name.
    var displayName: String {
        switch self {
        case .openAI:      "OpenAI"
        case .openAICodex: "ChatGPT"
        case .anthropic:   "Anthropic"
        case .gemini:      "Google"
        }
    }

    var apiKeyHelpURL: URL {
        switch self {
        case .openAI:      URL(string: "https://platform.openai.com/api-keys")!
        case .openAICodex: URL(string: "https://chatgpt.com/")!
        case .anthropic:   URL(string: "https://console.anthropic.com/settings/keys")!
        case .gemini:      URL(string: "https://aistudio.google.com/app/apikey")!
        }
    }

    var modelsURL: URL {
        switch self {
        case .openAI:      URL(string: "https://api.openai.com/v1/models")!
        case .openAICodex: URL(string: "https://chatgpt.com/backend-api/codex/models?client_version=1.0.0")!
        case .anthropic:   URL(string: "https://api.anthropic.com/v1/models")!
        case .gemini:      URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/models")!
        }
    }
}

enum APIKeyValidator {
    enum Outcome {
        case valid
        case invalid(reason: String)
        case networkUnreachable(detail: String)
    }

    static func validate(_ apiKey: String, for provider: CloudProvider) async -> Outcome {
        var request = URLRequest(url: provider.modelsURL)
        request.httpMethod = "GET"
        switch provider {
        case .openAI, .gemini, .openAICodex:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            // Native Anthropic /v1/models requires x-api-key + anthropic-version,
            // not the OpenAI-compat Bearer header (compat only covers /chat/completions).
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .invalid(reason: "Invalid response from \(provider.displayName).")
            }
            switch http.statusCode {
            case 200..<300:
                // The body is the provider's /models list — feed discovery so
                // the picker updates the moment a key is added. Free: no
                // extra request beyond the validation GET itself.
                CloudModelCache.update(
                    provider: provider,
                    models: CloudModelDiscovery.parse(provider: provider, data: data)
                )
                return .valid
            case 401, 403:
                return .invalid(reason: "\(provider.displayName) rejected this key.")
            case 429:
                return .invalid(reason: "\(provider.displayName) rate-limited the check. Try later.")
            default:
                return .invalid(reason: "\(provider.displayName) returned HTTP \(http.statusCode).")
            }
        } catch let urlError as URLError where urlError.code == .notConnectedToInternet
            || urlError.code == .cannotConnectToHost
            || urlError.code == .cannotFindHost
            || urlError.code == .timedOut
            || urlError.code == .networkConnectionLost {
            return .networkUnreachable(detail: urlError.localizedDescription)
        } catch {
            return .networkUnreachable(detail: error.localizedDescription)
        }
    }
}

enum KeychainStore {
    private enum CacheEntry {
        case missing
        case present(String)
    }
    private static var cache: [CloudProvider: CacheEntry] = [:]

    private static let storageDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appending(path: "Nugumi", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func apiKey(for provider: CloudProvider) -> String? {
        if let entry = cache[provider] {
            switch entry {
            case .missing: return nil
            case .present(let key): return key
            }
        }
        let key = readFromFile(for: provider)
        cache[provider] = key.map { .present($0) } ?? .missing
        return key
    }

    static func setAPIKey(_ key: String?, for provider: CloudProvider) {
        let url = fileURL(for: provider)
        guard let key, !key.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            cache[provider] = .missing
            return
        }
        do {
            try key.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // If we can't write, at least keep the in-memory cache so this session works.
        }
        cache[provider] = .present(key)
    }

    private static func readFromFile(for provider: CloudProvider) -> String? {
        let url = fileURL(for: provider)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func fileURL(for provider: CloudProvider) -> URL {
        storageDirectory.appending(path: "\(provider.rawValue).key", directoryHint: .notDirectory)
    }
}

struct ImageInput {
    let data: Data
    let mediaType: String

    var base64String: String { data.base64EncodedString() }
    var openAIDataURI: String { "data:\(mediaType);base64,\(base64String)" }
}

protocol LLMBackend {
    func translate(
        _ text: String,
        images: [ImageInput],
        to targetLanguage: TranslationLanguage,
        mode: TranslationMode,
        appCategory: AppCategory,
        composition: CompositionSettings?,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> String

    func ask(
        history: [AskNugumiTurn],
        question: String,
        image: ImageInput?,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> AskNugumiResponse
}

struct OllamaClient: LLMBackend {
    let baseURL: URL
    let model: String

    func ask(
        history: [AskNugumiTurn],
        question: String,
        image: ImageInput?,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> AskNugumiResponse {
        if image != nil, !LLMModel.option(id: model).supportsImages {
            throw TranslationError.ollama("Selected Ollama model doesn't support images.")
        }

        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuestion.isEmpty else {
            return AskNugumiResponse(message: "", petTarget: nil, emotion: nil)
        }

        var messages: [ChatMessage] = [
            ChatMessage(role: "system", content: AskNugumiPromptBuilder.systemPrompt(genZ: GenZStyle.isEnabled))
        ]
        for turn in history {
            messages.append(ChatMessage(role: "user", content: turn.question))
            messages.append(ChatMessage(role: "assistant", content: turn.answer))
        }
        let prompt = AskNugumiPromptBuilder.prompt(question: cleanQuestion, hasImage: image != nil)
        messages.append(ChatMessage(role: "user", content: prompt, images: image.map { [$0.base64String] }))

        let url = baseURL.appending(path: "api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(model: model, stream: true, think: thinkingLevel.rawValue, messages: messages)
        )

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let urlError as URLError where urlError.code == .cannotConnectToHost
            || urlError.code == .cannotFindHost
            || urlError.code == .networkConnectionLost
            || urlError.code == .notConnectedToInternet {
            throw TranslationError.serverUnavailable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.ollama("invalid response")
        }
        if httpResponse.statusCode == 404 {
            throw TranslationError.modelMissing(model)
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw TranslationError.signInRequired
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TranslationError.ollama("HTTP \(httpResponse.statusCode)")
        }

        var answer = ""
        let decoder = JSONDecoder()
        for try await line in bytes.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            if let streamError = try? decoder.decode(StreamError.self, from: data),
               let message = streamError.error {
                throw OllamaClient.classifyStreamError(message: message, model: model)
            }
            let decoded = try decoder.decode(ChatResponse.self, from: data)
            answer += decoded.message.content
            onPartial(answer)
            if decoded.done { break }
        }

        let parsed = AskNugumiResponse.parse(answer)
        guard !parsed.message.isEmpty else {
            throw TranslationError.emptyResponse
        }
        return parsed
    }

    func translate(
        _ text: String,
        images: [ImageInput] = [],
        to targetLanguage: TranslationLanguage,
        mode: TranslationMode = .selection,
        appCategory: AppCategory,
        composition: CompositionSettings? = nil,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        let sourceText: String
        switch mode {
        case .selection, .smartReply:
            sourceText = TextNormalizer.cleanedSelection(text)
        case .draftMessage:
            sourceText = TextNormalizer.cleanedDraftMessage(text)
        }
        guard !sourceText.isEmpty else {
            throw TranslationError.emptyResponse
        }

        let url = baseURL.appending(path: "api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        if !images.isEmpty, !LLMModel.option(id: model).supportsImages {
            throw TranslationError.ollama("Selected Ollama model doesn't support images.")
        }

        let imageStrings = images.isEmpty ? nil : images.map(\.base64String)
        let body = ChatRequest(
            model: model,
            stream: true,
            think: thinkingLevel.rawValue,
            messages: [
                ChatMessage(
                    role: "system",
                    content: mode.systemPrompt(
                        targetLanguage: targetLanguage,
                        appCategory: appCategory,
                        composition: composition
                    )
                ),
                ChatMessage(role: "user", content: sourceText, images: imageStrings)
            ]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let urlError as URLError where urlError.code == .cannotConnectToHost
            || urlError.code == .cannotFindHost
            || urlError.code == .networkConnectionLost
            || urlError.code == .notConnectedToInternet {
            throw TranslationError.serverUnavailable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.ollama("invalid response")
        }

        if httpResponse.statusCode == 404 {
            throw TranslationError.modelMissing(model)
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw TranslationError.signInRequired
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TranslationError.ollama("HTTP \(httpResponse.statusCode)")
        }

        var translated = ""
        let decoder = JSONDecoder()
        for try await line in bytes.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8) else {
                continue
            }

            if let streamError = try? decoder.decode(StreamError.self, from: data),
               let message = streamError.error {
                throw OllamaClient.classifyStreamError(message: message, model: model)
            }

            let decoded = try decoder.decode(ChatResponse.self, from: data)
            translated += decoded.message.content

            let partial = TextNormalizer.cleanedTranslation(translated)
            if !partial.isEmpty {
                onPartial(partial)
            }

            if decoded.done {
                break
            }
        }

        let finalTranslation = TextNormalizer.cleanedTranslation(translated)
        guard !finalTranslation.isEmpty else {
            throw TranslationError.emptyResponse
        }

        return finalTranslation
    }

    static func classifyStreamError(message: String, model: String) -> TranslationError {
        let lowered = message.lowercased()
        if lowered.contains("not found") && (lowered.contains("model") || lowered.contains("manifest")) {
            return .modelMissing(model)
        }
        if lowered.contains("unauthorized")
            || lowered.contains("sign in")
            || lowered.contains("not signed in")
            || lowered.contains("signin")
            || lowered.contains("authenticate")
            || lowered.contains("forbidden") {
            return .signInRequired
        }
        return .ollama(message)
    }
}

struct OpenAIChatClient: LLMBackend {
    let provider: CloudProvider
    let apiKey: String
    let model: String

    private static let maxImageBytes = 5 * 1024 * 1024

    func ask(
        history: [AskNugumiTurn],
        question: String,
        image: ImageInput?,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> AskNugumiResponse {
        guard !apiKey.isEmpty else {
            throw TranslationError.invalidAPIKey(provider)
        }

        if let image {
            guard LLMModel.option(id: model).supportsImages else {
                throw TranslationError.cloudError(provider, "Ask Nugumi with a screenshot needs a vision model.")
            }
            guard image.data.count <= Self.maxImageBytes else {
                throw TranslationError.cloudError(provider, "Image too large (limit 5 MB)")
            }
        }

        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuestion.isEmpty else {
            return AskNugumiResponse(message: "", petTarget: nil, emotion: nil)
        }

        let currentPrompt = AskNugumiPromptBuilder.prompt(question: cleanQuestion, hasImage: image != nil)
        let currentUserContent: OpenAIContent
        if let image {
            currentUserContent = .parts([
                .text(currentPrompt),
                .imageURL(image.openAIDataURI)
            ])
        } else {
            currentUserContent = .string(currentPrompt)
        }

        var messages: [OpenAIMessage] = [
            OpenAIMessage(role: "system", content: .string(AskNugumiPromptBuilder.systemPrompt(genZ: GenZStyle.isEnabled)))
        ]
        for turn in history {
            messages.append(OpenAIMessage(role: "user", content: .string(turn.question)))
            messages.append(OpenAIMessage(role: "assistant", content: .string(turn.answer)))
        }
        messages.append(OpenAIMessage(role: "user", content: currentUserContent))

        let body = OpenAIRequest(
            model: model,
            stream: true,
            messages: messages,
            thinkingOptions: CloudThinkingOptions(
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel
            )
        )

        var request = URLRequest(url: provider.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(body)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let urlError as URLError where urlError.code == .cannotConnectToHost
            || urlError.code == .cannotFindHost
            || urlError.code == .networkConnectionLost
            || urlError.code == .notConnectedToInternet
            || urlError.code == .timedOut {
            throw TranslationError.cloudError(provider, urlError.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.cloudError(provider, "invalid response")
        }

        switch httpResponse.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw TranslationError.invalidAPIKey(provider)
        case 429:
            throw TranslationError.rateLimited(provider)
        default:
            throw TranslationError.cloudError(provider, "HTTP \(httpResponse.statusCode)")
        }

        var answer = ""
        let decoder = JSONDecoder()
        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(":") { continue }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8) else { continue }
            if let streamError = try? decoder.decode(OpenAIStreamError.self, from: data) {
                throw TranslationError.cloudError(provider, streamError.displayMessage)
            }
            guard let chunk = try? decoder.decode(OpenAIStreamChunk.self, from: data) else {
                throw TranslationError.cloudError(provider, "Unexpected stream payload")
            }
            if let delta = chunk.choices.first?.delta.content, !delta.isEmpty {
                answer += delta
                onPartial(answer)
            }
            if chunk.choices.first?.finishReason != nil { break }
        }

        let parsed = AskNugumiResponse.parse(answer)
        guard !parsed.message.isEmpty else {
            throw TranslationError.emptyResponse
        }
        return parsed
    }

    func translate(
        _ text: String,
        images: [ImageInput] = [],
        to targetLanguage: TranslationLanguage,
        mode: TranslationMode = .selection,
        appCategory: AppCategory,
        composition: CompositionSettings? = nil,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        guard !apiKey.isEmpty else {
            throw TranslationError.invalidAPIKey(provider)
        }

        let sourceText: String
        switch mode {
        case .selection, .smartReply:
            sourceText = TextNormalizer.cleanedSelection(text)
        case .draftMessage:
            sourceText = TextNormalizer.cleanedDraftMessage(text)
        }
        guard !sourceText.isEmpty || !images.isEmpty else {
            throw TranslationError.emptyResponse
        }

        for image in images where image.data.count > Self.maxImageBytes {
            throw TranslationError.cloudError(provider, "Image too large (limit 5 MB)")
        }

        let systemPrompt = mode.systemPrompt(
            targetLanguage: targetLanguage,
            appCategory: appCategory,
            composition: composition
        )
        let userContent: OpenAIContent = images.isEmpty
            ? .string(sourceText)
            : .parts([.text(sourceText)] + images.map { .imageURL($0.openAIDataURI) })

        let body = OpenAIRequest(
            model: model,
            stream: true,
            messages: [
                OpenAIMessage(role: "system", content: .string(systemPrompt)),
                OpenAIMessage(role: "user", content: userContent)
            ],
            thinkingOptions: CloudThinkingOptions(
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel
            )
        )

        var request = URLRequest(url: provider.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(body)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let urlError as URLError where urlError.code == .cannotConnectToHost
            || urlError.code == .cannotFindHost
            || urlError.code == .networkConnectionLost
            || urlError.code == .notConnectedToInternet
            || urlError.code == .timedOut {
            throw TranslationError.cloudError(provider, urlError.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.cloudError(provider, "invalid response")
        }

        switch httpResponse.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw TranslationError.invalidAPIKey(provider)
        case 429:
            throw TranslationError.rateLimited(provider)
        default:
            throw TranslationError.cloudError(provider, "HTTP \(httpResponse.statusCode)")
        }

        var translated = ""
        let decoder = JSONDecoder()
        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(":") { continue }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8) else { continue }
            if let streamError = try? decoder.decode(OpenAIStreamError.self, from: data) {
                throw TranslationError.cloudError(provider, streamError.displayMessage)
            }
            guard let chunk = try? decoder.decode(OpenAIStreamChunk.self, from: data) else {
                throw TranslationError.cloudError(provider, "Unexpected stream payload")
            }
            if let delta = chunk.choices.first?.delta.content, !delta.isEmpty {
                translated += delta
                let partial = TextNormalizer.cleanedTranslation(translated)
                if !partial.isEmpty {
                    onPartial(partial)
                }
            }
            if chunk.choices.first?.finishReason != nil { break }
        }

        let finalTranslation = TextNormalizer.cleanedTranslation(translated)
        guard !finalTranslation.isEmpty else {
            throw TranslationError.emptyResponse
        }
        return finalTranslation
    }
}

private enum OpenAIContent: Encodable {
    case string(String)
    case parts([OpenAIPart])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let text):
            try container.encode(text)
        case .parts(let parts):
            try container.encode(parts)
        }
    }
}

private enum OpenAIPart: Encodable {
    case text(String)
    case imageURL(String)

    private enum CodingKeys: String, CodingKey {
        case type, text, image_url
    }

    private struct ImageURLBox: Encodable {
        let url: String
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageURL(let url):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageURLBox(url: url), forKey: .image_url)
        }
    }
}

private struct OpenAIMessage: Encodable {
    let role: String
    let content: OpenAIContent
}

struct CloudThinkingOptions: Encodable, Equatable {
    let reasoningEffort: String?
    let thinking: AnthropicThinkingConfig?
    let outputConfig: AnthropicOutputConfig?

    init(provider: CloudProvider, model: String, thinkingLevel: ThinkingLevel) {
        switch provider {
        case .openAI, .gemini, .openAICodex:
            reasoningEffort = thinkingLevel.cloudReasoningEffort
            thinking = nil
            outputConfig = nil
        case .anthropic:
            reasoningEffort = nil
            if Self.usesAdaptiveClaudeThinking(model: model) {
                thinking = AnthropicThinkingConfig(type: "adaptive")
                outputConfig = AnthropicOutputConfig(effort: thinkingLevel.cloudReasoningEffort)
            } else {
                thinking = AnthropicThinkingConfig(
                    type: "enabled",
                    budgetTokens: thinkingLevel.claudeThinkingBudgetTokens
                )
                outputConfig = nil
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case reasoningEffort = "reasoning_effort"
        case thinking
        case outputConfig = "output_config"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try container.encodeIfPresent(thinking, forKey: .thinking)
        try container.encodeIfPresent(outputConfig, forKey: .outputConfig)
    }

    private static func usesAdaptiveClaudeThinking(model: String) -> Bool {
        let normalized = model.lowercased()
        return normalized.contains("claude-opus-4-7")
            || normalized.contains("claude-opus-4-6")
            || normalized.contains("claude-sonnet-4-6")
            || normalized.contains("claude-mythos")
    }
}

struct AnthropicThinkingConfig: Encodable, Equatable {
    let type: String
    let budgetTokens: Int?

    init(type: String, budgetTokens: Int? = nil) {
        self.type = type
        self.budgetTokens = budgetTokens
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case budgetTokens = "budget_tokens"
    }
}

struct AnthropicOutputConfig: Encodable, Equatable {
    let effort: String
}

private extension ThinkingLevel {
    var cloudReasoningEffort: String { rawValue }

    var claudeThinkingBudgetTokens: Int {
        switch self {
        case .low: return 1_024
        case .medium: return 2_048
        case .high: return 4_096
        }
    }
}

private struct OpenAIRequest: Encodable {
    let model: String
    let stream: Bool
    let messages: [OpenAIMessage]
    let thinkingOptions: CloudThinkingOptions?

    private enum CodingKeys: String, CodingKey {
        case model
        case stream
        case messages
        case reasoningEffort = "reasoning_effort"
        case thinking
        case outputConfig = "output_config"
    }

    init(
        model: String,
        stream: Bool,
        messages: [OpenAIMessage],
        thinkingOptions: CloudThinkingOptions? = nil
    ) {
        self.model = model
        self.stream = stream
        self.messages = messages
        self.thinkingOptions = thinkingOptions
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(stream, forKey: .stream)
        try container.encode(messages, forKey: .messages)
        try container.encodeIfPresent(thinkingOptions?.reasoningEffort, forKey: .reasoningEffort)
        try container.encodeIfPresent(thinkingOptions?.thinking, forKey: .thinking)
        try container.encodeIfPresent(thinkingOptions?.outputConfig, forKey: .outputConfig)
    }
}

private struct OpenAIStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }
        let delta: Delta
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }
    let choices: [Choice]
}

private struct OpenAIStreamError: Decodable {
    struct ErrorBody: Decodable {
        let message: String?
        let type: String?
        let code: String?
    }

    let error: ErrorBody

    var displayMessage: String {
        error.message ?? error.type ?? error.code ?? "stream error"
    }
}

struct ChatRequest: Encodable {
    let model: String
    let stream: Bool
    let think: String
    let messages: [ChatMessage]
}

struct ChatMessage: Codable {
    let role: String
    let content: String
    let images: [String]?

    init(role: String, content: String, images: [String]? = nil) {
        self.role = role
        self.content = content
        self.images = images
    }
}

struct ChatResponse: Decodable {
    let message: ChatMessage
    let done: Bool
}

struct StreamError: Decodable {
    let error: String?
}

enum TranslationError: LocalizedError {
    case ollama(String)
    case emptyResponse
    case serverUnavailable
    case modelMissing(String)
    case signInRequired
    case modelDownloading(String)
    case invalidAPIKey(CloudProvider)
    case rateLimited(CloudProvider)
    case cloudError(CloudProvider, String)

    var errorDescription: String? {
        switch self {
        case .ollama(let message):
            "Translation request failed: \(message)"
        case .emptyResponse:
            "Got an empty translation. Try again."
        case .serverUnavailable:
            "The translator isn't running. Open setup to fix it."
        case .modelMissing:
            "The translator isn't downloaded yet. Open setup to download it."
        case .signInRequired:
            "Sign in to Ollama to use the online translator. Open setup to finish."
        case .modelDownloading(let detail):
            "\(detail) Try again when the translator is ready."
        case .invalidAPIKey(let provider):
            "\(provider.displayName) rejected the API key. Open settings to update it."
        case .rateLimited(let provider):
            "\(provider.displayName) rate limit reached. Try again in a minute, or switch model."
        case .cloudError(let provider, let detail):
            "\(provider.displayName): \(detail)"
        }
    }
}

// MARK: - OpenAI Codex (ChatGPT subscription) OAuth
//
// Lets ChatGPT Plus/Pro subscribers use Nugumi without an OpenAI API key.
// The flow mirrors what the official Codex CLI does (and what Hermes Agent
// replicates): OAuth device-code login against auth.openai.com, then inference
// against chatgpt.com/backend-api/codex/responses (the Responses API, not the
// public /v1/chat/completions surface).
//
// IMPORTANT: this endpoint is unofficial. The same client_id and Cloudflare
// allow-listed `originator` header are shared with Codex CLI; OpenAI could
// tighten the allow-list at any time and break this backend.

struct CodexCredentials: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let accountId: String?
    let planType: String?

    func isExpiring(within seconds: TimeInterval) -> Bool {
        expiresAt.timeIntervalSinceNow < seconds
    }
}

enum CodexJWT {
    struct Claims {
        let expiresAt: Date?
        let accountId: String?
        let planType: String?
    }

    static func decode(_ jwt: String) -> Claims {
        let empty = Claims(expiresAt: nil, accountId: nil, planType: nil)
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let payload = base64URLDecode(String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return empty }

        let exp: Date? = {
            if let v = json["exp"] as? Double { return Date(timeIntervalSince1970: v) }
            if let v = json["exp"] as? Int { return Date(timeIntervalSince1970: TimeInterval(v)) }
            return nil
        }()
        let auth = json["https://api.openai.com/auth"] as? [String: Any]
        return Claims(
            expiresAt: exp,
            accountId: auth?["chatgpt_account_id"] as? String,
            planType: auth?["chatgpt_plan_type"] as? String
        )
    }

    static func base64URLDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = (4 - b64.count % 4) % 4
        if pad > 0 { b64.append(String(repeating: "=", count: pad)) }
        return Data(base64Encoded: b64)
    }
}

extension KeychainStore {
    private static var codexCache: CodexCredentials?
    private static var codexCacheLoaded = false
    private static let codexFileName = "openai.codex.tokens.json"

    private static var codexFileURL: URL {
        storageDirectory.appending(path: codexFileName, directoryHint: .notDirectory)
    }

    static func codexCredentials() -> CodexCredentials? {
        if codexCacheLoaded { return codexCache }
        codexCacheLoaded = true
        guard let data = try? Data(contentsOf: codexFileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        codexCache = try? decoder.decode(CodexCredentials.self, from: data)
        return codexCache
    }

    static func setCodexCredentials(_ creds: CodexCredentials?) {
        guard let creds else {
            try? FileManager.default.removeItem(at: codexFileURL)
            codexCache = nil
            codexCacheLoaded = true
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(creds) {
            try? data.write(to: codexFileURL, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: codexFileURL.path
            )
        }
        codexCache = creds
        codexCacheLoaded = true
    }
}

extension CloudProvider {
    /// True if the user has saved credentials for this provider (API key OR OAuth tokens).
    var hasCredentials: Bool {
        switch self {
        case .openAICodex:
            return KeychainStore.codexCredentials() != nil
        case .openAI, .anthropic, .gemini:
            let key = KeychainStore.apiKey(for: self)
            return !(key?.isEmpty ?? true)
        }
    }

    /// Order in which providers appear in the onboarding wizard's Cloud tab.
    /// ChatGPT subscription (OAuth) first — it's the most-friction-free
    /// option for users who already have a ChatGPT account — followed by
    /// the API-key providers in their declaration order.
    static var cloudOnboardingCases: [CloudProvider] {
        [.openAICodex] + allCases.filter { !$0.usesOAuth }
    }

    /// Default model ID to assign to the everyday-text scope when the user
    /// signs in / saves a key for this provider during onboarding. Picks a
    /// fast/cheap option from the provider's lineup.
    var preferredTextModelID: String {
        switch self {
        case .openAICodex: "codex/gpt-5.4-mini"
        case .openAI:      "gpt-5.4-mini"
        case .anthropic:   "claude-haiku-4-5-20251001"
        case .gemini:      "gemini-2.5-flash-lite"
        }
    }

    /// Default model ID for Ask Nugumi (the multimodal scope) when this
    /// provider's credentials get set during onboarding. Picks the flagship
    /// vision model from the provider's lineup.
    var preferredAskModelID: String {
        switch self {
        case .openAICodex: "codex/gpt-5.5"
        case .openAI:      "gpt-5.5"
        case .anthropic:   "claude-sonnet-4-6"
        case .gemini:      "gemini-2.5-pro"
        }
    }
}

// MARK: Codex diagnostics log

/// File-based debug log for the Codex auth flow. NSLog/os_log can get
/// silenced when the app is launched via `open` (stderr → /dev/null) and the
/// system log filter is unfriendly, so for the duration of debugging the
/// OAuth dance we mirror everything to ~/Library/Logs/Nugumi/codex.log
/// where the user can always `tail -f` it.
enum CodexDebugLog {
    private static let lock = NSLock()
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let fileURL: URL = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first!
            .appending(path: "Logs/Nugumi", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appending(path: "codex.log", directoryHint: .notDirectory)
    }()

    static func append(_ message: String) {
        let stamped = "\(formatter.string(from: Date())) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        if let data = stamped.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
        NSLog("[Nugumi/Codex] %@", message)
    }
}

// MARK: Codex OAuth client (device-code login + refresh)

/// Endpoints + flow shape mirror Hermes Agent's hermes_cli/auth.py:
/// `app_EMoamEEZ73f0CkXaXp7hrann` is the public Codex CLI client_id;
/// device-code returns {user_code, device_auth_id} then poll
/// /api/accounts/deviceauth/token until 200 returns {authorization_code,
/// code_verifier}, then exchange those at /oauth/token.
actor CodexOAuthClient {
    static let shared = CodexOAuthClient()

    private let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let issuer = "https://auth.openai.com"
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg)
    }()

    struct DeviceCodeStart {
        let userCode: String       // e.g. "LI50-8AOZ1"
        let deviceAuthID: String
        let verificationURL: URL   // https://auth.openai.com/codex/device
        let pollInterval: TimeInterval
    }

    enum CodexAuthError: LocalizedError {
        case network(String)
        case server(Int, String)
        case malformedResponse(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .network(let d): "Network error: \(d)"
            case .server(let code, let d): "Server returned HTTP \(code): \(d.prefix(200))"
            case .malformedResponse(let d): "Unexpected response: \(d)"
            case .timeout: "Login timed out after 15 minutes."
            }
        }
    }

    func startDeviceCode() async throws -> DeviceCodeStart {
        CodexDebugLog.append("startDeviceCode: requesting device code from \(issuer)")
        var req = URLRequest(url: URL(string: "\(issuer)/api/accounts/deviceauth/usercode")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": clientID])

        let (data, resp) = try await dataTask(req)
        guard let http = resp as? HTTPURLResponse else {
            throw CodexAuthError.malformedResponse("not an HTTP response")
        }
        let bodyPreview = String(data: data, encoding: .utf8)?.prefix(500) ?? ""
        CodexDebugLog.append("startDeviceCode: status=\(http.statusCode) body=\(bodyPreview)")
        guard http.statusCode == 200 else {
            throw CodexAuthError.server(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userCode = json["user_code"] as? String,
              let deviceAuthID = json["device_auth_id"] as? String
        else { throw CodexAuthError.malformedResponse("missing user_code / device_auth_id") }

        let interval: TimeInterval = {
            if let i = json["interval"] as? Double { return i }
            if let i = json["interval"] as? Int { return Double(i) }
            if let s = json["interval"] as? String, let v = Double(s) { return v }
            return 5
        }()
        CodexDebugLog.append("startDeviceCode: got userCode=\(userCode) interval=\(interval) keys=\(Array(json.keys))")
        return DeviceCodeStart(
            userCode: userCode,
            deviceAuthID: deviceAuthID,
            verificationURL: URL(string: "\(issuer)/codex/device")!,
            pollInterval: max(3, interval)
        )
    }

    func pollForTokens(
        deviceAuthID: String,
        userCode: String,
        interval: TimeInterval
    ) async throws -> CodexCredentials {
        let deadline = Date().addingTimeInterval(15 * 60)
        let pollURL = URL(string: "\(issuer)/api/accounts/deviceauth/token")!
        CodexDebugLog.append("pollForTokens: start — interval=\(interval)s deviceAuthID=\(deviceAuthID) userCode=\(userCode)")
        var lastStatusLogged = -1
        var iteration = 0
        while Date() < deadline {
            iteration += 1
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            try Task.checkCancellation()

            var req = URLRequest(url: pollURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "device_auth_id": deviceAuthID,
                "user_code": userCode
            ])

            let (data, resp): (Data, URLResponse)
            do {
                (data, resp) = try await dataTask(req)
            } catch {
                CodexDebugLog.append("poll #\(iteration): network error \(error)")
                continue
            }
            guard let http = resp as? HTTPURLResponse else {
                CodexDebugLog.append("poll #\(iteration): non-HTTP response")
                continue
            }
            let bodyPreview = String(data: data, encoding: .utf8)?.prefix(500) ?? ""
            if http.statusCode != lastStatusLogged {
                CodexDebugLog.append("poll #\(iteration) status=\(http.statusCode) body=\(bodyPreview)")
                lastStatusLogged = http.statusCode
            }
            switch http.statusCode {
            case 200:
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    CodexDebugLog.append("poll 200 but body not JSON: \(bodyPreview)")
                    throw CodexAuthError.malformedResponse("poll 200 body not JSON")
                }
                if let _ = json["access_token"] as? String {
                    CodexDebugLog.append("poll 200: direct access_token, skipping exchange")
                    return try parseTokenResponseJSON(json, fallbackRefreshToken: "")
                }
                if let authCode = json["authorization_code"] as? String,
                   let verifier = json["code_verifier"] as? String {
                    CodexDebugLog.append("poll 200: got authorization_code, exchanging…")
                    return try await exchangeAuthorizationCode(authCode, verifier: verifier)
                }
                CodexDebugLog.append("poll 200 unknown shape — keys=\(Array(json.keys))")
                throw CodexAuthError.malformedResponse("poll 200 unknown shape: \(Array(json.keys))")
            case 403, 404:
                continue // user hasn't completed sign-in yet
            case 400, 408, 425, 429:
                continue // "authorization_pending", "slow_down", or rate limit
            default:
                CodexDebugLog.append("poll #\(iteration) unexpected status \(http.statusCode) body=\(bodyPreview)")
                throw CodexAuthError.server(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
        }
        throw CodexAuthError.timeout
    }

    private func parseTokenResponseJSON(_ json: [String: Any], fallbackRefreshToken: String) throws -> CodexCredentials {
        guard let access = json["access_token"] as? String else {
            throw CodexAuthError.malformedResponse("missing access_token")
        }
        let refresh = (json["refresh_token"] as? String) ?? fallbackRefreshToken
        let claims = CodexJWT.decode(access)
        let fallbackExpiresIn: TimeInterval = {
            if let v = json["expires_in"] as? Double { return v }
            if let v = json["expires_in"] as? Int { return Double(v) }
            return 3600
        }()
        let expiry = claims.expiresAt ?? Date().addingTimeInterval(fallbackExpiresIn)
        return CodexCredentials(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: expiry,
            accountId: claims.accountId,
            planType: claims.planType
        )
    }

    private func exchangeAuthorizationCode(_ code: String, verifier: String) async throws -> CodexCredentials {
        try await postTokenRequest(form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": "\(issuer)/deviceauth/callback",
            "client_id": clientID,
            "code_verifier": verifier
        ])
    }

    func refresh(_ refreshToken: String) async throws -> CodexCredentials {
        try await postTokenRequest(form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ])
    }

    private func postTokenRequest(form: [String: String]) async throws -> CodexCredentials {
        let grantType = form["grant_type"] ?? "?"
        CodexDebugLog.append("postTokenRequest: building \(grantType) request to /oauth/token")
        var req = URLRequest(url: URL(string: "\(issuer)/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.urlencode(form).data(using: .utf8)
        CodexDebugLog.append("postTokenRequest: sending \(grantType), body \(req.httpBody?.count ?? 0) bytes")

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await dataTask(req)
        } catch {
            CodexDebugLog.append("postTokenRequest: dataTask threw — \(error)")
            throw error
        }
        guard let http = resp as? HTTPURLResponse else {
            CodexDebugLog.append("postTokenRequest: not an HTTPURLResponse")
            throw CodexAuthError.malformedResponse("not an HTTP response")
        }
        let bodyPreview = String(data: data, encoding: .utf8)?.prefix(500) ?? ""
        CodexDebugLog.append("postTokenRequest: \(grantType) status=\(http.statusCode) body=\(bodyPreview)")
        guard http.statusCode == 200 else {
            throw CodexAuthError.server(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String
        else { throw CodexAuthError.malformedResponse("missing access_token") }

        let refresh = (json["refresh_token"] as? String) ?? form["refresh_token"] ?? ""
        let claims = CodexJWT.decode(access)
        let fallbackExpiresIn: TimeInterval = {
            if let v = json["expires_in"] as? Double { return v }
            if let v = json["expires_in"] as? Int { return Double(v) }
            return 3600
        }()
        let expiry = claims.expiresAt ?? Date().addingTimeInterval(fallbackExpiresIn)
        CodexDebugLog.append("postTokenRequest: \(grantType) success — accountId=\(claims.accountId ?? "nil") plan=\(claims.planType ?? "nil")")
        return CodexCredentials(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: expiry,
            accountId: claims.accountId,
            planType: claims.planType
        )
    }

    private func dataTask(_ req: URLRequest) async throws -> (Data, URLResponse) {
        let url = req.url?.absoluteString ?? "?"
        CodexDebugLog.append("dataTask: starting \(req.httpMethod ?? "?") \(url)")
        do {
            let result = try await session.data(for: req)
            CodexDebugLog.append("dataTask: completed \(url)")
            return result
        } catch let err as URLError {
            CodexDebugLog.append("dataTask: URLError on \(url) — \(err.code.rawValue) \(err.localizedDescription)")
            throw CodexAuthError.network(err.localizedDescription)
        } catch {
            CodexDebugLog.append("dataTask: unexpected error on \(url) — \(error)")
            throw error
        }
    }

    private static func urlencode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?")
        return form.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
            return "\(ek)=\(ev)"
        }.joined(separator: "&")
    }
}

// MARK: Token broker — refresh-on-demand for inference paths

/// Resolves a fresh access token + JWT-derived account ID for the Codex
/// backend. Persists refreshed tokens back to Keychain. Serialized on the
/// shared CodexOAuthClient actor so concurrent translate/ask calls don't
/// stampede the token endpoint.
enum CodexCredentialBroker {
    /// Returns an access token guaranteed not to expire within ~2 minutes,
    /// refreshing transparently if needed. Throws if the user is not logged in.
    static func resolveAccessToken() async throws -> (token: String, accountId: String?) {
        guard let creds = KeychainStore.codexCredentials() else {
            throw TranslationError.invalidAPIKey(.openAICodex)
        }
        if !creds.isExpiring(within: 120) {
            return (creds.accessToken, creds.accountId)
        }
        do {
            let refreshed = try await CodexOAuthClient.shared.refresh(creds.refreshToken)
            await MainActor.run { KeychainStore.setCodexCredentials(refreshed) }
            return (refreshed.accessToken, refreshed.accountId)
        } catch let err as CodexOAuthClient.CodexAuthError {
            if case .server(let status, _) = err, status == 400 || status == 401 || status == 403 {
                // Refresh token revoked or rotated by another client — force re-login.
                await MainActor.run { KeychainStore.setCodexCredentials(nil) }
                throw TranslationError.invalidAPIKey(.openAICodex)
            }
            throw TranslationError.cloudError(.openAICodex, err.errorDescription ?? "auth error")
        }
    }

    static func forceRefresh() async throws -> (token: String, accountId: String?) {
        guard let creds = KeychainStore.codexCredentials() else {
            throw TranslationError.invalidAPIKey(.openAICodex)
        }
        let refreshed = try await CodexOAuthClient.shared.refresh(creds.refreshToken)
        await MainActor.run { KeychainStore.setCodexCredentials(refreshed) }
        return (refreshed.accessToken, refreshed.accountId)
    }
}

// MARK: Discovered Codex models (live API + cached fallback)

/// Thread-safe cache of Codex model slugs discovered from
/// chatgpt.com/backend-api/codex/models. Falls back to the Hermes-curated
/// list when discovery hasn't run yet. Lives outside any actor so
/// `LLMModel.codexModels` can be read from any thread that builds the
/// menu / dispatches a backend.
enum CodexModelCache {
    /// Hermes' curated fallback (hermes_cli/codex_models.py DEFAULT_CODEX_MODELS).
    /// Used until live discovery succeeds.
    static let fallbackSlugs: [String] = [
        "gpt-5.5",
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.3-codex",
        "gpt-5.3-codex-spark",
        "gpt-5.2-codex",
        "gpt-5.1-codex-max",
        "gpt-5.1-codex-mini"
    ]

    private static let cacheKey = "codex.discoveredModels.v1"
    private static let lock = NSLock()
    private static var memo: [String]?

    static var slugs: [String] {
        lock.lock()
        defer { lock.unlock() }
        if let memo { return memo }
        let stored = UserDefaults.standard.stringArray(forKey: cacheKey) ?? []
        let resolved = stored.isEmpty ? fallbackSlugs : stored
        memo = resolved
        return resolved
    }

    static func update(_ slugs: [String]) {
        lock.lock()
        memo = slugs
        lock.unlock()
        UserDefaults.standard.set(slugs, forKey: cacheKey)
        NotificationCenter.default.post(name: .codexModelsUpdated, object: nil)
    }

    static func clear() {
        lock.lock()
        memo = nil
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: cacheKey)
        NotificationCenter.default.post(name: .codexModelsUpdated, object: nil)
    }
}

enum CodexModelDiscovery {
    /// Live fetch + cache. Best-effort: failure leaves the cache untouched.
    static func refreshFromAPI() async {
        let token: String
        do {
            token = try await CodexCredentialBroker.resolveAccessToken().token
        } catch {
            return
        }
        var req = URLRequest(url: CloudProvider.openAICodex.modelsURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for (k, v) in OpenAICodexClient.cloudflareHeaders(accessToken: token) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.timeoutInterval = 15

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["models"] as? [[String: Any]]
        else { return }

        struct Entry { let slug: String; let priority: Int }
        var parsed: [Entry] = []
        for item in entries {
            guard let slug = (item["slug"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !slug.isEmpty
            else { continue }
            if let v = item["visibility"] as? String,
               ["hide", "hidden"].contains(v.lowercased()) { continue }
            let priority: Int = {
                if let n = item["priority"] as? Int { return n }
                if let n = item["priority"] as? Double { return Int(n) }
                return 10_000
            }()
            parsed.append(Entry(slug: slug, priority: priority))
        }
        guard !parsed.isEmpty else { return }
        parsed.sort { $0.priority == $1.priority ? $0.slug < $1.slug : $0.priority < $1.priority }
        CodexModelCache.update(parsed.map(\.slug))
    }
}

// MARK: Discovered API-key cloud models (live /models + cached fallback)

/// Discovery for the three API-key providers (OpenAI, Anthropic, Gemini).
/// Same contract as CodexModelDiscovery: best-effort, failures never touch
/// the cache, the curated LLMModel.all entries remain the permanent floor.
enum CloudModelDiscovery {
    struct DiscoveredModel: Equatable {
        let id: String
        /// Provider-supplied pretty name (Anthropic's `display_name`).
        /// nil for providers whose list API returns bare ids.
        let displayName: String?
    }

    /// Substrings that mark an OpenAI id as non-chat or Codex-only.
    private static let openAIDropMarkers = [
        "-audio", "-realtime", "-search", "-tts", "-transcribe", "-image", "-codex"
    ]
    /// Substrings that mark a Gemini id as non-chat. Dash-anchored so a
    /// marker can't match inside an unrelated word (e.g. "-live" skips
    /// "gemini-live-2.5-flash" but not a hypothetical "gemini-alive").
    private static let geminiDropMarkers = [
        "-embedding", "-tts", "-image", "-live", "-audio"
    ]

    /// Parse a provider's `/models` response body into chat-capable models,
    /// in response order. All three providers use the OpenAI-style
    /// `{"data": [{"id": ...}]}` envelope (Anthropic adds `display_name`).
    /// Unknown payloads and the OAuth-only Codex provider yield [].
    static func parse(provider: CloudProvider, data: Data) -> [DiscoveredModel] {
        guard provider != .openAICodex,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]]
        else { return [] }

        var out: [DiscoveredModel] = []
        for item in entries {
            guard var id = (item["id"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !id.isEmpty
            else { continue }
            switch provider {
            case .openAI:
                // gpt-5 and newer text-chat families only.
                guard id.hasPrefix("gpt-5") || id.hasPrefix("gpt-6"),
                      !openAIDropMarkers.contains(where: id.contains)
                else { continue }
            case .anthropic:
                guard id.hasPrefix("claude-") else { continue }
            case .gemini:
                if id.hasPrefix("models/") { id = String(id.dropFirst("models/".count)) }
                guard id.hasPrefix("gemini-"),
                      !geminiDropMarkers.contains(where: id.contains)
                else { continue }
            case .openAICodex:
                continue
            }
            out.append(DiscoveredModel(id: id, displayName: item["display_name"] as? String))
        }
        return out
    }

    /// Anthropic pins releases with a trailing -YYYYMMDD date stamp
    /// (claude-haiku-4-5-20251001). Strip it so a curated dated id and the
    /// API's undated alias (or vice versa) compare equal.
    static func canonicalID(_ id: String) -> String {
        let parts = id.split(separator: "-")
        if let last = parts.last, last.count == 8, last.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return parts.dropLast().joined(separator: "-")
        }
        return id
    }

    /// Human-readable name for a discovered model with no curated entry.
    /// Matches the curated naming style per provider: "GPT-5.6 mini",
    /// "Claude Opus 4.8", "Gemini 3.0 Pro". Tier hints ("fast", "flagship")
    /// are curated-only — we can't infer them from an id.
    static func prettyName(provider: CloudProvider, id: String) -> String {
        switch provider {
        case .openAI, .openAICodex:
            // gpt-5.6-mini → GPT-5.6 mini
            var name = id
            if name.hasPrefix("gpt-") { name = "GPT-" + name.dropFirst("gpt-".count) }
            return name.replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "GPT ", with: "GPT-")
        case .anthropic:
            // claude-opus-4-8 → Claude Opus 4.8 (numeric tail joins with dots)
            let parts = canonicalID(id).split(separator: "-").map(String.init)
            var words: [String] = []
            for part in parts {
                if part.allSatisfy({ $0.isASCII && $0.isNumber }), let last = words.last,
                   last.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." }) {
                    words[words.count - 1] = last + "." + part
                } else {
                    words.append(part.capitalized)
                }
            }
            return words.joined(separator: " ")
        case .gemini:
            // gemini-2.5-flash-lite → Gemini 2.5 Flash Lite
            return id.split(separator: "-")
                .map { $0.first?.isNumber == true ? String($0) : String($0).capitalized }
                .joined(separator: " ")
        }
    }

    /// Launch-time refresh for every provider with a stored key. Best-effort:
    /// any failure (no key, network, non-200, unparseable body) leaves the
    /// cache untouched. Same contract as CodexModelDiscovery.refreshFromAPI.
    static func refreshAll() async {
        // KeychainStore's in-memory cache is main-actor-confined everywhere
        // else; read the keys there, then do the network work off-actor.
        let credentials: [(CloudProvider, String)] = await MainActor.run {
            [CloudProvider.openAI, .anthropic, .gemini].compactMap { provider in
                guard let key = KeychainStore.apiKey(for: provider), !key.isEmpty else { return nil }
                return (provider, key)
            }
        }
        for (provider, key) in credentials {
            var request = URLRequest(url: provider.modelsURL)
            request.httpMethod = "GET"
            switch provider {
            case .anthropic:
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            default:
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            request.timeoutInterval = 15
            guard let (data, resp) = try? await URLSession.shared.data(for: request),
                  let http = resp as? HTTPURLResponse, http.statusCode == 200
            else { continue }
            CloudModelCache.update(provider: provider, models: parse(provider: provider, data: data))
        }
    }
}

/// Thread-safe per-provider cache of model ids discovered from the
/// API-key providers' /models endpoints, persisted to UserDefaults.
/// nil (never fetched) and "fetched" are distinct states: merge logic
/// falls back to the curated list only in the former. Lives outside any
/// actor so LLMModel.cloudModels(for:) can be read from any thread that
/// builds the menu / dispatches a backend.
enum CloudModelCache {
    private static let lock = NSLock()
    private static var memoIDs: [CloudProvider: [String]] = [:]
    private static var memoNames: [CloudProvider: [String: String]] = [:]

    private static func idsKey(_ p: CloudProvider) -> String { "cloud.discoveredModels.\(p.rawValue).v1" }
    private static func namesKey(_ p: CloudProvider) -> String { "cloud.discoveredNames.\(p.rawValue).v1" }

    /// Discovered models for one provider, or nil if discovery has never
    /// succeeded for it (curated fallback applies).
    static func discovered(for provider: CloudProvider) -> [CloudModelDiscovery.DiscoveredModel]? {
        lock.lock()
        defer { lock.unlock() }
        let ids: [String]
        if let memo = memoIDs[provider] {
            ids = memo
        } else if let stored = UserDefaults.standard.stringArray(forKey: idsKey(provider)) {
            memoIDs[provider] = stored
            ids = stored
        } else {
            return nil
        }
        let names = memoNames[provider]
            ?? (UserDefaults.standard.dictionary(forKey: namesKey(provider)) as? [String: String])
            ?? [:]
        memoNames[provider] = names
        return ids.map { .init(id: $0, displayName: names[$0]) }
    }

    static func update(provider: CloudProvider, models: [CloudModelDiscovery.DiscoveredModel]) {
        guard provider != .openAICodex, !models.isEmpty else { return }
        let ids = models.map(\.id)
        var names: [String: String] = [:]
        for m in models { names[m.id] = m.displayName }
        lock.lock()
        let changed = memoIDs[provider] != ids || memoNames[provider] != names
        memoIDs[provider] = ids
        memoNames[provider] = names
        if changed {
            // Persist inside the lock so memo and UserDefaults can't diverge
            // when two providers refresh concurrently. UserDefaults writes are
            // fast in-process mutations; the daemon sync is asynchronous.
            UserDefaults.standard.set(ids, forKey: idsKey(provider))
            UserDefaults.standard.set(names, forKey: namesKey(provider))
        }
        lock.unlock()
        guard changed else { return }
        NotificationCenter.default.post(name: .cloudModelsUpdated, object: nil)
    }
}

extension Notification.Name {
    static let codexModelsUpdated = Notification.Name("com.nugumi.codex.modelsUpdated")
    static let ollamaModelsUpdated = Notification.Name("com.nugumi.ollama.modelsUpdated")
    static let cloudModelsUpdated = Notification.Name("com.nugumi.cloud.modelsUpdated")
}

// MARK: Discovered Ollama models (live /api/tags + cached fallback)

/// Thread-safe cache of Ollama model names discovered from the running
/// server's `/api/tags`. Fed by OllamaBootstrap's existing tags request (see
/// Bootstrap.swift `modelsPresent()`), persisted to UserDefaults so the menu
/// has something to show before the first refresh lands. Lives outside any
/// actor so `LLMModel.ollamaModels` can be read from any thread.
enum OllamaModelCache {
    private static let cacheKey = "ollama.discoveredModels.v1"
    private static let visionKey = "ollama.visionModels.v1"
    private static let lock = NSLock()
    private static var memoNames: [String]?
    private static var memoVision: Set<String>?

    /// Model names from the last successful `/api/tags`. Empty until the
    /// server is reachable.
    static var discovered: [String] {
        lock.lock()
        defer { lock.unlock() }
        if let memoNames { return memoNames }
        let stored = UserDefaults.standard.stringArray(forKey: cacheKey) ?? []
        memoNames = stored
        return stored
    }

    /// Names the server reported as vision-capable (`/api/show` capabilities
    /// include "vision"). Drives `supportsImages` so only these appear in the
    /// vision-only Ask Nugumi picker.
    static var visionCapable: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        if let memoVision { return memoVision }
        let stored = Set(UserDefaults.standard.stringArray(forKey: visionKey) ?? [])
        memoVision = stored
        return stored
    }

    static func update(names: [String], vision: Set<String>) {
        lock.lock()
        let changed = memoNames != names || memoVision != vision
        memoNames = names
        memoVision = vision
        lock.unlock()
        guard changed else { return }
        UserDefaults.standard.set(names, forKey: cacheKey)
        UserDefaults.standard.set(Array(vision), forKey: visionKey)
        NotificationCenter.default.post(name: .ollamaModelsUpdated, object: nil)
    }
}

// MARK: OpenAICodexClient — Responses API + Cloudflare allow-list headers

/// Talks to chatgpt.com/backend-api/codex/responses on behalf of a
/// ChatGPT Plus/Pro subscriber. Sits behind Cloudflare which 403s any
/// request that doesn't advertise an allow-listed `originator` — we pin
/// `codex_cli_rs` (the value the Rust Codex CLI uses), the matching
/// User-Agent shape, and a `ChatGPT-Account-ID` extracted from the JWT.
/// All three are required; dropping any one trips the WAF.
struct OpenAICodexClient: LLMBackend {
    let apiModelID: String
    private static let maxImageBytes = 5 * 1024 * 1024

    /// Pulls a user-facing error message out of an OpenAI error JSON body.
    /// Accepts both `{"error": {"message": "…"}}` and `{"error": "…"}` shapes.
    private func extractOpenAIErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let err = obj["error"] as? [String: Any] {
            if let m = err["message"] as? String, !m.isEmpty { return m }
        } else if let s = obj["error"] as? String, !s.isEmpty {
            return s
        }
        return nil
    }

    /// Headers that mimic the Rust Codex CLI so Cloudflare doesn't block us.
    /// Extracted as a static helper so model discovery can reuse them.
    static func cloudflareHeaders(accessToken: String) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": "codex_cli_rs/0.0.0 (Nugumi)",
            "originator": "codex_cli_rs"
        ]
        let claims = CodexJWT.decode(accessToken)
        if let acct = claims.accountId, !acct.isEmpty {
            headers["ChatGPT-Account-ID"] = acct
        }
        return headers
    }

    func translate(
        _ text: String,
        images: [ImageInput],
        to targetLanguage: TranslationLanguage,
        mode: TranslationMode,
        appCategory: AppCategory,
        composition: CompositionSettings?,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        let sourceText: String
        switch mode {
        case .selection, .smartReply:
            sourceText = TextNormalizer.cleanedSelection(text)
        case .draftMessage:
            sourceText = TextNormalizer.cleanedDraftMessage(text)
        }
        guard !sourceText.isEmpty || !images.isEmpty else {
            throw TranslationError.emptyResponse
        }
        for image in images where image.data.count > Self.maxImageBytes {
            throw TranslationError.cloudError(.openAICodex, "Image too large (limit 5 MB)")
        }

        let systemPrompt = mode.systemPrompt(
            targetLanguage: targetLanguage,
            appCategory: appCategory,
            composition: composition
        )
        // TEMP DIAGNOSTIC (voice-sample issue) — remove once resolved.
        CodexDebugLog.append("[voice-debug] codex mode=\(mode) promptHasVoice=\(systemPrompt.contains("Voice sample —")) promptChars=\(systemPrompt.count)")
        let userContent: [CodexInputContent] = {
            var parts: [CodexInputContent] = [.text(sourceText, role: "user")]
            parts.append(contentsOf: images.map { .image($0.openAIDataURI) })
            return parts
        }()
        let body = CodexResponsesRequest(
            model: apiModelID,
            instructions: systemPrompt,
            input: [CodexInputItem(role: "user", content: userContent)],
            stream: true,
            store: false,
            reasoning: CodexReasoningConfig(effort: thinkingLevel.cloudReasoningEffort)
        )

        var streamed = ""
        try await runStreaming(body: body, timeoutInterval: 25) { delta in
            streamed += delta
            let partial = TextNormalizer.cleanedTranslation(streamed)
            if !partial.isEmpty { onPartial(partial) }
        }
        let final = TextNormalizer.cleanedTranslation(streamed)
        guard !final.isEmpty else { throw TranslationError.emptyResponse }
        return final
    }

    func ask(
        history: [AskNugumiTurn],
        question: String,
        image: ImageInput?,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> AskNugumiResponse {
        if let image, image.data.count > Self.maxImageBytes {
            throw TranslationError.cloudError(.openAICodex, "Image too large (limit 5 MB)")
        }
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuestion.isEmpty else {
            return AskNugumiResponse(message: "", petTarget: nil, emotion: nil)
        }
        let currentPrompt = AskNugumiPromptBuilder.prompt(question: cleanQuestion, hasImage: image != nil)

        var items: [CodexInputItem] = []
        for turn in history {
            items.append(CodexInputItem(role: "user", content: [.text(turn.question, role: "user")]))
            items.append(CodexInputItem(role: "assistant", content: [.text(turn.answer, role: "assistant")]))
        }
        var currentContent: [CodexInputContent] = [.text(currentPrompt, role: "user")]
        if let image { currentContent.append(.image(image.openAIDataURI)) }
        items.append(CodexInputItem(role: "user", content: currentContent))

        let body = CodexResponsesRequest(
            model: apiModelID,
            instructions: AskNugumiPromptBuilder.systemPrompt(genZ: GenZStyle.isEnabled),
            input: items,
            stream: true,
            store: false,
            reasoning: CodexReasoningConfig(effort: thinkingLevel.cloudReasoningEffort)
        )

        var answer = ""
        try await runStreaming(body: body, timeoutInterval: 60) { delta in
            answer += delta
            onPartial(answer)
        }
        let parsed = AskNugumiResponse.parse(answer)
        guard !parsed.message.isEmpty else { throw TranslationError.emptyResponse }
        return parsed
    }

    // MARK: Streaming transport (Responses API SSE)

    private func runStreaming(
        body: CodexResponsesRequest,
        timeoutInterval: TimeInterval,
        onDelta: @escaping (String) -> Void
    ) async throws {
        let encoded = try JSONEncoder().encode(body)
        do {
            try await performStreamingRequest(encodedBody: encoded, timeoutInterval: timeoutInterval, allowRefresh: true, onDelta: onDelta)
        } catch TranslationError.invalidAPIKey(.openAICodex) {
            // One transparent retry after a forced refresh — covers tokens
            // revoked between our last JWT-exp check and the actual request.
            try await performStreamingRequest(encodedBody: encoded, timeoutInterval: timeoutInterval, allowRefresh: false, onDelta: onDelta)
        }
    }

    private func performStreamingRequest(
        encodedBody: Data,
        timeoutInterval: TimeInterval,
        allowRefresh: Bool,
        onDelta: @escaping (String) -> Void
    ) async throws {
        let (token, accountId) = try await CodexCredentialBroker.resolveAccessToken()
        CodexDebugLog.append("inference: POST /responses (model=\(apiModelID), account=\(accountId ?? "nil"), bodyBytes=\(encodedBody.count))")

        var request = URLRequest(url: CloudProvider.openAICodex.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "session_id")
        for (k, v) in Self.cloudflareHeaders(accessToken: token) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        // chatgpt.com/backend-api/codex/responses returns response headers in
        // <2s when healthy; when it black-holes, it black-holes forever.
        // Translate uses 25s (fast iteration); Ask uses 60s (longer responses,
        // more typing invested in the question).
        request.timeoutInterval = timeoutInterval
        request.httpBody = encodedBody

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let urlError as URLError where urlError.code == .cannotConnectToHost
            || urlError.code == .cannotFindHost
            || urlError.code == .networkConnectionLost
            || urlError.code == .notConnectedToInternet
            || urlError.code == .timedOut {
            CodexDebugLog.append("inference: URLError \(urlError.code.rawValue) — \(urlError.localizedDescription)")
            // The subscription endpoint sometimes drops individual requests
            // upstream — be explicit about that so users don't think Nugumi
            // is broken.
            let message: String
            if urlError.code == .notConnectedToInternet {
                message = "No internet connection."
            } else {
                message = "Sometimes drops requests — just try one more time."
            }
            throw TranslationError.cloudError(.openAICodex, message)
        }

        guard let http = response as? HTTPURLResponse else {
            CodexDebugLog.append("inference: non-HTTP response")
            throw TranslationError.cloudError(.openAICodex, "invalid response")
        }
        CodexDebugLog.append("inference: status=\(http.statusCode)")
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            // Drain the body so we can show OpenAI's actual error message —
            // 401/403 from the Codex endpoint for free accounts surfaces as
            // a JSON body with a useful explanation we should pass through
            // rather than swallowing as "rejected the API key."
            var bodyData = Data()
            for try await chunk in bytes { bodyData.append(chunk) }
            let bodyPreview = String(data: bodyData, encoding: .utf8)?.prefix(800) ?? ""
            CodexDebugLog.append("inference: \(http.statusCode) body=\(bodyPreview)")
            if http.statusCode == 401, allowRefresh {
                _ = try? await CodexCredentialBroker.forceRefresh()
                throw TranslationError.invalidAPIKey(.openAICodex)
            }
            // Try to extract a human-readable message from OpenAI's error JSON.
            let detail = extractOpenAIErrorMessage(from: bodyData) ?? "HTTP \(http.statusCode)"
            throw TranslationError.cloudError(.openAICodex, detail)
        case 429:
            throw TranslationError.rateLimited(.openAICodex)
        default:
            var bodyData = Data()
            for try await chunk in bytes { bodyData.append(chunk) }
            let bodyPreview = String(data: bodyData, encoding: .utf8)?.prefix(800) ?? ""
            CodexDebugLog.append("inference: \(http.statusCode) body=\(bodyPreview)")
            let detail = extractOpenAIErrorMessage(from: bodyData) ?? "HTTP \(http.statusCode)"
            throw TranslationError.cloudError(.openAICodex, detail)
        }

        let decoder = JSONDecoder()
        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(":") || line.hasPrefix("event:") { continue }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8) else { continue }
            if let chunk = try? decoder.decode(CodexResponsesStreamEvent.self, from: data) {
                if chunk.type == "response.output_text.delta", let delta = chunk.delta, !delta.isEmpty {
                    onDelta(delta)
                } else if chunk.type == "response.completed" {
                    break
                } else if chunk.type == "response.error" || chunk.type == "error" {
                    let msg = chunk.message ?? chunk.error?.message ?? "stream error"
                    throw TranslationError.cloudError(.openAICodex, msg)
                }
            }
        }
    }
}

// MARK: Codex Responses API wire types

private struct CodexResponsesRequest: Encodable {
    let model: String
    let instructions: String?
    let input: [CodexInputItem]
    let stream: Bool
    let store: Bool
    let reasoning: CodexReasoningConfig?
}

private struct CodexReasoningConfig: Encodable {
    let effort: String
}

private struct CodexInputItem: Encodable {
    let role: String
    let content: [CodexInputContent]
}

private enum CodexInputContent: Encodable {
    case text(String, role: String)
    case image(String) // data: URI

    private enum CodingKeys: String, CodingKey {
        case type, text, image_url
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s, let role):
            try c.encode(role == "assistant" ? "output_text" : "input_text", forKey: .type)
            try c.encode(s, forKey: .text)
        case .image(let url):
            try c.encode("input_image", forKey: .type)
            try c.encode(url, forKey: .image_url)
        }
    }
}

private struct CodexResponsesStreamEvent: Decodable {
    let type: String
    let delta: String?
    let message: String?
    let error: CodexResponsesStreamError?
}

private struct CodexResponsesStreamError: Decodable {
    let message: String?
}

// MARK: Codex login UI (device-code alert)

/// Modal NSAlert that drives the device-code dance:
///   1. Calls /api/accounts/deviceauth/usercode to get a code + interval.
///   2. Shows the code + URL with copy/open buttons.
///   3. Polls /api/accounts/deviceauth/token until the user finishes sign-in
///      in their browser (or until 15-minute timeout / Cancel).
///   4. On success, persists CodexCredentials to Keychain and dismisses
///      the alert programmatically via NSApp.stopModal.
/// ChatGPT (Codex) device-flow sign-in, shown as a compact floating panel.
///
/// Deliberately NOT an `NSAlert.runModal`: the app-modal alert activated
/// Nugumi on every click, yanking the main window in front of the browser
/// page the user was trying to sign in with. A `.nonactivatingPanel` floats
/// above the browser, takes clicks without activating the app, and needs no
/// nested modal run loop — completion is a plain continuation.
@MainActor
final class CodexLoginAlert: NSObject {
    enum Outcome {
        case success(CodexCredentials)
        case cancelled
        case failed(String)
    }

    private var panel: NSPanel?
    private var pollTask: Task<Void, Never>?
    private var verificationURL: URL!
    private var userCode: String!
    /// Resumes `run()`'s continuation exactly once, whichever finishes first
    /// (successful poll, poll failure, or Cancel).
    private var finish: ((Outcome) -> Void)?

    static func present() async -> Outcome {
        let controller = CodexLoginAlert()
        return await controller.run()
    }

    private func run() async -> Outcome {
        let start: CodexOAuthClient.DeviceCodeStart
        do {
            start = try await CodexOAuthClient.shared.startDeviceCode()
        } catch {
            return .failed("Couldn't start sign-in: \(error.localizedDescription)")
        }

        verificationURL = start.verificationURL
        userCode = start.userCode

        // Open the browser WITHOUT activating Nugumi — the sign-in page must
        // stay in front; the panel floats above it.
        NSWorkspace.shared.open(start.verificationURL)

        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            var resumed = false
            finish = { outcome in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: outcome)
            }

            CodexDebugLog.append("CodexLoginAlert: launching poll task")
            pollTask = Task { [weak self] in
                do {
                    let creds = try await CodexOAuthClient.shared.pollForTokens(
                        deviceAuthID: start.deviceAuthID,
                        userCode: start.userCode,
                        interval: start.pollInterval
                    )
                    // Persist before resuming so the caller always finds them.
                    KeychainStore.setCodexCredentials(creds)
                    CodexDebugLog.append("CodexLoginAlert: tokens persisted")
                    self?.finish?(.success(creds))
                } catch is CancellationError {
                    CodexDebugLog.append("CodexLoginAlert: poll cancelled")
                } catch {
                    CodexDebugLog.append("CodexLoginAlert: poll failed — \(error)")
                    self?.finish?(.failed(error.localizedDescription))
                }
            }

            presentPanel()
        }

        pollTask?.cancel()
        finish = nil
        closePanel()

        if case .success = outcome {
            // Fire-and-forget model discovery so the menu reflects this
            // account's catalog (Plus vs Pro see different lineups).
            Task.detached { await CodexModelDiscovery.refreshFromAPI() }
        }
        return outcome
    }

    private func presentPanel() {
        let view = CodexLoginPanelView(
            code: userCode,
            openPage: { [weak self] in
                guard let self else { return }
                NSWorkspace.shared.open(self.verificationURL)
            },
            cancel: { [weak self] in
                self?.finish?(.cancelled)
            }
        )
        let hosting = NSHostingView(rootView: view)
        // The titled+fullSizeContentView panel reports the titlebar as a top
        // safe-area inset, which SwiftUI turns into ~28pt of dead air above
        // the content. The panel has no visible titlebar — drop the inset.
        hosting.safeAreaRegions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Sign in with ChatGPT"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear

        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.appearance = NSAppearance(named: .darkAqua)
        backdrop.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: backdrop.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        panel.contentView = backdrop

        let size = hosting.fittingSize
        panel.setContentSize(size)
        // Upper middle of the screen: visible alongside the browser without
        // covering the code field in the center of the page.
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.maxY - size.height - frame.height * 0.16
            ))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Compact content for the sign-in panel: one-line explanation, the code in a
/// selectable chip with a copy icon, and a status/cancel row.
private struct CodexLoginPanelView: View {
    let code: String
    let openPage: () -> Void
    let cancel: () -> Void

    @State private var copied = false

    private static let mint = Color(red: 0.67, green: 0.93, blue: 0.88)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in with ChatGPT")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.white)
            Text("Enter this code on the page that just opened — Nugumi finishes sign-in automatically.")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.white.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Text(code)
                    .font(.system(size: 21, weight: .bold, design: .monospaced))
                    .foregroundStyle(Self.mint)
                    .textSelection(.enabled)
                Button(action: copyCode) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(copied ? Self.mint : Color.white.opacity(0.7))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy code")
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )

            HStack(spacing: 8) {
                Button(action: openPage) {
                    Text("Open page again")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Self.mint)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 12)

                ProgressView()
                    .controlSize(.small)
                Text("Waiting…")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.55))

                Button(action: cancel) {
                    Text("Cancel")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .padding(.vertical, 4)
                        .padding(.horizontal, 10)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
            }
        }
        .padding(16)
        .frame(width: 336)
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            copied = false
        }
    }
}

// MARK: - Main window bridge

extension NugumiApp: SettingsHost {
    var usageStats: UsageStatsStore { usageStatsStore }
    var snippets: SnippetsStore { snippetsStore }
    var history: TranslationHistoryStore { translationHistoryStore }
    var isAppBundle: Bool { isRunningFromAppBundle }
    var appVersionString: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
    }

    func cloudProviderHasCredentials(_ provider: CloudProvider) -> Bool {
        provider.hasCredentials
    }

    var bootstrapState: BootstrapState { bootstrap.state }
    var ollamaModels: [OllamaModelOption] { bootstrap.models }
    var requiresOllamaAccount: Bool { bootstrap.requiresOllamaAccount }

    func makeSettingsSnapshot() -> SettingsSnapshot {
        var styles: [AppCategory: WritingStyle] = [:]
        for category in AppCategory.allCases {
            styles[category] = writingStyle(for: category)
        }
        var shortcuts: [GlobalShortcutAction: GlobalShortcut] = [:]
        for action in GlobalShortcutAction.allCases {
            shortcuts[action] = shortcut(for: action)
        }
        return SettingsSnapshot(
            targetLanguage: targetLanguage,
            draftTargetLanguage: draftTargetLanguage,
            writingToggleAlternate: writingToggleAlternate,
            floatingDefaultMode: floatingDefaultMode,
            selectionDisplayMode: selectionDisplayMode,
            replacementMode: replacementMode,
            cleanupLevel: cleanupLevel,
            genZMode: genZModeEnabled,
            emailVoiceSample: emailVoiceSample,
            invisibilityEnabled: invisibilityModeEnabled,
            writingStyles: styles,
            textModelID: textModelID,
            askNugumiModelID: askNugumiModelID,
            textThinkingLevel: textThinkingLevel,
            askNugumiThinkingLevel: askNugumiThinkingLevel,
            shortcuts: shortcuts,
            appsByCategory: appsByCategory()
        )
    }

    private static let appsMigratedKey = "appCategoryDefaultsMigratedV1"

    /// One-time: fold the built-in `bundleIDMap` defaults into the persisted
    /// assignment list (installed apps only, de-duplicated by name). After this the
    /// strip is built purely from the persisted list, so hardcoded defaults can no
    /// longer collide with user edits — which is what produced duplicate icons (two
    /// Telegram bundle IDs) and apps re-appearing after add/remove.
    private func migrateDefaultAppsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.appsMigratedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.appsMigratedKey)

        var list = customAppAssignments()
        var seenBundles = Set(list.map(\.bundleID))
        var seenNames = Set(list.map { $0.name.lowercased() })
        let suppressed = suppressedBuiltInApps()

        for (bundleID, category) in AppCategoryClassifier.bundleIDMap.sorted(by: { $0.key < $1.key }) {
            guard !suppressed.contains(bundleID),
                  !seenBundles.contains(bundleID),
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            else { continue }
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            guard !seenNames.contains(name.lowercased()) else { continue }
            seenBundles.insert(bundleID)
            seenNames.insert(name.lowercased())
            list.append(CustomAppAssignment(bundleID: bundleID, name: name, category: category))
        }
        saveCustomAppAssignments(list)
    }

    /// Apps shown per category in the Style page — built purely from the persisted
    /// assignment list (defaults migrated in once), de-duplicated by app name so the
    /// same app never shows twice. Icons are resolved lazily in the UI by bundle ID.
    private func appsByCategory() -> [AppCategory: [AppRef]] {
        migrateDefaultAppsIfNeeded()
        var result: [AppCategory: [AppRef]] = [:]
        for category in AppCategory.allCases { result[category] = [] }

        var seenNames: Set<String> = []
        for assignment in customAppAssignments() {
            let nameKey = assignment.name.lowercased()
            guard !seenNames.contains(nameKey) else { continue }
            seenNames.insert(nameKey)
            result[assignment.category, default: []].append(
                AppRef(bundleID: assignment.bundleID, name: assignment.name, isBuiltIn: false)
            )
        }
        for category in result.keys {
            result[category]?.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return result
    }

    /// Presents an open panel scoped to applications so the user can assign any
    /// installed app to a Style category.
    @MainActor
    private func presentAppPicker(for category: AppCategory) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        panel.message = "Choose an app to assign to “\(category.displayName)”."
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier
        else { return }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        addCustomApp(bundleID: bundleID, name: name, category: category)
        mainWindowController?.bridge.refreshFromHost()
    }

    func performSettingsIntent(_ intent: SettingsIntent) {
        switch intent {
        case .setTargetLanguage(let language):
            targetLanguage = language
            translationPanelController?.close()
            translationPanelController = nil
            updateMenuState()
        case .setDraftTargetLanguage(let language):
            draftTargetLanguage = language
            translationPanelController?.close()
            translationPanelController = nil
            updateMenuState()
        case .setWritingToggleAlternate(let language):
            writingToggleAlternate = language
        case .setFloatingDefaultMode(let mode):
            floatingDefaultMode = mode
            petController?.setActionMode(mode.translationMode)
            refreshStatusBarIcon()
            updateMenuState()
        case .setSelectionDisplayMode(let mode):
            selectionDisplayMode = mode
            applySelectionDisplayMode()
        case .setReplacementMode(let mode):
            replacementMode = mode
            updateMenuState()
        case .setCleanupLevel(let level):
            cleanupLevel = level
            updateMenuState()
        case .setGenZMode(let enabled):
            genZModeEnabled = enabled
            updateMenuState()
        case .setEmailVoiceSample(let sample):
            emailVoiceSample = sample
        case .setWritingStyle(let style, let category):
            setWritingStyle(style, for: category)
            updateMenuState()
        case .addAppToCategory(let category):
            presentAppPicker(for: category)
        case .removeApp(let bundleID):
            removeApp(bundleID: bundleID)
        case .setThinkingLevel(let level, let scope):
            guard level != thinkingLevel(for: scope) else { return }
            setThinkingLevel(level, for: scope)
            updateMenuState()
        case .chooseModel(let modelID, let scope):
            let option = LLMModel.option(id: modelID)
            guard option.id != self.modelID(for: scope) else { return }
            if let provider = option.cloudProvider, !provider.hasCredentials {
                presentCredentialPrompt(for: provider) { [weak self] saved in
                    guard let self, saved else { return }
                    self.applyModelSelection(option.id, for: scope)
                }
                return
            }
            applyModelSelection(option.id, for: scope)
        case .toggleInvisibility:
            toggleInvisibilityMode()
        case .recordShortcut(let action):
            presentShortcutRecorder(for: action)
        case .resetShortcuts:
            resetKeyboardShortcuts()
        case .signInCloud(let provider):
            presentCredentialPrompt(for: provider) { [weak self] _ in
                self?.mainWindowController?.bridge.refreshFromHost()
            }
        case .signOutCloud(let provider):
            disconnectCloudProvider(provider)
        case .openOllamaInstall:
            bootstrap.openInstallPage()
        case .launchOllama:
            bootstrap.launchOllamaApp()
        case .openOllamaSignIn:
            bootstrap.openOllamaForSignIn()
        case .refreshBootstrap:
            bootstrap.refresh()
        case .startModelPull(let modelID):
            // Remember the model the user just requested so that when its pull
            // finishes we can auto-promote it to the everyday-text default —
            // mirroring the old onboarding window's onOllamaReady behavior.
            pendingOllamaAutoSelectID = modelID
            bootstrap.startModelPull(for: modelID)
        case .cancelModelPull(let modelID):
            if pendingOllamaAutoSelectID == modelID { pendingOllamaAutoSelectID = nil }
            bootstrap.cancelPull(for: modelID)
        case .checkForUpdates:
            checkForUpdates()
        case .contactSupport:
            contactSupport()
        case .openPermissionsHelp:
            presentPermissionsWindow(force: true)
        case .resetSettings:
            resetSettings()
        case .quit:
            quit()
        }
    }
}

// MARK: - Language toggle HUD

/// Small auto-fading toast shown when the writing language flips via the
/// global shortcut — without it the toggle is invisible to the user. One
/// shared instance so rapid toggles replace the text instead of stacking.
@MainActor
final class LanguageToggleHUD {
    static let shared = LanguageToggleHUD()

    private var panel: NSPanel?
    private var label: NSTextField?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(text: String) {
        dismissTask?.cancel()

        let panel = panel ?? makePanel()
        guard let label else { return }
        label.stringValue = text
        label.sizeToFit()

        let padding = NSSize(width: 22, height: 12)
        let size = NSSize(
            width: label.frame.width + padding.width * 2,
            height: label.frame.height + padding.height * 2
        )
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        panel.setFrame(
            NSRect(
                x: visible.midX - size.width / 2,
                y: visible.maxY - size.height - 60,
                width: size.width,
                height: size.height
            ),
            display: true
        )
        label.frame.origin = NSPoint(x: padding.width, y: padding.height)
        (panel.contentView?.layer)?.cornerRadius = size.height / 2

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }

        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                panel.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor [weak self] in
                    if self?.dismissTask?.isCancelled == false {
                        self?.panel?.orderOut(nil)
                    }
                }
            })
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        // Same liquid-glass material as the main window, so the toast reads
        // as part of the same family.
        let content = NSVisualEffectView()
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.appearance = NSAppearance(named: .darkAqua)
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        content.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        content.layer?.borderWidth = 1

        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        content.addSubview(label)

        panel.contentView = content
        InvisibilityState.apply(to: panel)
        self.panel = panel
        self.label = label
        return panel
    }
}
