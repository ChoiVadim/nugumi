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

enum CloudProvider: String, Codable, CaseIterable {
    case openAI
    case openAICodex
    case anthropic
    case gemini
    case openRouter
    /// Anthropic Claude subscription (Pro/Max) via Claude Code OAuth. Uses a
    /// Bearer OAuth token against the *native* /v1/messages API, not the
    /// OpenAI-compat endpoint `.anthropic` uses. See `ClaudeCodeClient`.
    case anthropicClaudeCode

    /// OAuth (subscription) providers use a sign-in flow instead of an API key
    /// — branches that present the API-key sheet must consult this flag.
    var usesOAuth: Bool {
        switch self {
        case .openAICodex, .anthropicClaudeCode: true
        case .openAI, .anthropic, .gemini, .openRouter: false
        }
    }

    var baseURL: URL {
        switch self {
        case .openAI:      URL(string: "https://api.openai.com/v1/chat/completions")!
        case .openAICodex: URL(string: "https://chatgpt.com/backend-api/codex/responses")!
        case .anthropic:   URL(string: "https://api.anthropic.com/v1/chat/completions")!
        case .gemini:      URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
        case .openRouter:  URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        case .anthropicClaudeCode: URL(string: "https://api.anthropic.com/v1/messages")!
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
        case .openAICodex: "Codex"
        case .anthropic:   "Anthropic"
        case .gemini:      "Google"
        case .openRouter:  "OpenRouter"
        case .anthropicClaudeCode: "Claude Code"
        }
    }

    var apiKeyHelpURL: URL {
        switch self {
        case .openAI:      URL(string: "https://platform.openai.com/api-keys")!
        case .openAICodex: URL(string: "https://chatgpt.com/")!
        case .anthropic:   URL(string: "https://console.anthropic.com/settings/keys")!
        case .gemini:      URL(string: "https://aistudio.google.com/app/apikey")!
        case .openRouter:  URL(string: "https://openrouter.ai/keys")!
        case .anthropicClaudeCode: URL(string: "https://claude.ai")!
        }
    }

