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

enum MenuItemTag: Int {
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
    case keyboardShortcuts = 121
    case translateOrReplySelection = 122
    case resetSettings = 123
    case invisibilityMode = 124
    case contactSupport = 125
    case permissionsOnboarding = 126
    case mainWindow = 127
    case liveTranslation = 128
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
        // Cloud API-key providers (OpenAI, Anthropic, Gemini, OpenRouter) carry
        // NO hardcoded models — their catalogs come entirely from each provider's
        // /models call (see cloudModels(for:) / CloudModelCache). Until a key is
        // added and discovery runs, these picker sections are simply empty.
        // Subscription engines with no /models endpoint keep curated entries:
        // Claude Code below, and ChatGPT via CodexModelCache.fallbackSlugs.
        // Claude Code (Pro/Max subscription via OAuth — native /v1/messages).
        // Curated only: the OAuth scope is inference-only, so /models isn't
        // fetched for this provider (excluded from discovery).
        // Distinct ids (mirrors the codex/ prefix) so these never collide with
        // the .anthropic API-key Claude entries above — same model, different
        // backend. apiModelID keeps the real name sent to /v1/messages.
        .init(id: "claude-code/claude-haiku-4-5-20251001", apiModelID: "claude-haiku-4-5-20251001", shortName: "Claude Haiku 4.5",  displayName: "Claude Haiku 4.5 (fast)", backend: .cloud(.anthropicClaudeCode), supportsImages: true),
        .init(id: "claude-code/claude-sonnet-4-6",         apiModelID: "claude-sonnet-4-6",         shortName: "Claude Sonnet 4.6", displayName: "Claude Sonnet 4.6",       backend: .cloud(.anthropicClaudeCode), supportsImages: true),
        .init(id: "claude-code/claude-opus-4-8",           apiModelID: "claude-opus-4-8",           shortName: "Claude Opus 4.8",   displayName: "Claude Opus 4.8 (top)",   backend: .cloud(.anthropicClaudeCode), supportsImages: true),
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

    /// Picker list for one cloud provider: once /models discovery has run,
    /// exactly the models it returned (deduped, in response order). Before the
    /// first successful fetch, the curated floor from LLMModel.all.
    static func cloudModels(for provider: CloudProvider) -> [LLMModel] {
        mergedCloudModels(
            provider: provider,
            curated: models(for: provider),
            discovered: CloudModelCache.discovered(for: provider)
        )
    }

    /// Pure resolver (testable without UserDefaults). When discovery has run,
    /// returns ONLY the discovered models — no curated merge — in response
    /// order, deduped by canonical id (a dated + undated alias collapse to
    /// one). Claude Code shares model ids with the .anthropic provider, so its
    /// ids get a `claude-code/` prefix while apiModelID stays the bare id sent
    /// to /v1/messages. Defaults to supportsImages (the backend rejects images
    /// for text-only models; hiding usable models is worse). `discovered == nil`
    /// (never fetched) → curated floor unchanged.
    static func mergedCloudModels(
        provider: CloudProvider,
        curated: [LLMModel],
        discovered: [CloudModelDiscovery.DiscoveredModel]?
    ) -> [LLMModel] {
        guard let discovered, !discovered.isEmpty else { return curated }
        var seen = Set<String>()
        var out: [LLMModel] = []
        for model in discovered {
            guard seen.insert(CloudModelDiscovery.canonicalID(model.id)).inserted else { continue }
            let name = model.displayName
                ?? CloudModelDiscovery.prettyName(provider: provider, id: model.id)
            let id = provider == .anthropicClaudeCode ? "claude-code/\(model.id)" : model.id
            out.append(LLMModel(
                id: id,
                apiModelID: model.id,
                shortName: name,
                displayName: name,
                backend: .cloud(provider),
                supportsImages: true
            ))
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

    static var localOllamaModels: [LLMModel] {
        ollamaModels.filter { !$0.isCloud }
    }

    static var ollamaCloudModels: [LLMModel] {
        ollamaModels.filter(\.isCloud)
    }

    /// Ollama cloud models served on the free tier (with usage limits), keyed by
    /// `shortName` so it matches both the curated entry and a discovered
    /// `-cloud`/`:cloud` tag (the suffix is stripped from shortName). Every other
    /// Ollama cloud model needs a paid Ollama plan.
    /// ponytail: hardcoded allowlist of one; widen if Ollama frees more models.
    static let freeOllamaCloudShortNames: Set<String> = ["gpt-oss:120b"]

    /// True for an Ollama cloud model that needs a *paid* Ollama plan — a free
    /// account isn't enough. Local models and free-tier cloud models are false.
    var requiresPaidOllamaPlan: Bool {
        guard isOllama, isCloud else { return false }
        return !LLMModel.freeOllamaCloudShortNames.contains(shortName)
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
        for provider in [CloudProvider.openAI, .anthropic, .gemini, .openRouter, .anthropicClaudeCode] {
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
            // No hardcoded cloud flagship anymore — the first vision-capable
            // model in `all` (Gemma 4 locally, or a curated Claude Code model)
            // is the safe default until the user picks one.
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
        case .cloud(.anthropicClaudeCode):
            return scope == .textActions ? "claude-code/claude-sonnet-4-6" : "claude-code/claude-opus-4-8"
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
        case .cloud(let provider):
            // Discovery-only providers (OpenAI, Anthropic API key, Gemini,
            // OpenRouter): no hardcoded default — point at the first model the
            // API actually returned. nil until discovery lands, so applyEngine-
            // Preset leaves the slot put instead of jumping to a missing model.
            let models = LLMModel.cloudModels(for: provider)
            switch scope {
            case .textActions: return models.first?.id
            case .askNugumi:   return (models.first(where: \.supportsImages) ?? models.first)?.id
            }
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
    static let defaultDraftLanguage = all.first { $0.id == "en" } ?? defaultLanguage

    static func language(id: String) -> TranslationLanguage {
        all.first { $0.id == id } ?? defaultLanguage
    }
}

/// Launch-at-login via the native ServiceManagement API (macOS 13+). The app
/// bundle registers *itself* as the login item — no separate helper target.
/// Callers MUST gate on `isRunningFromAppBundle`: `SMAppService` is meaningless
/// under `swift run` (no bundle) and the registration would point at the
/// transient `.build` binary.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            NSLog("[Nugumi] Launch-at-login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
    }
}

