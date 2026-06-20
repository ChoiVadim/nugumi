import XCTest
@testable import Nugumi

final class CloudThinkingTests: XCTestCase {
    func testOpenAIAndGeminiUseReasoningEffort() {
        let openAI = CloudThinkingOptions(
            provider: .openAI,
            model: "gpt-5.5",
            thinkingLevel: .high
        )
        let gemini = CloudThinkingOptions(
            provider: .gemini,
            model: "gemini-2.5-flash",
            thinkingLevel: .medium
        )

        XCTAssertEqual(openAI.reasoningEffort, "high")
        XCTAssertNil(openAI.thinking)
        XCTAssertNil(openAI.outputConfig)
        XCTAssertEqual(gemini.reasoningEffort, "medium")
        XCTAssertNil(gemini.thinking)
        XCTAssertNil(gemini.outputConfig)
    }

    func testClaudeUsesReasoningEffortViaCompatEndpoint() {
        // Anthropic's OpenAI-compat /chat/completions rejects native thinking /
        // output_config (HTTP 400), so Claude routes through reasoning_effort like
        // every other compat provider — for legacy and newer models alike.
        let haiku = CloudThinkingOptions(
            provider: .anthropic,
            model: "claude-haiku-4-5-20251001",
            thinkingLevel: .medium
        )
        XCTAssertEqual(haiku.reasoningEffort, "medium")
        XCTAssertNil(haiku.thinking)
        XCTAssertNil(haiku.outputConfig)

        let opus = CloudThinkingOptions(
            provider: .anthropic,
            model: "claude-opus-4-7",
            thinkingLevel: .high
        )
        XCTAssertEqual(opus.reasoningEffort, "high")
        XCTAssertNil(opus.thinking)
        XCTAssertNil(opus.outputConfig)
    }

    func testCloudThinkingOptionsEncodeProviderSpecificKeys() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let openAIData = try encoder.encode(CloudThinkingOptions(
            provider: .openAI,
            model: "gpt-5.5",
            thinkingLevel: .low
        ))
        let openAIJSON = String(data: openAIData, encoding: .utf8)
        XCTAssertEqual(openAIJSON, #"{"reasoning_effort":"low"}"#)

        let anthropicData = try encoder.encode(CloudThinkingOptions(
            provider: .anthropic,
            model: "claude-opus-4-7",
            thinkingLevel: .medium
        ))
        let anthropicJSON = String(data: anthropicData, encoding: .utf8)
        XCTAssertEqual(anthropicJSON, #"{"reasoning_effort":"medium"}"#)
    }
}
