import XCTest
@testable import Nugumi

final class AskNugumiTests: XCTestCase {
    func testExtractsJSONFromFencedResponse() throws {
        let raw = """
        Here is the answer:
        ```json
        {"message":"Use the button on the right.","emotion":"happy"}
        ```
        """

        let response = AskNugumiResponse.parse(raw)

        XCTAssertEqual(response.message, "Use the button on the right.")
        XCTAssertEqual(response.emotion, .happy)
    }

    func testParsesOptionalEmotion() {
        let raw = """
        {"message":"That worked.","emotion":"happy"}
        """

        let response = AskNugumiResponse.parse(raw)

        XCTAssertEqual(response.message, "That worked.")
        XCTAssertEqual(response.emotion, .happy)
    }

    func testRejectsUnsupportedEmotion() {
        let raw = """
        {"message":"I am not sure.","emotion":"sleepy"}
        """

        let response = AskNugumiResponse.parse(raw)

        XCTAssertEqual(response.message, "I am not sure.")
        XCTAssertNil(response.emotion)
    }

    func testFallsBackToPlainMessageForNonJSON() {
        let response = AskNugumiResponse.parse("The save button is at the top right.")

        XCTAssertEqual(response.message, "The save button is at the top right.")
    }

    func testBlankDecodedMessageDoesNotFallBackToRawJSON() {
        let response = AskNugumiResponse.parse("{\"message\":\"   \"}")

        XCTAssertEqual(response.message, "")
    }

    func testPromptWithImageIncludesCoordinateGuide() {
        let prompt = AskNugumiPromptBuilder.prompt(question: "Where is the Apple icon?", hasImage: true)

        XCTAssertTrue(prompt.contains("Where is the Apple icon?"))
        XCTAssertTrue(prompt.contains("normalized from 0.0 to 1.0"))
        XCTAssertTrue(prompt.contains("geometric center"))
        XCTAssertTrue(prompt.contains("Never anchor to the top-left of a text label"))
        // (Literals split so this file passes the repo-wide tombstone grep for the removed field names.)
        XCTAssertFalse(prompt.contains("screenshot" + "_normalized"))
    }

    func testPromptWithoutImageOmitsCoordinateGuide() {
        let prompt = AskNugumiPromptBuilder.prompt(question: "What is the capital of Korea?", hasImage: false)

        XCTAssertEqual(prompt, "What is the capital of Korea?")
        XCTAssertFalse(prompt.contains("normalized"))
        XCTAssertFalse(prompt.contains("screenshot"))
    }

    func testSystemPromptDescribesGeneralAgentWithOptionalScreenshot() {
        let prompt = AskNugumiPromptBuilder.systemPrompt(genZ: false)

        XCTAssertTrue(prompt.contains("desktop assistant"))
        XCTAssertTrue(prompt.contains("When the user attaches a screenshot"))
        XCTAssertTrue(prompt.contains("When no screenshot is attached, answer from general knowledge"))
        // (Literals split so this file passes the repo-wide tombstone grep for the removed field names.)
        XCTAssertFalse(prompt.contains("pet" + "Target"))
        XCTAssertFalse(prompt.contains("screenshot" + "_normalized"))
        XCTAssertFalse(prompt.contains("The user will provide a screenshot"))
    }

