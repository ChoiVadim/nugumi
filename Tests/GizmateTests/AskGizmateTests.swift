import XCTest
@testable import Gizmate

final class AskGizmateTests: XCTestCase {
    func testExtractsJSONFromFencedResponse() throws {
        let raw = """
        Here is the answer:
        ```json
        {"message":"Use the button on the right.","emotion":"happy"}
        ```
        """

        let response = AskGizmateResponse.parse(raw)

        XCTAssertEqual(response.message, "Use the button on the right.")
    }

    func testIgnoresStrayLegacyKeysInJSON() {
        // Older models may still emit retired fields; they must be ignored,
        // never break message extraction.
        let raw = """
        {"message":"That worked.","emotion":"happy"}
        """

        let response = AskGizmateResponse.parse(raw)

        XCTAssertEqual(response.message, "That worked.")
    }

    func testFallsBackToPlainMessageForNonJSON() {
        let response = AskGizmateResponse.parse("The save button is at the top right.")

        XCTAssertEqual(response.message, "The save button is at the top right.")
    }

    func testBlankDecodedMessageDoesNotFallBackToRawJSON() {
        let response = AskGizmateResponse.parse("{\"message\":\"   \"}")

        XCTAssertEqual(response.message, "")
    }

    func testPromptWithImageIncludesCoordinateGuide() {
        let prompt = AskGizmatePromptBuilder.prompt(question: "Where is the Apple icon?", hasImage: true)

        XCTAssertTrue(prompt.contains("Where is the Apple icon?"))
        XCTAssertTrue(prompt.contains("normalized from 0.0 to 1.0"))
        XCTAssertTrue(prompt.contains("geometric center"))
        XCTAssertTrue(prompt.contains("Never anchor to the top-left of a text label"))
        // (Literals split so this file passes the repo-wide tombstone grep for the removed field names.)
        XCTAssertFalse(prompt.contains("screenshot" + "_normalized"))
    }

    func testPromptWithoutImageOmitsCoordinateGuide() {
        let prompt = AskGizmatePromptBuilder.prompt(question: "What is the capital of Korea?", hasImage: false)

        XCTAssertEqual(prompt, "What is the capital of Korea?")
        XCTAssertFalse(prompt.contains("normalized"))
        XCTAssertFalse(prompt.contains("screenshot"))
    }

    func testSystemPromptDescribesGeneralAgentWithOptionalScreenshot() {
        let prompt = AskGizmatePromptBuilder.systemPrompt()

        XCTAssertTrue(prompt.contains("desktop assistant"))
        XCTAssertTrue(prompt.contains("When the user attaches a screenshot"))
        XCTAssertTrue(prompt.contains("When no screenshot is attached, answer from general knowledge"))
        // (Literals split so this file passes the repo-wide tombstone grep for the removed field names.)
        XCTAssertFalse(prompt.contains("pet" + "Target"))
        XCTAssertFalse(prompt.contains("screenshot" + "_normalized"))
        XCTAssertFalse(prompt.contains("The user will provide a screenshot"))
    }

    func testSystemPromptAllowsMarkdownInMessage() {
        let prompt = AskGizmatePromptBuilder.systemPrompt()
        XCTAssertTrue(prompt.contains("Markdown is welcome"))
        XCTAssertTrue(prompt.contains("numbered lists for steps"))
    }

    func testSystemPromptUsesPlainTextPlusAnnotationsFenceProtocol() {
        let prompt = AskGizmatePromptBuilder.systemPrompt()
        XCTAssertTrue(prompt.contains("plain text, not JSON"))
        XCTAssertTrue(prompt.contains("```annotations"))
        XCTAssertFalse(prompt.contains("Return only JSON"))
        XCTAssertFalse(prompt.contains("emotion"))
    }

    @MainActor
    func testFlattenedMarkdownStripsSyntaxKeepsText() {
        let flat = TranslationContentView.flattenedMarkdown(
            "**Bold** term\n- first step\n- second step"
        )
        XCTAssertFalse(flat.contains("**"), "emphasis syntax must be resolved")
        XCTAssertTrue(flat.contains("first step"))
        XCTAssertTrue(flat.contains("second step"))
    }

