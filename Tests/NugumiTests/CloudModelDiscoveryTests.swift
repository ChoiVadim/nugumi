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
