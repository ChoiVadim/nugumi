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
            // Surface every returned model except the review-only variants
            // (codex-auto-review) — they're not chat models and error if picked
            // for translation.
            if slug.contains("auto-review") { continue }
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

    /// Substrings that mark an OpenAI id as non-chat or Codex-only. `-pro`
    /// models (gpt-5-pro, gpt-5.2-pro, …) are Responses-API-only and reject
    /// /v1/chat/completions with "not a chat model" — our client only speaks
    /// chat/completions, so drop them.
    private static let openAIDropMarkers = [
        "-audio", "-realtime", "-search", "-tts", "-transcribe", "-image", "-codex", "-pro"
    ]
    /// Substrings that mark a Gemini id as non-chat. Dash-anchored so a
    /// marker can't match inside an unrelated word (e.g. "-live" skips
    /// "gemini-live-2.5-flash" but not a hypothetical "gemini-alive").
    private static let geminiDropMarkers = [
        "-embedding", "-tts", "-image", "-live", "-audio"
    ]
    /// OpenRouter lists 300+ models. Keep recognizable chat vendors plus ANY
    /// `:free` model (free-ness is its own reason to surface it), and drop
    /// non-chat variants so the picker isn't flooded.
    private static let openRouterVendorAllowlist = [
        "openai/", "anthropic/", "google/", "x-ai/", "meta-llama/",
        "mistralai/", "deepseek/", "qwen/"
    ]
    private static let openRouterDropMarkers = [
        "-image", "-tts", "-audio", "-embedding",
        "-search", "-realtime", "-transcribe", "-codex"
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
            case .anthropic, .anthropicClaudeCode:
                guard id.hasPrefix("claude-") else { continue }
            case .gemini:
                if id.hasPrefix("models/") { id = String(id.dropFirst("models/".count)) }
                guard id.hasPrefix("gemini-"),
                      !geminiDropMarkers.contains(where: id.contains)
                else { continue }
            case .openRouter:
                let isFree = id.hasSuffix(":free")
                guard isFree || openRouterVendorAllowlist.contains(where: id.hasPrefix),
                      !openRouterDropMarkers.contains(where: id.contains)
                else { continue }
            case .openAICodex:
                // ChatGPT subscription uses its own codex/models endpoint
                // (CodexModelDiscovery), not the OpenAI /v1/models list.
                continue
            }
            // OpenRouter supplies a pretty `name`; the others use `display_name`.
            var pretty = (provider == .openRouter ? item["name"] : item["display_name"]) as? String
            // Tag free models so the picker shows it. OpenRouter's `name` almost
            // always already ends in "(free)" — guarantee it when it doesn't.
            if provider == .openRouter, id.hasSuffix(":free") {
                let base = pretty ?? id
                pretty = base.lowercased().contains("free") ? base : "\(base) (free)"
            }
            out.append(DiscoveredModel(id: id, displayName: pretty))
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
        case .anthropic, .anthropicClaudeCode:
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
        case .openRouter:
            // ids are "vendor/model"; the API's `name` is preferred upstream,
            // so this fallback only fires if `name` is absent — the slug reads
            // well enough.
            return id
        }
    }

    /// Launch-time refresh for every provider with a stored key. Best-effort:
    /// any failure (no key, network, non-200, unparseable body) leaves the
    /// cache untouched. Same contract as CodexModelDiscovery.refreshFromAPI.
    static func refreshAll() async {
        // KeychainStore's in-memory cache is main-actor-confined everywhere
        // else; read the keys there, then do the network work off-actor.
        let credentials: [(CloudProvider, String)] = await MainActor.run {
            [CloudProvider.openAI, .anthropic, .gemini, .openRouter].compactMap { provider in
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
        await refreshClaudeCode()
    }

    /// Claude Code (OAuth subscription) has no dedicated models endpoint, so
    /// try the standard Anthropic /v1/models with the OAuth bearer + Claude Code
    /// headers. If the inference-only OAuth scope forbids the list call, the
    /// request 401s (or the body is unparseable) and the cache is left
    /// untouched — the curated Claude Code entries in LLMModel.all stay the
    /// floor. No-ops silently when the user isn't signed in.
    static func refreshClaudeCode() async {
        let token: String
        do {
            token = try await ClaudeCodeCredentialBroker.resolveAccessToken()
        } catch {
            return
        }
        var request = URLRequest(url: CloudProvider.anthropicClaudeCode.modelsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-cli/2.0.0 (external, cli)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              let http = resp as? HTTPURLResponse, http.statusCode == 200
        else { return }
        CloudModelCache.update(
            provider: .anthropicClaudeCode,
            models: parse(provider: .anthropicClaudeCode, data: data)
        )
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
    static let updateAvailabilityChanged = Notification.Name("com.nugumi.updateAvailabilityChanged")
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
    /// vision-only Ask Gizmo picker.
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