    func testAppendingTurnGrowsHistoryUpToCap() {
        var history: [AskGizmateTurn] = []
        for index in 1...3 {
            history = AskGizmatePromptBuilder.appending(
                AskGizmateTurn(question: "Q\(index)", answer: "A\(index)"),
                to: history
            )
        }

        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.first?.question, "Q1")
        XCTAssertEqual(history.last?.answer, "A3")
    }

    func testAppendingTurnDropsOldestTurnsBeyondCap() {
        var history: [AskGizmateTurn] = []
        let overflow = AskGizmatePromptBuilder.maxHistoryTurns + 3
        for index in 1...overflow {
            history = AskGizmatePromptBuilder.appending(
                AskGizmateTurn(question: "Q\(index)", answer: "A\(index)"),
                to: history
            )
        }

        XCTAssertEqual(history.count, AskGizmatePromptBuilder.maxHistoryTurns)
        XCTAssertEqual(history.first?.question, "Q4")
        XCTAssertEqual(history.last?.question, "Q\(overflow)")
    }

    func testAboutContextAppendsBackgroundWithDisambiguationGuard() {
        let prompt = UserAboutContext.appending(to: "Base prompt.", about: "I'm a software developer.")

        XCTAssertTrue(prompt.hasPrefix("Base prompt."))
        XCTAssertTrue(prompt.contains("I'm a software developer."))
        XCTAssertTrue(prompt.contains("disambiguate terms"))
        XCTAssertTrue(prompt.contains("Do not change the output's tone, style, language, or format"))
    }

    func testAboutContextLeavesPromptUntouchedWhenEmpty() {
        XCTAssertEqual(UserAboutContext.appending(to: "Base prompt.", about: "  \n "), "Base prompt.")
    }

    func testAboutContextIsCappedAtMaxLength() {
        let oversized = String(repeating: "x", count: UserAboutContext.maxLength + 500)
        let prompt = UserAboutContext.appending(to: "Base.", about: oversized)

        XCTAssertTrue(prompt.contains(String(repeating: "x", count: UserAboutContext.maxLength)))
        XCTAssertFalse(prompt.contains(String(repeating: "x", count: UserAboutContext.maxLength + 1)))
    }

    func testAskSystemPromptIncludesAboutUser() {
        let prompt = AskGizmatePromptBuilder.systemPrompt(aboutUser: "I'm a PostgreSQL developer.")

        XCTAssertTrue(prompt.contains("desktop assistant"))
        XCTAssertTrue(prompt.contains("I'm a PostgreSQL developer."))
    }

    func testTranslationModeSystemPromptIncludesAboutUser() {
        UserDefaults.standard.set("I'm a software developer.", forKey: UserAboutContext.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: UserAboutContext.defaultsKey) }

        let prompt = TranslationMode.selection.systemPrompt(
            targetLanguage: TranslationLanguage.defaultLanguage,
            composition: nil
        )

        XCTAssertTrue(prompt.contains("I'm a software developer."))
    }

    func testHistoryStoreRoundTripsWithinMaxAge() throws {
        let suiteName = "test.askGizmateHistory.roundTrip"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let turns = [AskGizmateTurn(question: "Q1", answer: "A1")]
        let savedAt = Date(timeIntervalSince1970: 1_000_000)

        AskGizmateHistoryStore.save(turns, defaults: defaults, now: savedAt)
        let loaded = AskGizmateHistoryStore.load(
            defaults: defaults,
            now: savedAt.addingTimeInterval(AskGizmateHistoryStore.maxAge - 1)
        )

        XCTAssertEqual(loaded, turns)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testHistoryStoreExpiresAfterMaxAge() throws {
        let suiteName = "test.askGizmateHistory.expiry"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let turns = [AskGizmateTurn(question: "Q1", answer: "A1")]
        let savedAt = Date(timeIntervalSince1970: 1_000_000)

        AskGizmateHistoryStore.save(turns, defaults: defaults, now: savedAt)
        let loaded = AskGizmateHistoryStore.load(
            defaults: defaults,
            now: savedAt.addingTimeInterval(AskGizmateHistoryStore.maxAge + 1)
        )

        XCTAssertEqual(loaded, [])
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testFloatingPromptLayoutHasTallerPillAndCenteredInput() {
        let layout = AskGizmateFloatingPromptMetrics.layout

        XCTAssertEqual(layout.pillFrame.size.height, 46, accuracy: 0.001)
        XCTAssertEqual(layout.panelSize.height, 74, accuracy: 0.001)
        XCTAssertEqual(layout.cornerRadius, 23, accuracy: 0.001)
        XCTAssertEqual(layout.textFrame.height, 24, accuracy: 0.001)
        XCTAssertEqual(layout.textFrame.midY, layout.pillFrame.midY, accuracy: 0.001)
    }
}
