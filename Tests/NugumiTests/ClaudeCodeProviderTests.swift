import XCTest
@testable import Nugumi

final class ClaudeCodeProviderTests: XCTestCase {
    /// Regression: Claude Code models must carry the `claude-code/` prefix so they
    /// can never collide with a discovered Anthropic API-key model that uses the
    /// bare name — otherwise a Claude Code pick silently routes to Anthropic.
    func testClaudeCodeModelUsesDistinctPrefixedId() {
        let claudeCode = LLMModel.option(id: "claude-code/claude-sonnet-4-6")
        XCTAssertEqual(claudeCode.cloudProvider, .anthropicClaudeCode)
        // The bare id is NOT the Claude Code model.
        XCTAssertNotEqual(LLMModel.option(id: "claude-sonnet-4-6").cloudProvider, .anthropicClaudeCode)
    }

    /// The prefix is UI-only — the real model name still reaches /v1/messages.
    /// Version-agnostic so it doesn't chase model bumps (opus-4-7 → 4-8 → …).
    func testClaudeCodeModelSendsRealModelName() {
        guard let cc = LLMModel.all.first(where: { $0.cloudProvider == .anthropicClaudeCode }) else {
            return XCTFail("expected at least one curated Claude Code model")
        }
        XCTAssertTrue(cc.id.hasPrefix("claude-code/"), "Claude Code ids must be prefixed")
        XCTAssertFalse(cc.apiModelID.hasPrefix("claude-code/"), "apiModelID must be the real wire name")
        XCTAssertEqual(LLMModel.option(id: cc.id).cloudProvider, .anthropicClaudeCode)
    }

    /// Onboarding/preset defaults for Claude Code must point at the prefixed ids,
    /// otherwise signing in lands the slot on the API-key Anthropic model.
    func testClaudeCodePresetDefaultsArePrefixed() {
        XCTAssertEqual(CloudProvider.anthropicClaudeCode.preferredTextModelID,
                       "claude-code/claude-haiku-4-5-20251001")
        XCTAssertEqual(CloudProvider.anthropicClaudeCode.preferredAskModelID,
                       "claude-code/claude-sonnet-4-6")
        XCTAssertEqual(LLMModel.option(id: CloudProvider.anthropicClaudeCode.preferredTextModelID).cloudProvider,
                       .anthropicClaudeCode)
    }
}
