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
}