    var modelsURL: URL {
        switch self {
        case .openAI:      URL(string: "https://api.openai.com/v1/models")!
        case .openAICodex: URL(string: "https://chatgpt.com/backend-api/codex/models?client_version=1.0.0")!
        case .anthropic:   URL(string: "https://api.anthropic.com/v1/models")!
        case .gemini:      URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/models")!
        case .openRouter:  URL(string: "https://openrouter.ai/api/v1/models")!
        case .anthropicClaudeCode: URL(string: "https://api.anthropic.com/v1/models")!
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
        case .openAI, .gemini, .openAICodex, .openRouter, .anthropicClaudeCode:
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
                let reason = CloudHTTPError.extractMessage(from: data)
                    ?? CloudHTTPError.friendlyMessage(status: http.statusCode)
                return .invalid(reason: "\(provider.displayName): \(reason)")
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

    static let storageDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // Stays "Nugumi" across the Gizmate rename: API keys and OAuth creds are
        // plain files in here, so renaming the directory signs every existing
        // user out of every provider. Cosmetics are not worth that.
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

/// One-time acknowledgement that a chat summary sent through a cloud backend
/// leaves the device (and may include other people's messages). Local Ollama
/// summaries never consult this — nothing leaves the machine. Persisted so
/// the modal only shows once per install, not once per summary.
enum SummaryConsent {
    private static let key = "summary.cloudConsentAccepted"
    static var accepted: Bool {
        get { value(forKey: key) }
        set { set(newValue, forKey: key) }
    }
    static func value(forKey k: String) -> Bool { UserDefaults.standard.bool(forKey: k) }
    static func set(_ v: Bool, forKey k: String) { UserDefaults.standard.set(v, forKey: k) }
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
        history: [AskGizmateTurn],
        question: String,
        image: ImageInput?,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> AskGizmateResponse

    /// One shot with a caller-supplied system prompt and no Gizmate persona,
    /// returning the model's text verbatim. `ask` can't serve this: it injects
    /// `AskGizmatePromptBuilder.systemPrompt` and post-processes through
    /// `AskGizmateResponse.parse`, both of which would mangle a tool manifest.
    func complete(
        systemPrompt: String,
        userPrompt: String,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> String
}

/// Turns a non-2xx cloud HTTP response into a human sentence instead of a bare
/// "HTTP 402". Prefers the provider's own error message from the JSON body
/// (OpenAI-compat `{"error":{"message":...}}`), falling back to a friendly
/// status-code map. Shared by every cloud client so the Test result and the
/// Ask Gizmate error pill read the same way.
enum CloudHTTPError {
    /// The provider's own error message from a JSON error body, if present.
    static func extractMessage(from data: Data?) -> String? {
        guard let data, !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let err = obj["error"] as? [String: Any],
           let m = err["message"] as? String, !m.isEmpty { return m }
        if let s = obj["error"] as? String, !s.isEmpty { return s }
        if let m = obj["message"] as? String, !m.isEmpty { return m }
        return nil
    }

    /// Friendly fallback for a status the caller didn't map to a more specific
    /// TranslationError (401/403 → invalidAPIKey, 429 → rateLimited are handled
    /// before this). Phrased to read after "Provider: " — cloudError prepends
    /// the provider name.
    static func friendlyMessage(status: Int) -> String {
        switch status {
        case 400: return "Couldn't process that request. Try shorter text or another model."
        case 402: return "You're out of credits. Add funds to use paid models - free models still work."
        case 404: return "That model isn't available right now. Pick another in settings."
        case 408: return "The request timed out. Try again."
        case 413: return "The text or image is too large for this model."
        case 500, 502, 503, 504, 529: return "Their server had a problem. Try again in a moment."
        default: return "Unexpected error (HTTP \(status))."
        }
    }

    /// Best available detail: the provider's own message, else the friendly map.
    static func detail(status: Int, body: Data?) -> String {
        extractMessage(from: body) ?? friendlyMessage(status: status)
    }

    /// Drain a (small) error-response byte stream into Data for `detail`. Capped
    /// so a misbehaving endpoint can't stream forever into an error message.
    static func readBody(_ bytes: URLSession.AsyncBytes, cap: Int = 16 * 1024) async -> Data? {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= cap { break }
            }
        } catch { return data.isEmpty ? nil : data }
        return data.isEmpty ? nil : data
    }
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
    case outOfCredits(CloudProvider)
    case cloudError(CloudProvider, String)

    /// True for failures that prove the key authenticated (the provider is
    /// reachable and the credentials are valid) but the request couldn't run —
    /// out of credits or rate-limited. The connectivity test treats these as
    /// "connected", not a broken key.
    var provesCredentialsValid: Bool {
        switch self {
        case .rateLimited, .outOfCredits: return true
        default: return false
        }
    }

    /// Every backend throws these, and translating is only one of the things
    /// they are asked to do — the same failures reach Ask and the tool builder.
    /// So the text says what is actually wrong (the model) rather than naming a
    /// feature the user may not have been using: "the translator isn't running"
    /// is a confusing thing to read after asking for a tool.
    var errorDescription: String? {
        switch self {
        case .ollama(let message):
            "The model request failed: \(message)"
        case .emptyResponse:
            "The model returned nothing. Try again."
        case .serverUnavailable:
            "The local model isn't running. Open setup to fix it."
        case .modelMissing:
            "The local model isn't downloaded yet. Open setup to download it."
        case .signInRequired:
            "Sign in to Ollama to use its hosted models. Open setup to finish."
        case .modelDownloading(let detail):
            "\(detail) Try again when the model is ready."
        case .invalidAPIKey(let provider):
            "\(provider.displayName) rejected the API key. Open settings to update it."
        case .rateLimited(let provider):
            "\(provider.displayName) rate limit reached. Try again in a minute, or switch model."
        case .outOfCredits(let provider):
            "\(provider.displayName) is out of credits. Add funds to use paid models - free models still work."
        case .cloudError(let provider, let detail):
            "\(provider.displayName): \(detail)"
        }
    }
}

// MARK: - OpenAI Codex (ChatGPT subscription) OAuth
//
// Lets ChatGPT Plus/Pro subscribers use Gizmate without an OpenAI API key.
// The flow mirrors what the official Codex CLI does (and what Hermes Agent
// replicates): OAuth device-code login against auth.openai.com, then inference
// against chatgpt.com/backend-api/codex/responses (the Responses API, not the
// public /v1/chat/completions surface).
//
// IMPORTANT: this endpoint is unofficial. The same client_id and Cloudflare
// allow-listed `originator` header are shared with Codex CLI; OpenAI could
// tighten the allow-list at any time and break this backend.

extension CloudProvider {
    /// True if the user has saved credentials for this provider (API key OR OAuth tokens).
    var hasCredentials: Bool {
        switch self {
        case .openAICodex:
            return KeychainStore.codexCredentials() != nil
        case .anthropicClaudeCode:
            return KeychainStore.claudeCodeCredentials() != nil
        case .openAI, .anthropic, .gemini, .openRouter:
            let key = KeychainStore.apiKey(for: self)
            return !(key?.isEmpty ?? true)
        }
    }

    /// Order in which providers appear in the onboarding wizard's Cloud tab.
    /// ChatGPT subscription (OAuth) first — it's the most-friction-free
    /// option for users who already have a ChatGPT account — followed by
    /// the API-key providers in their declaration order.
    static var cloudOnboardingCases: [CloudProvider] {
        // OAuth/subscription providers first (most-friction-free for users who
        // already have an account), then the API-key providers in declaration
        // order. usesOAuth providers must be listed explicitly since the filter
        // below excludes them.
        [.openAICodex, .anthropicClaudeCode] + allCases.filter { !$0.usesOAuth }
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
        case .openRouter:  "openai/gpt-5.4-mini"
        case .anthropicClaudeCode: "claude-code/claude-haiku-4-5-20251001"
        }
    }

    /// Default model ID for Ask Gizmate (the multimodal scope) when this
    /// provider's credentials get set during onboarding. Picks the flagship
    /// vision model from the provider's lineup.
    var preferredAskModelID: String {
        switch self {
        case .openAICodex: "codex/gpt-5.5"
        case .openAI:      "gpt-5.5"
        case .anthropic:   "claude-sonnet-4-6"
        case .gemini:      "gemini-2.5-pro"
        case .openRouter:  "google/gemini-2.5-pro"
        case .anthropicClaudeCode: "claude-code/claude-sonnet-4-6"
        }
    }
}

// MARK: Codex diagnostics log