    func testAppendingTurnGrowsHistoryUpToCap() {
        var history: [AskNugumiTurn] = []
        for index in 1...3 {
            history = AskNugumiPromptBuilder.appending(
                AskNugumiTurn(question: "Q\(index)", answer: "A\(index)"),
                to: history
            )
        }

        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.first?.question, "Q1")
        XCTAssertEqual(history.last?.answer, "A3")
    }

    func testAppendingTurnDropsOldestTurnsBeyondCap() {
        var history: [AskNugumiTurn] = []
        let overflow = AskNugumiPromptBuilder.maxHistoryTurns + 3
        for index in 1...overflow {
            history = AskNugumiPromptBuilder.appending(
                AskNugumiTurn(question: "Q\(index)", answer: "A\(index)"),
                to: history
            )
        }

        XCTAssertEqual(history.count, AskNugumiPromptBuilder.maxHistoryTurns)
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
        let prompt = AskNugumiPromptBuilder.systemPrompt(genZ: false, aboutUser: "I'm a PostgreSQL developer.")

        XCTAssertTrue(prompt.contains("Return only JSON"))
        XCTAssertTrue(prompt.contains("I'm a PostgreSQL developer."))
    }

    func testTranslationModeSystemPromptIncludesAboutUser() {
        UserDefaults.standard.set("I'm a software developer.", forKey: UserAboutContext.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: UserAboutContext.defaultsKey) }

        let prompt = TranslationMode.selection.systemPrompt(
            targetLanguage: TranslationLanguage.defaultLanguage,
            appCategory: .other,
            composition: nil
        )

        XCTAssertTrue(prompt.contains("I'm a software developer."))
    }

    func testHistoryStoreRoundTripsWithinMaxAge() throws {
        let suiteName = "test.askNugumiHistory.roundTrip"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let turns = [AskNugumiTurn(question: "Q1", answer: "A1")]
        let savedAt = Date(timeIntervalSince1970: 1_000_000)

        AskNugumiHistoryStore.save(turns, defaults: defaults, now: savedAt)
        let loaded = AskNugumiHistoryStore.load(
            defaults: defaults,
            now: savedAt.addingTimeInterval(AskNugumiHistoryStore.maxAge - 1)
        )

        XCTAssertEqual(loaded, turns)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testHistoryStoreExpiresAfterMaxAge() throws {
        let suiteName = "test.askNugumiHistory.expiry"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let turns = [AskNugumiTurn(question: "Q1", answer: "A1")]
        let savedAt = Date(timeIntervalSince1970: 1_000_000)

        AskNugumiHistoryStore.save(turns, defaults: defaults, now: savedAt)
        let loaded = AskNugumiHistoryStore.load(
            defaults: defaults,
            now: savedAt.addingTimeInterval(AskNugumiHistoryStore.maxAge + 1)
        )

        XCTAssertEqual(loaded, [])
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testPetPromptDismissesOnlyWhenClickTargetsPet() {
        let petFrame = CGRect(x: 40, y: 50, width: 54, height: 46)

        XCTAssertTrue(AskNugumiPetDismissalPolicy.shouldDismissPrompt(
            clickPoint: CGPoint(x: 67, y: 73),
            petFrame: petFrame
        ))
        XCTAssertFalse(AskNugumiPetDismissalPolicy.shouldDismissPrompt(
            clickPoint: CGPoint(x: 160, y: 120),
            petFrame: petFrame
        ))
    }

    func testPetPromptDismissalAllowsSmallPetHitTolerance() {
        let petFrame = CGRect(x: 40, y: 50, width: 54, height: 46)

        XCTAssertTrue(AskNugumiPetDismissalPolicy.shouldDismissPrompt(
            clickPoint: CGPoint(x: petFrame.minX - AskNugumiPetDismissalPolicy.hitTolerance, y: petFrame.midY),
            petFrame: petFrame
        ))
        XCTAssertFalse(AskNugumiPetDismissalPolicy.shouldDismissPrompt(
            clickPoint: CGPoint(x: petFrame.minX - AskNugumiPetDismissalPolicy.hitTolerance - 1, y: petFrame.midY),
            petFrame: petFrame
        ))
    }

    func testSelectionStatusUpdateIsIgnoredWhilePetIsThinkingOrPromptIsVisible() {
        XCTAssertTrue(PetSelectionStatusPolicy.shouldPreserveCurrentStatus(
            isThinking: true,
            isPromptVisible: false
        ))
        XCTAssertTrue(PetSelectionStatusPolicy.shouldPreserveCurrentStatus(
            isThinking: false,
            isPromptVisible: true
        ))
        XCTAssertFalse(PetSelectionStatusPolicy.shouldPreserveCurrentStatus(
            isThinking: false,
            isPromptVisible: false
        ))
    }

    func testPetBubblePresentationKeepsPetStillWhenBubbleFitsAboveMascot() {
        let layout = AskNugumiPromptInputMetrics.layout(forContentHeight: 18)
        let petOrigin = CGPoint(x: 40, y: 40)
        let petSize = CGSize(width: 54, height: 46)
        let presentation = AskNugumiPetBubblePresentationMetrics.presentation(
            petOrigin: petOrigin,
            petSize: petSize,
            promptSize: layout.panelSize,
            bubbleFrame: layout.bubbleFrame,
            visibleFrame: CGRect(x: 0, y: 0, width: 420, height: 300),
            edgeMargin: 6
        )
        let bubbleScreenFrame = layout.bubbleFrame.offsetBy(
            dx: presentation.promptFrame.minX,
            dy: presentation.promptFrame.minY
        )
        let petFrame = CGRect(origin: presentation.petOrigin, size: petSize)

        XCTAssertEqual(presentation.petOrigin.x, petOrigin.x, accuracy: 0.001)
        XCTAssertEqual(presentation.petOrigin.y, petOrigin.y, accuracy: 0.001)
        XCTAssertEqual(
            bubbleScreenFrame.minY - petFrame.maxY,
            AskNugumiPetBubblePresentationMetrics.bubbleToPetPanelGap,
            accuracy: 0.001
        )
    }

    func testPetBubblePresentationMovesPetBelowTopClampedBubble() {
        let layout = AskNugumiAnswerBubbleMetrics.layout(forContentHeight: 80)
        let petSize = CGSize(width: 54, height: 46)
        let visibleFrame = CGRect(x: 0, y: 0, width: 420, height: 300)
        let edgeMargin: CGFloat = 6
        let presentation = AskNugumiPetBubblePresentationMetrics.presentation(
            petOrigin: CGPoint(x: 40, y: 248),
            petSize: petSize,
            promptSize: layout.panelSize,
            bubbleFrame: layout.bubbleFrame,
            visibleFrame: visibleFrame,
            edgeMargin: edgeMargin
        )
        let bubbleScreenFrame = layout.bubbleFrame.offsetBy(
            dx: presentation.promptFrame.minX,
            dy: presentation.promptFrame.minY
        )
        let petFrame = CGRect(origin: presentation.petOrigin, size: petSize)

        XCTAssertEqual(
            bubbleScreenFrame.minY - petFrame.maxY,
            AskNugumiPetBubblePresentationMetrics.bubbleToPetPanelGap,
            accuracy: 0.001
        )
        XCTAssertLessThanOrEqual(presentation.promptFrame.maxY, visibleFrame.maxY - edgeMargin)
    }

    func testPromptInputLayoutIsShorterWithSmallerText() {
        let layout = AskNugumiPromptInputMetrics.layout(forContentHeight: 18)

        XCTAssertEqual(layout.panelSize.width, 182, accuracy: 0.001)
        XCTAssertEqual(AskNugumiPromptInputMetrics.fontSize, 13, accuracy: 0.001)
        XCTAssertLessThan(layout.panelSize.width, AskNugumiAnswerBubbleMetrics.panelWidth)
    }

    func testPromptInputTextHasSymmetricInnerPadding() {
        let layout = AskNugumiPromptInputMetrics.layout(forContentHeight: 18)

        XCTAssertEqual(layout.textFrame.minX - layout.bubbleFrame.minX, 30, accuracy: 0.001)
        XCTAssertEqual(layout.bubbleFrame.maxX - layout.textFrame.maxX, 30, accuracy: 0.001)
    }

    func testPromptInputMeasuresWrappingBeforeVisibleTextFrameEdge() {
        let layout = AskNugumiPromptInputMetrics.layout(forContentHeight: 18)

        XCTAssertLessThan(AskNugumiPromptInputMetrics.textMeasurementWidth, layout.textFrame.width)
        XCTAssertEqual(
            layout.textFrame.width - AskNugumiPromptInputMetrics.textMeasurementWidth,
            12,
            accuracy: 0.001
        )
        XCTAssertGreaterThanOrEqual(AskNugumiPromptInputMetrics.textMeasurementBottomInset, 6)
    }

    func testPromptInputLayoutGrowsWhenTextWraps() {
        let short = AskNugumiPromptInputMetrics.layout(forContentHeight: 18)
        let taller = AskNugumiPromptInputMetrics.layout(forContentHeight: 72)

        XCTAssertGreaterThan(taller.panelSize.height, short.panelSize.height)
        XCTAssertGreaterThan(taller.bubbleFrame.height, short.bubbleFrame.height)
    }

    func testFloatingPromptLayoutHasTallerPillAndCenteredInput() {
        let layout = AskNugumiFloatingPromptMetrics.layout

        XCTAssertEqual(layout.pillFrame.size.height, 46, accuracy: 0.001)
        XCTAssertEqual(layout.panelSize.height, 74, accuracy: 0.001)
        XCTAssertEqual(layout.cornerRadius, 23, accuracy: 0.001)
        XCTAssertEqual(layout.textFrame.height, 24, accuracy: 0.001)
        XCTAssertEqual(layout.textFrame.midY, layout.pillFrame.midY, accuracy: 0.001)
    }

    func testAnswerBubbleLayoutGrowsBeforeScrollLimit() {
        let short = AskNugumiAnswerBubbleMetrics.layout(forContentHeight: 30)
        let taller = AskNugumiAnswerBubbleMetrics.layout(forContentHeight: 120)

        XCTAssertGreaterThan(taller.panelSize.height, short.panelSize.height)
        XCTAssertGreaterThan(taller.bubbleFrame.height, short.bubbleFrame.height)
        XCTAssertFalse(taller.needsScroll)
    }

    func testAnswerTextHasSymmetricInnerPadding() {
        let layout = AskNugumiAnswerBubbleMetrics.layout(forContentHeight: 80)

        // Metrics stay symmetric; the scroller lane is applied at runtime on
        // the text container only when a scrollbar is present.
        XCTAssertEqual(layout.viewportFrame.minX - layout.bubbleFrame.minX, 30, accuracy: 0.001)
        XCTAssertEqual(layout.bubbleFrame.maxX - layout.viewportFrame.maxX, 30, accuracy: 0.001)
    }

    func testAnswerBubbleLayoutUsesScrollAfterMaximumHeight() {
        let layout = AskNugumiAnswerBubbleMetrics.layout(forContentHeight: 600)

        XCTAssertEqual(layout.panelSize.height, AskNugumiAnswerBubbleMetrics.maximumPanelHeight)
        XCTAssertTrue(layout.needsScroll)
        XCTAssertGreaterThan(layout.documentHeight, layout.viewportFrame.height)
    }
}
