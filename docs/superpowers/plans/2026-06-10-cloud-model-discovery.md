# Cloud Model Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The OpenAI / Anthropic / Google sections of the model picker reflect what each provider's `/models` endpoint actually serves — new chat models appear automatically, retired ids disappear — while the hardcoded curated list stays as fallback and as the source of pretty names.

**Architecture:** Mirror the existing `CodexModelCache` + `CodexModelDiscovery` pattern (live fetch → UserDefaults cache → curated fallback) for the three API-key providers. Pure, network-free parse and merge functions carry all the logic; thin wrappers wire them to `URLSession`, `KeychainStore`, and `NotificationCenter`. Spec: `docs/superpowers/specs/2026-06-10-cloud-model-discovery-design.md`.

**Tech Stack:** Swift / AppKit, SwiftPM, XCTest. No new dependencies.

**Codebase notes for the implementer:**

- Almost everything lives in `Sources/Nugumi/App.swift` — this is intentional (see CLAUDE.md). Do NOT create new source files.
- Build/test: `swift build` and `swift test` from the repo root. Tests are XCTest (`Tests/NugumiTests/`).
- Existing precedents to read first: `CodexModelCache` (App.swift ~line 11889), `CodexModelDiscovery` (~11934), `OllamaModelCache` (~11990), `LLMModel` (~73), `CloudProvider` (~10502), `APIKeyValidator` (~10560).
- The working tree has unrelated in-progress changes (Onboarding work). Only `git add` the specific files each task names — never `git add -A`.

---

### Task 1: Pure parsing — `CloudModelDiscovery.parse`

Parse each provider's `/models` JSON into `[DiscoveredModel]`, applying the family filters from the spec.

**Files:**

- Modify: `Sources/Nugumi/App.swift` (new code after the `CodexModelDiscovery` enum, ~line 11976)
- Test: `Tests/NugumiTests/CloudModelDiscoveryTests.swift` (new test file — test files are fine to add; the single-file rule covers `Sources/` only)

- [ ] **Step 1: Write the failing tests**

Create `Tests/NugumiTests/CloudModelDiscoveryTests.swift`:

```swift
import XCTest
@testable import Nugumi

final class CloudModelDiscoveryTests: XCTestCase {

    // MARK: Parsing

    func testOpenAIParseKeepsChatModelsAndDropsNoise() {
        let json = """
        {"object":"list","data":[
            {"id":"gpt-5.5","object":"model"},
            {"id":"gpt-5.4-mini","object":"model"},
            {"id":"gpt-5.6","object":"model"},
            {"id":"gpt-5.4-audio","object":"model"},
            {"id":"gpt-5.3-codex","object":"model"},
            {"id":"gpt-realtime","object":"model"},
            {"id":"whisper-1","object":"model"},
            {"id":"tts-1","object":"model"},
            {"id":"dall-e-3","object":"model"},
            {"id":"text-embedding-3-small","object":"model"},
            {"id":"gpt-4o","object":"model"}
        ]}
        """.data(using: .utf8)!

        let parsed = CloudModelDiscovery.parse(provider: .openAI, data: json)

        XCTAssertEqual(parsed.map(\.id), ["gpt-5.5", "gpt-5.4-mini", "gpt-5.6"])
    }

    func testAnthropicParseCarriesDisplayName() {
        let json = """
        {"data":[
            {"id":"claude-opus-4-8","display_name":"Claude Opus 4.8","type":"model"},
            {"id":"claude-sonnet-4-6","display_name":"Claude Sonnet 4.6","type":"model"},
            {"id":"claude-haiku-4-5-20251001","display_name":"Claude Haiku 4.5","type":"model"}
        ],"has_more":false}
        """.data(using: .utf8)!

        let parsed = CloudModelDiscovery.parse(provider: .anthropic, data: json)

        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed[0].id, "claude-opus-4-8")
        XCTAssertEqual(parsed[0].displayName, "Claude Opus 4.8")
    }

    func testGeminiParseStripsPrefixAndDropsNonChatVariants() {
        let json = """
        {"object":"list","data":[
            {"id":"models/gemini-2.5-pro","object":"model"},
            {"id":"models/gemini-3.0-flash","object":"model"},
            {"id":"models/gemini-embedding-001","object":"model"},
            {"id":"models/gemini-2.5-flash-preview-tts","object":"model"},
            {"id":"models/gemini-2.5-flash-image","object":"model"},
            {"id":"models/gemini-live-2.5-flash","object":"model"},
            {"id":"models/imagen-4.0-generate-001","object":"model"}
        ]}
        """.data(using: .utf8)!

        let parsed = CloudModelDiscovery.parse(provider: .gemini, data: json)

        XCTAssertEqual(parsed.map(\.id), ["gemini-2.5-pro", "gemini-3.0-flash"])
    }

    func testParseReturnsEmptyOnGarbageAndOnCodexProvider() {
        let garbage = "not json".data(using: .utf8)!
        XCTAssertTrue(CloudModelDiscovery.parse(provider: .openAI, data: garbage).isEmpty)

        let valid = #"{"data":[{"id":"gpt-5.5"}]}"#.data(using: .utf8)!
        XCTAssertTrue(CloudModelDiscovery.parse(provider: .openAICodex, data: valid).isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CloudModelDiscoveryTests 2>&1 | tail -20`
