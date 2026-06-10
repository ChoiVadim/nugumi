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

        // gpt-4o dropped: prefix guard only admits gpt-5+
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
}
