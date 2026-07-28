import XCTest
@testable import Gizmate

final class ModelRoutingTests: XCTestCase {
    func testEverydayTextDefaultsToLegacySelectedModel() {
        let modelID = ModelUseScope.textActions.defaultModelID(
            legacySelectedModelID: "gpt-oss:20b"
        )

        XCTAssertEqual(modelID, "gpt-oss:20b")
    }

    func testEverydayTextDefaultsToOnlineWithoutLegacySelection() {
        let modelID = ModelUseScope.textActions.defaultModelID(
            legacySelectedModelID: nil
        )

        XCTAssertEqual(modelID, "gpt-oss:120b-cloud")
    }

    func testAskGizmateDefaultsToFirstVisionCapableModel() {
        // No hardcoded cloud flagship anymore — the default is the first
        // vision-capable model in the catalog (Gemma 4 locally).
        let modelID = ModelUseScope.askGizmate.defaultModelID(
            legacySelectedModelID: "gpt-oss:20b"
        )
        let model = LLMModel.option(id: modelID)

        XCTAssertTrue(model.supportsImages)
        XCTAssertEqual(modelID, LLMModel.all.first(where: \.supportsImages)?.id)
    }

    func testAskGizmateScopeOnlyOffersVisionModels() {
        let models = ModelUseScope.askGizmate.availableModels()

        XCTAssertFalse(models.isEmpty)
        XCTAssertTrue(models.allSatisfy(\.supportsImages))
        XCTAssertFalse(models.contains { $0.id == "gpt-oss:20b" })
    }

    func testEverydayThinkingDefaultsToLegacyThinkingLevel() {
        let level = ModelUseScope.textActions.defaultThinkingLevel(
            legacyThinkingRawValue: ThinkingLevel.medium.rawValue
        )

        XCTAssertEqual(level, .medium)
    }

    func testEverydayThinkingDefaultsLowWithoutLegacySelection() {
        let level = ModelUseScope.textActions.defaultThinkingLevel(
            legacyThinkingRawValue: nil
        )

        XCTAssertEqual(level, .low)
    }

    func testAskGizmateThinkingDefaultsHigh() {
        let level = ModelUseScope.askGizmate.defaultThinkingLevel(
            legacyThinkingRawValue: ThinkingLevel.low.rawValue
        )

        XCTAssertEqual(level, .high)
    }

    func testScopedThinkingMenuTitlesUsePurposeFirstLabels() {
        XCTAssertEqual(
            ModelUseScope.textActions.thinkingMenuTitle(for: .low),
            "Everyday text: Low"
        )
        XCTAssertEqual(
            ModelUseScope.askGizmate.thinkingMenuTitle(for: .high),
            "Ask Gizmate: High"
        )
    }

    func testScopedMenuTitlesUsePurposeFirstLabels() {
        XCTAssertEqual(
            ModelUseScope.textActions.menuTitle(for: LLMModel.option(id: "gpt-oss:120b-cloud")),
            "Everyday text: gpt-oss:120b"
        )
        XCTAssertEqual(
            ModelUseScope.askGizmate.menuTitle(for: LLMModel.option(id: "gemma4")),
            "Ask Gizmate: Gemma 4"
        )
    }

    func testCuratedEnginePresetsAreStable() {
        // Curated engines keep deterministic presets. Discovery-only cloud
        // providers (OpenAI, Anthropic API key, Gemini, OpenRouter) no longer
        // have hardcoded presets — they return the first discovered model, or
        // nil until a key + /models fetch populates the catalog.
        XCTAssertEqual(EngineModelPreset.ollama.modelID(for: .textActions), "gpt-oss:20b")
        XCTAssertEqual(EngineModelPreset.ollama.modelID(for: .askGizmate), "gemma4")
        // Claude Code (no /models endpoint) keeps a prefixed curated default.
        if let ccText = EngineModelPreset.cloud(.anthropicClaudeCode).modelID(for: .textActions) {
            XCTAssertEqual(LLMModel.option(id: ccText).cloudProvider, .anthropicClaudeCode)
        } else {
            XCTFail("Claude Code must keep a curated preset")
        }
    }

    func testCuratedEnginePresetsResolveInCatalog() {
        // Only curated engines are asserted — discovery-only providers may have
        // nil presets (no models until a key + /models fetch).
        for engine: EngineModelPreset in [.ollama, .cloud(.anthropicClaudeCode)] {
            for scope in ModelUseScope.allCases {
                guard let id = engine.modelID(for: scope) else {
                    XCTFail("no preset for \(engine) / \(scope)")
                    continue
                }
                let model = LLMModel.option(id: id)
                XCTAssertEqual(model.id, id, "preset \(id) must resolve in the catalog")
                if scope == .askGizmate {
                    XCTAssertTrue(model.supportsImages, "Ask Gizmate preset \(id) must be vision-capable")
                }
            }
        }
    }

    func testLatestTagResolvesToBareTagCuratedModel() {
        // `ollama pull gemma4` lists as "gemma4:latest"; a selection stored
        // under that id must keep resolving to the curated bare-tag entry.
        XCTAssertEqual(LLMModel.option(id: "gemma4:latest").id, "gemma4")
        XCTAssertEqual(LLMModel.canonicalOllamaID("gemma4:latest"), "gemma4")
        XCTAssertEqual(LLMModel.canonicalOllamaID("gpt-oss:20b"), "gpt-oss:20b")
    }

    func testCodexEnginePresetResolvesMiniAndFlagshipFromCatalog() {
        // With the fallback catalog: mini for everyday text, flagship for Ask.
        let text = EngineModelPreset.cloud(.openAICodex).modelID(for: .textActions)
        let ask = EngineModelPreset.cloud(.openAICodex).modelID(for: .askGizmate)

        XCTAssertNotNil(text)
        XCTAssertNotNil(ask)
        XCTAssertTrue(text?.hasPrefix("codex/") ?? false)
        XCTAssertTrue(ask?.hasPrefix("codex/") ?? false)
        XCTAssertTrue(text?.contains("mini") ?? false)
        XCTAssertFalse(ask?.contains("mini") ?? true)
    }
}