Expected: compile error — `CloudModelDiscovery` has no member `parse` / no type `DiscoveredModel`.

- [ ] **Step 3: Implement `parse`**

In `Sources/Nugumi/App.swift`, directly **after** the closing brace of `enum CodexModelDiscovery` (before `extension Notification.Name`), add:

```swift
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
    /// Substrings that mark a Gemini id as non-chat.
    private static let geminiDropMarkers = [
        "embedding", "tts", "image", "live", "audio"
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
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CloudModelDiscoveryTests 2>&1 | tail -5`
Expected: `Executed 4 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/Nugumi/App.swift Tests/NugumiTests/CloudModelDiscoveryTests.swift
git commit -m "feat: parse cloud provider /models responses into chat model lists"
```

---

### Task 2: Canonical ids + generated display names

Two pure helpers on `CloudModelDiscovery`: date-suffix-tolerant id matching, and pretty-name generation for discovered models that have no curated entry.

**Files:**

- Modify: `Sources/Nugumi/App.swift` (inside `enum CloudModelDiscovery` from Task 1)
- Test: `Tests/NugumiTests/CloudModelDiscoveryTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `CloudModelDiscoveryTests`:

```swift
    // MARK: Canonical ids

    func testCanonicalIDStripsTrailingDateStamp() {
        XCTAssertEqual(
            CloudModelDiscovery.canonicalID("claude-haiku-4-5-20251001"),
            "claude-haiku-4-5"
        )
        XCTAssertEqual(CloudModelDiscovery.canonicalID("claude-opus-4-8"), "claude-opus-4-8")
        XCTAssertEqual(CloudModelDiscovery.canonicalID("gpt-5.5"), "gpt-5.5")
    }

    // MARK: Generated names

    func testPrettyNameForOpenAIIDs() {
        XCTAssertEqual(CloudModelDiscovery.prettyName(provider: .openAI, id: "gpt-5.6"), "GPT-5.6")
        XCTAssertEqual(CloudModelDiscovery.prettyName(provider: .openAI, id: "gpt-5.6-mini"), "GPT-5.6 mini")
    }

    func testPrettyNameForAnthropicIDs() {
        XCTAssertEqual(
            CloudModelDiscovery.prettyName(provider: .anthropic, id: "claude-opus-4-8"),
            "Claude Opus 4.8"
        )
        XCTAssertEqual(
            CloudModelDiscovery.prettyName(provider: .anthropic, id: "claude-haiku-4-5-20251001"),
            "Claude Haiku 4.5"
        )
    }

    func testPrettyNameForGeminiIDs() {
        XCTAssertEqual(
            CloudModelDiscovery.prettyName(provider: .gemini, id: "gemini-3.0-pro"),
            "Gemini 3.0 Pro"
        )
        XCTAssertEqual(
            CloudModelDiscovery.prettyName(provider: .gemini, id: "gemini-2.5-flash-lite"),
            "Gemini 2.5 Flash Lite"
        )
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CloudModelDiscoveryTests 2>&1 | tail -20`
Expected: compile error — no member `canonicalID` / `prettyName`.

- [ ] **Step 3: Implement both helpers**

Add inside `enum CloudModelDiscovery`:

```swift
    /// Anthropic pins releases with a trailing -YYYYMMDD date stamp
    /// (claude-haiku-4-5-20251001). Strip it so a curated dated id and the
    /// API's undated alias (or vice versa) compare equal.
    static func canonicalID(_ id: String) -> String {
        let parts = id.split(separator: "-")
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
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
                if part.allSatisfy(\.isNumber), let last = words.last,
                   last.allSatisfy({ $0.isNumber || $0 == "." }) {
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
```

Note: `"4".capitalized == "4"`, so Anthropic's numeric parts survive `capitalized`; the dot-joining branch checks `words.last` so "Claude Opus" never absorbs digits.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CloudModelDiscoveryTests 2>&1 | tail -5`
Expected: `Executed 8 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/Nugumi/App.swift Tests/NugumiTests/CloudModelDiscoveryTests.swift
git commit -m "feat: canonical cloud model ids and generated display names"
```

---

### Task 3: `CloudModelCache` — per-provider persisted cache

Thread-safe per-provider cache, same shape as `CodexModelCache`, plus the new `.cloudModelsUpdated` notification.

**Files:**

- Modify: `Sources/Nugumi/App.swift` (new enum before `CloudModelDiscovery`; new case in the `Notification.Name` extension ~line 11978)

No unit test for the cache itself — it is UserDefaults + NSLock plumbing identical to the already-shipped `CodexModelCache`, and tests sharing `UserDefaults.standard` would be order-dependent. The pure merge logic it feeds is tested in Task 4. (Same trade-off the codebase already made for `CodexModelCache` / `OllamaModelCache`.)

- [ ] **Step 1: Implement the cache**

In `Sources/Nugumi/App.swift`, insert **between** `CodexModelDiscovery`'s closing brace and the `// MARK: Discovered API-key cloud models` block from Task 1:

```swift
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
        lock.unlock()
        guard changed else { return }
        UserDefaults.standard.set(ids, forKey: idsKey(provider))
        UserDefaults.standard.set(names, forKey: namesKey(provider))
        NotificationCenter.default.post(name: .cloudModelsUpdated, object: nil)
    }
}
```

The `guard !models.isEmpty` is the spec's defense: an unrecognized payload must never wipe the picker down to nothing.

- [ ] **Step 2: Add the notification name**

In the existing `extension Notification.Name` (App.swift ~line 11978), add:

```swift
    static let cloudModelsUpdated = Notification.Name("com.nugumi.cloud.modelsUpdated")
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/Nugumi/App.swift
git commit -m "feat: persisted per-provider cache for discovered cloud models"
```

---

### Task 4: Merge logic — `LLMModel.cloudModels(for:)`

Curated entries first (dead ids hidden), fresh discovered ids appended with generated names. Pure function + thin cache-reading wrapper.

**Files:**

- Modify: `Sources/Nugumi/App.swift` (inside `struct LLMModel`, after `models(for:)` ~line 142; and `option(id:)` ~line 212)
- Test: `Tests/NugumiTests/CloudModelDiscoveryTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `CloudModelDiscoveryTests`:

```swift
    // MARK: Merge

    private let curatedAnthropic = LLMModel.models(for: .anthropic)

    func testMergeNeverFetchedReturnsCuratedUnchanged() {
        let merged = LLMModel.mergedCloudModels(
            provider: .anthropic, curated: curatedAnthropic, discovered: nil
        )
        XCTAssertEqual(merged, curatedAnthropic)
    }

    func testMergeKeepsCuratedNamesAndOrderForConfirmedModels() {
        let discovered: [CloudModelDiscovery.DiscoveredModel] = [
            .init(id: "claude-opus-4-7", displayName: "Claude Opus 4.7"),
            .init(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6"),
            .init(id: "claude-haiku-4-5-20251001", displayName: "Claude Haiku 4.5"),
        ]
        let merged = LLMModel.mergedCloudModels(
            provider: .anthropic, curated: curatedAnthropic, discovered: discovered
        )
        XCTAssertEqual(merged, curatedAnthropic)
        XCTAssertEqual(merged.first?.displayName, "Claude Haiku 4.5 (fast)")
    }

    func testMergeHidesCuratedModelAbsentFromFetch() {
        let discovered: [CloudModelDiscovery.DiscoveredModel] = [
            .init(id: "claude-sonnet-4-6", displayName: nil),
            .init(id: "claude-haiku-4-5-20251001", displayName: nil),
        ]
        let merged = LLMModel.mergedCloudModels(
            provider: .anthropic, curated: curatedAnthropic, discovered: discovered
        )
        XCTAssertFalse(merged.contains { $0.id == "claude-opus-4-7" })
        XCTAssertEqual(merged.count, 2)
    }

    func testMergeMatchesCuratedDatedIdAgainstUndatedFetch() {
        // Curated claude-haiku-4-5-20251001 must survive a fetch reporting
        // the undated alias claude-haiku-4-5.
        let discovered: [CloudModelDiscovery.DiscoveredModel] = [
            .init(id: "claude-haiku-4-5", displayName: nil),
            .init(id: "claude-sonnet-4-6", displayName: nil),
            .init(id: "claude-opus-4-7", displayName: nil),
        ]
        let merged = LLMModel.mergedCloudModels(
            provider: .anthropic, curated: curatedAnthropic, discovered: discovered
        )
        XCTAssertEqual(merged, curatedAnthropic)
    }

    func testMergeAppendsFreshModelsWithGeneratedNamesNewestFirst() {
        let discovered: [CloudModelDiscovery.DiscoveredModel] = [
            .init(id: "claude-haiku-4-5-20251001", displayName: nil),
            .init(id: "claude-sonnet-4-6", displayName: nil),
            .init(id: "claude-opus-4-7", displayName: nil),
            .init(id: "claude-opus-4-8", displayName: "Claude Opus 4.8 (API)"),
            .init(id: "claude-magnum-5-0", displayName: nil),
        ]
        let merged = LLMModel.mergedCloudModels(
            provider: .anthropic, curated: curatedAnthropic, discovered: discovered
        )
        XCTAssertEqual(Array(merged.prefix(3)), curatedAnthropic)

        let fresh = Array(merged.dropFirst(3))
        XCTAssertEqual(fresh.map(\.id), ["claude-opus-4-8", "claude-magnum-5-0"])
        // API display_name wins when present; generated otherwise.
        XCTAssertEqual(fresh[0].displayName, "Claude Opus 4.8 (API)")
        XCTAssertEqual(fresh[1].displayName, "Claude Magnum 5.0")
        XCTAssertTrue(fresh.allSatisfy(\.supportsImages))
        XCTAssertTrue(fresh.allSatisfy { $0.cloudProvider == .anthropic })
    }

    func testOptionResolvesDiscoveredCloudID() {
        // mergedCloudModels output must be reachable via LLMModel.option(id:)
        // when the cache holds it; with an empty cache option() falls back.
        let fallback = LLMModel.option(id: "claude-magnum-5-0")
        XCTAssertNotNil(fallback) // degrades to defaultModel, never crashes
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CloudModelDiscoveryTests 2>&1 | tail -20`
Expected: compile error — `LLMModel` has no member `mergedCloudModels`.

- [ ] **Step 3: Implement merge + wrapper + option(id:) hook**

In `struct LLMModel`, after `models(for:)` (~line 142), add:

```swift
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
    /// sort descending by id — within one provider's naming scheme that puts
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
            .sorted { $0.id > $1.id }
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
```

In `option(id:)` (~line 212), insert a cloud resolution step after the curated lookup and **before** the Ollama lookup:

```swift
        if let curated = all.first(where: { $0.id == id }) { return curated }
        // Discovered cloud models live outside `all`; resolve them so backend
        // dispatch and the menu label can find them (mirrors Ollama below).
        for provider in [CloudProvider.openAI, .anthropic, .gemini] {
            if let cloud = cloudModels(for: provider).first(where: { $0.id == id }) {
                return cloud
            }
        }
        if let ollama = ollamaModels.first(where: { $0.id == id }) { return ollama }
```

- [ ] **Step 4: Run the full test suite**

Run: `swift test 2>&1 | tail -5`
Expected: 0 failures (existing `ModelRoutingTests` must stay green — merge with `discovered: nil` is identity, so curated behavior is unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/Nugumi/App.swift Tests/NugumiTests/CloudModelDiscoveryTests.swift
git commit -m "feat: merge discovered cloud models into the curated picker list"
```

---

### Task 5: Wire refresh triggers + picker + notification

Feed the cache from `APIKeyValidator` (key entry), refresh at launch, point the picker at `cloudModels(for:)`, re-render on update.

**Files:**

- Modify: `Sources/Nugumi/App.swift` — `APIKeyValidator.validate` (~line 10567), `applicationDidFinishLaunching` (~line 1181), `CloudModelDiscovery` (add `refreshAll`)
- Modify: `Sources/Nugumi/MainWindowSections.swift:865-867`
- Modify: `Sources/Nugumi/MainWindow.swift:223`

- [ ] **Step 1: Ingest the /models body during key validation**

In `APIKeyValidator.validate` (~line 10581), the response body is currently discarded. Change:

```swift
            let (_, response) = try await URLSession.shared.data(for: request)
```

to:

```swift
            let (data, response) = try await URLSession.shared.data(for: request)
```

and in the success case:

```swift
            case 200..<300:
                return .valid
```

to:

```swift
            case 200..<300:
                // The body is the provider's /models list — feed discovery so
                // the picker updates the moment a key is added. Free: no
                // extra request beyond the validation GET itself.
                CloudModelCache.update(
                    provider: provider,
                    models: CloudModelDiscovery.parse(provider: provider, data: data)
                )
                return .valid
```

(`CloudModelCache.update` already no-ops for `.openAICodex` and for empty parses, so no extra guards here.)

- [ ] **Step 2: Add `refreshAll` to `CloudModelDiscovery`**

Add inside `enum CloudModelDiscovery`:

```swift
    /// Launch-time refresh for every provider with a stored key. Best-effort:
    /// any failure (no key, network, non-200, unparseable body) leaves the
    /// cache untouched. Same contract as CodexModelDiscovery.refreshFromAPI.
    static func refreshAll() async {
        for provider in [CloudProvider.openAI, .anthropic, .gemini] {
            guard let key = KeychainStore.apiKey(for: provider), !key.isEmpty else { continue }
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
```

(The auth-header switch intentionally duplicates `APIKeyValidator`'s three lines rather than extracting a shared helper — two call sites, three lines, different timeout/error semantics.)

- [ ] **Step 3: Fire it at launch**

In `applicationDidFinishLaunching` (~line 1200), after `setupBootstrap()`, add:

```swift
        // Refresh the API-key providers' model catalogs (best-effort, cached).
        Task.detached { await CloudModelDiscovery.refreshAll() }
```

- [ ] **Step 4: Point the picker at the merged list**

In `Sources/Nugumi/MainWindowSections.swift:865-867`, change:

```swift
                        modelSection(CloudProvider.openAI.displayName, LLMModel.models(for: .openAI))
                        modelSection(CloudProvider.anthropic.displayName, LLMModel.models(for: .anthropic))
                        modelSection(CloudProvider.gemini.displayName, LLMModel.models(for: .gemini))
```

to:

```swift
                        modelSection(CloudProvider.openAI.displayName, LLMModel.cloudModels(for: .openAI))
                        modelSection(CloudProvider.anthropic.displayName, LLMModel.cloudModels(for: .anthropic))
                        modelSection(CloudProvider.gemini.displayName, LLMModel.cloudModels(for: .gemini))
```

- [ ] **Step 5: Re-render the picker on cache updates**

In `Sources/Nugumi/MainWindow.swift:223`, change:

```swift
        for name in [Notification.Name.ollamaModelsUpdated, .codexModelsUpdated] {
```

to:

```swift
        for name in [Notification.Name.ollamaModelsUpdated, .codexModelsUpdated, .cloudModelsUpdated] {
```

- [ ] **Step 6: Build and run the full test suite**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected: `Build complete!`, 0 test failures.

- [ ] **Step 7: Commit**

```bash
git add Sources/Nugumi/App.swift Sources/Nugumi/MainWindow.swift Sources/Nugumi/MainWindowSections.swift
git commit -m "feat: live cloud model discovery on key entry and app launch"
```

---

### Task 6: Manual verification

No new automated tests here — this validates the network-touching seams the unit tests stub out.

- [ ] **Step 1: Run the app**

Run: `swift run Nugumi` (debug mode; Sparkle inert, that's expected).

- [ ] **Step 2: Verify with a real key**

In the main window's model picker: providers **without** a stored key must show exactly the curated three models. If a real OpenAI/Anthropic/Gemini key is stored, the section should (after launch refresh lands) show curated entries plus any newer chat models, and no retired ones. Adding a key via the API-key sheet must update the section without restarting.

- [ ] **Step 3: Verify the defensive fallbacks**

Quit the app, run with networking unavailable (e.g. Wi-Fi off): picker must show the last cached list (or curated if never fetched), never an empty section.

- [ ] **Step 4: Report results to the user before declaring done**

If any step misbehaves, stop and debug — do not paper over with a fallback.
