import XCTest
@testable import Gizmate

final class CloudCatalogTests: XCTestCase {
    /// API-key cloud providers carry no hardcoded models — their catalogs come
    /// only from each provider's /models call. Only Ollama (local baseline) and
    /// the subscription engines (Claude Code; ChatGPT via CodexModelCache) stay
    /// curated.
    func testNoHardcodedApiKeyCloudModels() {
        let curatedApiKeyCloud = LLMModel.all.filter {
            switch $0.backend {
            case .cloud(.openAI), .cloud(.anthropic), .cloud(.gemini), .cloud(.openRouter):
                return true
            case .cloud(.anthropicClaudeCode), .cloud(.openAICodex), .ollama:
                return false
            }
        }
        XCTAssertTrue(curatedApiKeyCloud.isEmpty,
                      "expected zero hardcoded API-key cloud models, got \(curatedApiKeyCloud.map(\.id))")
    }

    /// Empty-state safety: `all` must never be empty, or `defaultModel = all[0]`
    /// and every `option(id:)` fallback crash on a fresh install with no keys.
    func testCatalogStaysNonEmptyForSafeDefault() {
        XCTAssertFalse(LLMModel.all.isEmpty)
        XCTAssertFalse(LLMModel.defaultModel.id.isEmpty)
        // The Ollama local baseline and Claude Code curated set survive.
        XCTAssertTrue(LLMModel.all.contains { $0.id == "gpt-oss:20b" })
        XCTAssertTrue(LLMModel.all.contains { $0.id == "claude-code/claude-sonnet-4-6" })
    }
}
