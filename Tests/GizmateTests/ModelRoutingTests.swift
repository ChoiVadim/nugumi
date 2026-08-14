import XCTest
@testable import Gizmate

final class ModelRoutingTests: XCTestCase {
    func testEverydayTextDefaultsToLegacySelectedModel() {
        let modelID = ModelUseScope.fast.defaultModelID(
            legacySelectedModelID: "gpt-oss:20b"
        )

        XCTAssertEqual(modelID, "gpt-oss:20b")
    }

    func testEverydayTextDefaultsToOnlineWithoutLegacySelection() {
        let modelID = ModelUseScope.fast.defaultModelID(
            legacySelectedModelID: nil
        )

        XCTAssertEqual(modelID, "gpt-oss:120b-cloud")
    }

    func testAskGizmateDefaultsToFirstVisionCapableModel() {
        // No hardcoded cloud flagship anymore — the default is the first
        // vision-capable model in the catalog (Gemma 4 locally).
        let modelID = ModelUseScope.standard.defaultModelID(
            legacySelectedModelID: "gpt-oss:20b"
        )
        let model = LLMModel.option(id: modelID)

        XCTAssertTrue(model.supportsImages)
        XCTAssertEqual(modelID, LLMModel.all.first(where: \.supportsImages)?.id)
    }

    func testAskGizmateScopeOnlyOffersVisionModels() {
        let models = ModelUseScope.standard.availableModels()

        XCTAssertFalse(models.isEmpty)
        XCTAssertTrue(models.allSatisfy(\.supportsImages))
        XCTAssertFalse(models.contains { $0.id == "gpt-oss:20b" })
    }

    /// The bug this tier exists to prevent, pinned.
    ///
    /// The builder used to run on `.standard` and inherit its vision filter,
    /// which narrowed the catalog to the models that read pictures and left the
    /// heaviest job in the app on a small local one. The builder writes Python
    /// and JSON and is never handed a picture, so a filter about pictures must
    /// not decide what builds gizmos.
    func testDeepScopeIsNotNarrowedByAFilterAboutPictures() {
        let deep = ModelUseScope.deep.availableModels()

        XCTAssertEqual(deep.map(\.id), LLMModel.all.map(\.id))
        XCTAssertTrue(deep.contains { !$0.supportsImages })
        XCTAssertGreaterThan(deep.count, ModelUseScope.standard.availableModels().count)
    }

    /// A new row must not move someone who had already chosen well: until this
    /// tier existed, `.standard`'s model is literally what built every gizmo.
    func testDeepInheritsAStandardChoiceThatWasAlreadyMade() {
        let key = ModelUseScope.standard.defaultsKey
        let restore = UserDefaults.standard.string(forKey: key)
        defer {
            if let restore {
                UserDefaults.standard.set(restore, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.set("claude-code/claude-opus-4-8", forKey: key)
        XCTAssertEqual(
            ModelUseScope.deep.defaultModelID(legacySelectedModelID: nil),
            "claude-code/claude-opus-4-8"
        )

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(
            ModelUseScope.deep.defaultModelID(legacySelectedModelID: nil),
            LLMModel.defaultModel.id
        )
    }

    /// `scope.rawValue` is reported to analytics as `model_scope`, so renaming
    /// the cases has to leave the wire spelling alone or it breaks the series
    /// rather than renaming it.
    func testScopeRawValuesSurviveTheTierRename() {
        XCTAssertEqual(ModelUseScope.fast.rawValue, "textActions")
        XCTAssertEqual(ModelUseScope.standard.rawValue, "askGizmate")
        XCTAssertEqual(ModelUseScope.fast.defaultsKey, "textModelID")
        XCTAssertEqual(ModelUseScope.standard.defaultsKey, "askGizmateModelID")
        XCTAssertEqual(ModelUseScope.fast.thinkingDefaultsKey, "textThinkingLevel")
        XCTAssertEqual(
            ModelUseScope.standard.thinkingDefaultsKey,
            "askGizmateThinkingLevel"
        )
        // Every scope's keys are distinct, or two tiers share one setting.
        XCTAssertEqual(Set(ModelUseScope.allCases.map(\.defaultsKey)).count, 3)
        XCTAssertEqual(Set(ModelUseScope.allCases.map(\.thinkingDefaultsKey)).count, 3)
    }

    func testEverydayThinkingDefaultsToLegacyThinkingLevel() {
        let level = ModelUseScope.fast.defaultThinkingLevel(
            legacyThinkingRawValue: ThinkingLevel.medium.rawValue
        )

        XCTAssertEqual(level, .medium)
    }

    func testEverydayThinkingDefaultsLowWithoutLegacySelection() {
        let level = ModelUseScope.fast.defaultThinkingLevel(
            legacyThinkingRawValue: nil
        )

        XCTAssertEqual(level, .low)
    }

    func testAskGizmateThinkingDefaultsHigh() {
        let level = ModelUseScope.standard.defaultThinkingLevel(
            legacyThinkingRawValue: ThinkingLevel.low.rawValue
        )

        XCTAssertEqual(level, .high)
    }

    func testScopedThinkingMenuTitlesUsePurposeFirstLabels() {
        XCTAssertEqual(
            ModelUseScope.fast.thinkingMenuTitle(for: .low),
            "Fast: Low"
        )
        XCTAssertEqual(
            ModelUseScope.standard.thinkingMenuTitle(for: .high),
            "Standard: High"
        )
        XCTAssertEqual(
            ModelUseScope.deep.thinkingMenuTitle(for: .high),
            "Deep: High"
        )
    }

    func testScopedMenuTitlesUsePurposeFirstLabels() {
        XCTAssertEqual(
            ModelUseScope.fast.menuTitle(for: LLMModel.option(id: "gpt-oss:120b-cloud")),
            "Fast: gpt-oss:120b"
        )
        XCTAssertEqual(
            ModelUseScope.standard.menuTitle(for: LLMModel.option(id: "gemma4")),
            "Standard: Gemma 4"
        )
        XCTAssertEqual(
            ModelUseScope.deep.menuTitle(for: LLMModel.option(id: "gpt-oss:20b")),
            "Deep: gpt-oss:20b"
        )
    }

    func testCuratedEnginePresetsAreStable() {
        // Curated engines keep deterministic presets. Discovery-only cloud
        // providers (OpenAI, Anthropic API key, Gemini, OpenRouter) no longer
        // have hardcoded presets — they return the first discovered model, or
        // nil until a key + /models fetch populates the catalog.
        XCTAssertEqual(EngineModelPreset.ollama.modelID(for: .fast), "gpt-oss:20b")
        XCTAssertEqual(EngineModelPreset.ollama.modelID(for: .standard), "gemma4")
        // Claude Code (no /models endpoint) keeps a prefixed curated default.
        if let ccText = EngineModelPreset.cloud(.anthropicClaudeCode).modelID(for: .fast) {
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
                if scope == .standard {
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
        let text = EngineModelPreset.cloud(.openAICodex).modelID(for: .fast)
        let ask = EngineModelPreset.cloud(.openAICodex).modelID(for: .standard)

        XCTAssertNotNil(text)
        XCTAssertNotNil(ask)
        XCTAssertTrue(text?.hasPrefix("codex/") ?? false)
        XCTAssertTrue(ask?.hasPrefix("codex/") ?? false)
        XCTAssertTrue(text?.contains("mini") ?? false)
        XCTAssertFalse(ask?.contains("mini") ?? true)
    }
}
