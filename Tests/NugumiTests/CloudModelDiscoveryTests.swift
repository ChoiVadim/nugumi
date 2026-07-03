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
            {"id":"gpt-5-pro","object":"model"},
            {"id":"gpt-5.2-pro","object":"model"},
            {"id":"gpt-realtime","object":"model"},
            {"id":"whisper-1","object":"model"},
            {"id":"tts-1","object":"model"},
            {"id":"dall-e-3","object":"model"},
            {"id":"text-embedding-3-small","object":"model"},
            {"id":"gpt-4o","object":"model"}
        ]}
        """.data(using: .utf8)!

        let parsed = CloudModelDiscovery.parse(provider: .openAI, data: json)

        // gpt-4o dropped: prefix guard only admits gpt-5/gpt-6 families.
        // gpt-5-pro / gpt-5.2-pro dropped: Responses-API-only, reject chat/completions.
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
            {"id":"models/gemini-2.5-flash-lite","object":"model"},
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

        XCTAssertEqual(parsed.map(\.id), ["gemini-2.5-flash-lite", "gemini-2.5-pro", "gemini-3.0-flash"])
    }

    func testOpenRouterParseAllowlistsVendorsKeepsFreeAndCarriesName() {
        let json = """
        {"data":[
            {"id":"openai/gpt-5.4-mini","name":"OpenAI: GPT-5.4 Mini"},
            {"id":"anthropic/claude-sonnet-4.6","name":"Anthropic: Claude Sonnet 4.6"},
            {"id":"deepseek/deepseek-chat:free","name":"DeepSeek: Chat (free)"},
            {"id":"nvidia/nemotron-nano:free","name":"NVIDIA: Nemotron Nano"},
            {"id":"openai/gpt-5.4-image-2","name":"OpenAI: GPT-5.4 Image 2"},
            {"id":"somerandomvendor/mystery-7b","name":"Mystery 7B"},
            {"id":"google/gemini-2.5-pro","name":"Google: Gemini 2.5 Pro"}
        ]}
        """.data(using: .utf8)!

        let parsed = CloudModelDiscovery.parse(provider: .openRouter, data: json)

        // :free kept from ANY vendor (deepseek + non-allowlisted nvidia);
        // -image dropped; unknown non-free vendor dropped.
        XCTAssertEqual(parsed.map(\.id),
                       ["openai/gpt-5.4-mini", "anthropic/claude-sonnet-4.6",
                        "deepseek/deepseek-chat:free", "nvidia/nemotron-nano:free",
                        "google/gemini-2.5-pro"])
        // OpenRouter's `name` field is carried (not `display_name`).
        XCTAssertEqual(parsed[0].displayName, "OpenAI: GPT-5.4 Mini")
        // Free name already has "(free)" → carried as-is.
        XCTAssertEqual(parsed[2].displayName, "DeepSeek: Chat (free)")
        // Free name missing "(free)" → suffix appended as the tag.
        XCTAssertEqual(parsed[3].displayName, "NVIDIA: Nemotron Nano (free)")
    }

    func testClaudeCodeParsesLikeAnthropic() {
        // Claude Code has no dedicated models endpoint; it reads the standard
        // Anthropic /v1/models list, so parsing must match .anthropic.
        let json = """
        {"data":[
            {"id":"claude-fable-5","display_name":"Claude Fable 5","type":"model"},
            {"id":"claude-opus-4-8","display_name":"Claude Opus 4.8","type":"model"},
            {"id":"gpt-4o","display_name":"nope","type":"model"}
        ],"has_more":false}
        """.data(using: .utf8)!

        let parsed = CloudModelDiscovery.parse(provider: .anthropicClaudeCode, data: json)

        // Non-claude ids dropped; display_name carried through.
        XCTAssertEqual(parsed.map(\.id), ["claude-fable-5", "claude-opus-4-8"])
        XCTAssertEqual(parsed[0].displayName, "Claude Fable 5")
    }

    func testParseReturnsEmptyOnGarbageAndOnCodexProvider() {
        let garbage = "not json".data(using: .utf8)!
        XCTAssertTrue(CloudModelDiscovery.parse(provider: .openAI, data: garbage).isEmpty)

        let valid = #"{"data":[{"id":"gpt-5.5"}]}"#.data(using: .utf8)!
        XCTAssertTrue(CloudModelDiscovery.parse(provider: .openAICodex, data: valid).isEmpty)
    }

    // MARK: Canonical ids

    func testCanonicalIDStripsTrailingDateStamp() {
        XCTAssertEqual(
            CloudModelDiscovery.canonicalID("claude-haiku-4-5-20251001"),
            "claude-haiku-4-5"
        )
        XCTAssertEqual(CloudModelDiscovery.canonicalID("claude-opus-4-8"), "claude-opus-4-8")
        XCTAssertEqual(CloudModelDiscovery.canonicalID("gpt-5.5"), "gpt-5.5")
        // 7 digits is not a date stamp — must pass through untouched.
        XCTAssertEqual(CloudModelDiscovery.canonicalID("claude-haiku-4-5-2025101"), "claude-haiku-4-5-2025101")
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
        XCTAssertEqual(
            CloudModelDiscovery.prettyName(provider: .anthropic, id: "claude-3-5-sonnet"),
            "Claude 3.5 Sonnet"
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

    // MARK: Merge

    // API-key catalogs are now empty (models come from /models discovery), so the
    // merge logic is exercised against a hand-built curated list rather than the
    // live (empty) catalog — this tests the merge, not the catalog contents.
    private let curatedAnthropic: [LLMModel] = [
        .init(id: "claude-haiku-4-5-20251001", shortName: "Claude Haiku 4.5",
              displayName: "Claude Haiku 4.5 (fast)", backend: .cloud(.anthropic), supportsImages: true),
        .init(id: "claude-sonnet-4-6", shortName: "Claude Sonnet 4.6",
              displayName: "Claude Sonnet 4.6", backend: .cloud(.anthropic), supportsImages: true),
        .init(id: "claude-opus-4-7", shortName: "Claude Opus 4.7",
              displayName: "Claude Opus 4.7 (top)", backend: .cloud(.anthropic), supportsImages: true),
    ]

    func testMergeNeverFetchedReturnsCuratedUnchanged() {
        let merged = LLMModel.mergedCloudModels(
            provider: .anthropic, curated: curatedAnthropic, discovered: nil
        )
        XCTAssertEqual(merged, curatedAnthropic)
    }

    func testMergeShowsOnlyDiscoveredInResponseOrder() {
        // Discovery has run → curated is dropped entirely; the picker shows
        // exactly what the endpoint returned, in response order, with the
        // API's names (generated only when display_name is absent).
        let discovered: [CloudModelDiscovery.DiscoveredModel] = [
            .init(id: "claude-opus-4-8", displayName: "Claude Opus 4.8"),
            .init(id: "claude-magnum-5-0", displayName: nil),
            .init(id: "claude-haiku-4-5-20251001", displayName: "Claude Haiku 4.5"),
        ]
        let merged = LLMModel.mergedCloudModels(
            provider: .anthropic, curated: curatedAnthropic, discovered: discovered
        )
        XCTAssertEqual(merged.map(\.id),
                       ["claude-opus-4-8", "claude-magnum-5-0", "claude-haiku-4-5-20251001"])
        // No curated tier-hint names leak in.
        XCTAssertEqual(merged.map(\.displayName),
                       ["Claude Opus 4.8", "Claude Magnum 5.0", "Claude Haiku 4.5"])
        XCTAssertTrue(merged.allSatisfy(\.supportsImages))
        XCTAssertTrue(merged.allSatisfy { $0.cloudProvider == .anthropic })
    }

    func testMergeDedupesDatedAndUndatedAliases() {
        // A dated + undated alias for the same model must collapse to one row;
        // the first occurrence (response order) wins.
        let discovered: [CloudModelDiscovery.DiscoveredModel] = [
            .init(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5"),
            .init(id: "claude-haiku-4-5-20251001", displayName: "Claude Haiku 4.5 dated"),
            .init(id: "claude-opus-4-8", displayName: "Claude Opus 4.8"),
        ]
        let merged = LLMModel.mergedCloudModels(
            provider: .anthropic, curated: curatedAnthropic, discovered: discovered
        )
        XCTAssertEqual(merged.map(\.id), ["claude-haiku-4-5", "claude-opus-4-8"])
        XCTAssertEqual(merged[0].displayName, "Claude Haiku 4.5")
    }

    // Claude Code curated entries use `claude-code/` ids (apiModelID = bare id)
    // so they never collide with the .anthropic API-key provider's claude models.
    private let curatedClaudeCode: [LLMModel] = [
        .init(id: "claude-code/claude-haiku-4-5-20251001", apiModelID: "claude-haiku-4-5-20251001",
              shortName: "Claude Haiku 4.5", displayName: "Claude Haiku 4.5 (fast)",
              backend: .cloud(.anthropicClaudeCode), supportsImages: true),
        .init(id: "claude-code/claude-opus-4-8", apiModelID: "claude-opus-4-8",
              shortName: "Claude Opus 4.8", displayName: "Claude Opus 4.8 (top)",
              backend: .cloud(.anthropicClaudeCode), supportsImages: true),
    ]

    func testMergeClaudeCodePrefixesEveryDiscoveredIDAndKeepsBareAPIModelID() {
        let discovered: [CloudModelDiscovery.DiscoveredModel] = [
            .init(id: "claude-opus-4-8", displayName: "Claude Opus 4.8"),
            .init(id: "claude-fable-5", displayName: "Claude Fable 5"),
        ]
        let merged = LLMModel.mergedCloudModels(
            provider: .anthropicClaudeCode, curated: curatedClaudeCode, discovered: discovered
        )
        // Discovered-only, in response order; every id gets the claude-code/
        // prefix while apiModelID stays the bare id /v1/messages expects.
        XCTAssertEqual(merged.map(\.id), ["claude-code/claude-opus-4-8", "claude-code/claude-fable-5"])
        XCTAssertEqual(merged.map(\.apiModelID), ["claude-opus-4-8", "claude-fable-5"])
        XCTAssertEqual(merged.last?.displayName, "Claude Fable 5")
        XCTAssertTrue(merged.allSatisfy { $0.cloudProvider == .anthropicClaudeCode })
    }

    func testOptionResolvesDiscoveredCloudID() {
        // mergedCloudModels output must be reachable via LLMModel.option(id:)
        // when the cache holds it; with an empty cache option() falls back.
        let fallback = LLMModel.option(id: "claude-magnum-5-0")
        XCTAssertNotNil(fallback) // degrades to defaultModel, never crashes
    }
}
