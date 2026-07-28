import XCTest
@testable import Gizmate

final class OllamaSetupTests: XCTestCase {
    func testLocalOllamaCatalogExcludesAccountRequiredCloudModels() {
        XCTAssertFalse(LLMModel.localOllamaModels.isEmpty)
        XCTAssertTrue(LLMModel.localOllamaModels.allSatisfy { !$0.isCloud })
        XCTAssertTrue(LLMModel.ollamaCloudModels.allSatisfy(\.isCloud))
        XCTAssertTrue(LLMModel.ollamaCloudModels.contains { $0.id == "gpt-oss:120b-cloud" })
    }

    func testOllamaSignInNoticeAppearsOnlyForOllamaCloudModels() {
        let signedOut = BootstrapStepStatus.needsAction("Open Ollama and sign in.")

        XCTAssertNil(AIEngineStatusCopy.ollamaCloudSignInNotice(
            for: LLMModel.option(id: "gpt-oss:20b"),
            signInStatus: signedOut
        ))
        XCTAssertEqual(
            AIEngineStatusCopy.ollamaCloudSignInNotice(
                for: LLMModel.option(id: "gpt-oss:120b-cloud"),
                signInStatus: signedOut
            ),
            AIEngineStatusCopy.ollamaCloudSignInNoticeText
        )
        XCTAssertNil(AIEngineStatusCopy.ollamaCloudSignInNotice(
            for: LLMModel.option(id: "gpt-oss:120b-cloud"),
            signInStatus: .ok
        ))
        // A non-Ollama cloud model never gets the Ollama notice. Pulled from the
        // catalog (not a hardcoded id) since cloud models are discovery-only now.
        if let nonOllamaCloud = LLMModel.all.first(where: { $0.cloudProvider != nil }) {
            XCTAssertNil(AIEngineStatusCopy.ollamaCloudSignInNotice(
                for: nonOllamaCloud,
                signInStatus: signedOut
            ))
        }
    }

    func testFreeTierCloudModelIsNotMarkedPaid() {
        // gpt-oss:120b is the only Ollama cloud model on the free tier.
        XCTAssertFalse(LLMModel.option(id: "gpt-oss:120b-cloud").requiresPaidOllamaPlan)
        // Local models never require a paid plan.
        XCTAssertFalse(LLMModel.option(id: "gpt-oss:20b").requiresPaidOllamaPlan)
        // Non-Ollama cloud providers are out of scope for this flag.
        XCTAssertFalse(LLMModel.option(id: "gpt-5.4-mini").requiresPaidOllamaPlan)
    }

    func testPaidCloudModelIsFlaggedAndGetsPaidNotice() {
        // A discovered Ollama cloud model that isn't on the free allowlist.
        let paid = LLMModel(
            id: "deepseek-v3.1:671b-cloud",
            shortName: "deepseek-v3.1:671b",
            displayName: "deepseek-v3.1:671b",
            backend: .ollama(requiresAccount: true),
            supportsImages: false
        )
        XCTAssertTrue(paid.requiresPaidOllamaPlan)
        XCTAssertEqual(
            AIEngineStatusCopy.ollamaCloudSignInNotice(
                for: paid,
                signInStatus: .needsAction("Open Ollama and sign in.")
            ),
            AIEngineStatusCopy.ollamaCloudPaidNoticeText
        )
    }
}
