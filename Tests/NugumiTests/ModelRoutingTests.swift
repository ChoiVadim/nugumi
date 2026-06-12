import XCTest
@testable import Nugumi

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

    func testAskNugumiDefaultsToVisionCapableFlagship() {
        let modelID = ModelUseScope.askNugumi.defaultModelID(
            legacySelectedModelID: "gpt-oss:20b"
        )
        let model = LLMModel.option(id: modelID)

        XCTAssertEqual(modelID, "gpt-5.5")
        XCTAssertTrue(model.supportsImages)
    }

    func testAskNugumiScopeOnlyOffersVisionModels() {
        let models = ModelUseScope.askNugumi.availableModels()

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

    func testAskNugumiThinkingDefaultsHigh() {
        let level = ModelUseScope.askNugumi.defaultThinkingLevel(
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
            ModelUseScope.askNugumi.thinkingMenuTitle(for: .high),
            "Ask Nugumi: High"
        )
    }

    func testScopedMenuTitlesUsePurposeFirstLabels() {
        XCTAssertEqual(
            ModelUseScope.textActions.menuTitle(for: LLMModel.option(id: "gpt-oss:120b-cloud")),
            "Everyday text: gpt-oss:120b"
        )
        XCTAssertEqual(
            ModelUseScope.askNugumi.menuTitle(for: LLMModel.option(id: "gpt-5.5")),
            "Ask Nugumi: GPT-5.5"
        )
    }

    func testEnginePresetsPairFastTextWithVisionFlagship() {
        XCTAssertEqual(EngineModelPreset.ollama.modelID(for: .textActions), "gpt-oss:20b")
        XCTAssertEqual(EngineModelPreset.ollama.modelID(for: .askNugumi), "gemma4")
        XCTAssertEqual(EngineModelPreset.cloud(.openAI).modelID(for: .textActions), "gpt-5.4-mini")
        XCTAssertEqual(EngineModelPreset.cloud(.openAI).modelID(for: .askNugumi), "gpt-5.5")
        XCTAssertEqual(EngineModelPreset.cloud(.anthropic).modelID(for: .textActions), "claude-sonnet-4-6")
        XCTAssertEqual(EngineModelPreset.cloud(.anthropic).modelID(for: .askNugumi), "claude-opus-4-7")
        XCTAssertEqual(EngineModelPreset.cloud(.gemini).modelID(for: .textActions), "gemini-2.5-flash")
        XCTAssertEqual(EngineModelPreset.cloud(.gemini).modelID(for: .askNugumi), "gemini-2.5-pro")
    }

    func testEnginePresetModelsExistInCatalogAndSupportTheirScope() {
        for engine: EngineModelPreset in [.ollama, .cloud(.openAI), .cloud(.anthropic), .cloud(.gemini)] {
            for scope in ModelUseScope.allCases {
                guard let id = engine.modelID(for: scope) else {
                    XCTFail("no preset for \(engine) / \(scope)")
                    continue
                }
                let model = LLMModel.option(id: id)
                XCTAssertEqual(model.id, id, "preset \(id) must resolve in the curated catalog")
                if scope == .askNugumi {
                    XCTAssertTrue(model.supportsImages, "Ask Nugumi preset \(id) must be vision-capable")
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
        let ask = EngineModelPreset.cloud(.openAICodex).modelID(for: .askNugumi)

        XCTAssertNotNil(text)
        XCTAssertNotNil(ask)
        XCTAssertTrue(text?.hasPrefix("codex/") ?? false)
        XCTAssertTrue(ask?.hasPrefix("codex/") ?? false)
        XCTAssertTrue(text?.contains("mini") ?? false)
        XCTAssertFalse(ask?.contains("mini") ?? true)
    }
}
