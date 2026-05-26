import XCTest
@testable import Nugumi

final class ModelMenuTests: XCTestCase {
    func testModeMenuKeepsCloudModelsInSeparateSubmenus() {
        let entries = LLMModel.modeMenuEntries

        XCTAssertEqual(entries.count, 4)

        guard case let .model(online) = entries[0] else {
            return XCTFail("First mode menu entry should be Online.")
        }
        XCTAssertEqual(online.shortName, "Online")

        guard case let .model(offline) = entries[1] else {
            return XCTFail("Second mode menu entry should be Offline.")
        }
        XCTAssertEqual(offline.shortName, "Offline")

        guard case let .apiKeyModels(apiKeyTitle, apiKeyModels) = entries[2] else {
            return XCTFail("Third mode menu entry should hold API key models.")
        }
        XCTAssertEqual(apiKeyTitle, "API key models")
        XCTAssertEqual(apiKeyModels.map(\.id), LLMModel.apiKeyModels.map(\.id))
        XCTAssertTrue(apiKeyModels.allSatisfy { $0.cloudProvider != nil && $0.cloudProvider?.usesOAuth == false })

        guard case let .apiKeyModels(subscriptionTitle, subscriptionModels) = entries[3] else {
            return XCTFail("Fourth mode menu entry should hold ChatGPT subscription models.")
        }
        XCTAssertEqual(subscriptionTitle, "ChatGPT subscription")
        XCTAssertEqual(subscriptionModels.map(\.id), LLMModel.codexModels.map(\.id))
        XCTAssertTrue(subscriptionModels.allSatisfy { $0.cloudProvider == .openAICodex })
    }
}
