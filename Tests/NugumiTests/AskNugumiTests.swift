import XCTest
@testable import Nugumi

final class AskNugumiTests: XCTestCase {
    func testParsesStrictJSONResponse() throws {
        let raw = """
        {"message":"Click Save.","petTarget":{"x":0.82,"y":0.18,"coordinateSpace":"screenshot_normalized"}}
        """

        let response = AskNugumiResponse.parse(raw)

        XCTAssertEqual(response.message, "Click Save.")
        XCTAssertEqual(response.petTarget?.x, 0.82)
        XCTAssertEqual(response.petTarget?.y, 0.18)
        XCTAssertEqual(response.petTarget?.coordinateSpace, .screenshotNormalized)
    }

    func testExtractsJSONFromFencedResponse() throws {
        let raw = """
        Here is the answer:
        ```json
        {"message":"Use the button on the right.","petTarget":{"x":0.9,"y":0.5,"coordinateSpace":"screenshot_normalized"}}
        ```
        """

        let response = AskNugumiResponse.parse(raw)

        XCTAssertEqual(response.message, "Use the button on the right.")
        XCTAssertEqual(response.petTarget?.x, 0.9)
        XCTAssertEqual(response.petTarget?.y, 0.5)
    }

    func testParsesOptionalEmotion() {
        let raw = """
        {"message":"That worked.","emotion":"happy"}
        """

        let response = AskNugumiResponse.parse(raw)

        XCTAssertEqual(response.message, "That worked.")
        XCTAssertEqual(response.emotion, .happy)
        XCTAssertNil(response.petTarget)
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
        XCTAssertNil(response.petTarget)
    }

    func testBlankDecodedMessageDoesNotFallBackToRawJSON() {
        let response = AskNugumiResponse.parse("{\"message\":\"   \"}")

        XCTAssertEqual(response.message, "")
        XCTAssertNil(response.petTarget)
    }

    func testRejectsInvalidTargetCoordinates() {
        let raw = """
        {"message":"Click there.","petTarget":{"x":1.4,"y":0.2,"coordinateSpace":"screenshot_normalized"}}
        """

        let response = AskNugumiResponse.parse(raw)

        XCTAssertEqual(response.message, "Click there.")
        XCTAssertNil(response.petTarget)
    }

    func testRejectsUnsupportedCoordinateSpace() {
        let raw = """
        {"message":"Click there.","petTarget":{"x":0.4,"y":0.2,"coordinateSpace":"screen_pixels"}}
        """

        let response = AskNugumiResponse.parse(raw)

        XCTAssertEqual(response.message, "Click there.")
        XCTAssertNil(response.petTarget)
    }

    func testPromptWithImageIncludesCoordinateGuide() {
        let prompt = AskNugumiPromptBuilder.prompt(question: "Where is the Apple icon?", hasImage: true)

        XCTAssertTrue(prompt.contains("Where is the Apple icon?"))
        XCTAssertTrue(prompt.contains("normalized from 0.0 to 1.0"))
        XCTAssertTrue(prompt.contains("geometric center"))
        XCTAssertTrue(prompt.contains("Never anchor to the top-left of a text label"))
        XCTAssertTrue(prompt.contains("screenshot_normalized"))
    }

    func testPromptWithoutImageOmitsCoordinateGuide() {
        let prompt = AskNugumiPromptBuilder.prompt(question: "What is the capital of Korea?", hasImage: false)

        XCTAssertEqual(prompt, "What is the capital of Korea?")
        XCTAssertFalse(prompt.contains("petTarget"))
        XCTAssertFalse(prompt.contains("normalized"))
        XCTAssertFalse(prompt.contains("screenshot"))
    }

    func testSystemPromptDescribesGeneralAgentWithOptionalScreenshot() {
        let prompt = AskNugumiPromptBuilder.systemPrompt

        XCTAssertTrue(prompt.contains("desktop assistant"))
        XCTAssertTrue(prompt.contains("When the user attaches a screenshot"))
        XCTAssertTrue(prompt.contains("When no screenshot is attached, answer from general knowledge"))
        XCTAssertTrue(prompt.contains("Never include `petTarget` without a screenshot"))
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

    func testMapsTopLeftNormalizedCoordinateToAppKitScreenPoint() {
        let screenFrame = CGRect(x: 100, y: 200, width: 1000, height: 800)
        let visibleFrame = CGRect(x: 100, y: 200, width: 1000, height: 760)
        let target = AskNugumiPetTarget(
            x: 0.25,
            y: 0.10,
            coordinateSpace: .screenshotNormalized
        )

        let point = AskNugumiCoordinateMapper.screenPoint(
            for: target,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(point.x, 350, accuracy: 0.001)
        XCTAssertEqual(point.y, 920, accuracy: 0.001)
    }

    func testClampsMappedCoordinateToVisibleFrame() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let visibleFrame = CGRect(x: 50, y: 40, width: 900, height: 700)
        let target = AskNugumiPetTarget(
            x: 1.0,
            y: 1.0,
            coordinateSpace: .screenshotNormalized
        )

        let point = AskNugumiCoordinateMapper.screenPoint(
            for: target,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(point.x, 950, accuracy: 0.001)
        XCTAssertEqual(point.y, 40, accuracy: 0.001)
    }

    func testExactScreenPointKeepsMenuBarCoordinatesForTargetMarker() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 760)
        let target = AskNugumiPetTarget(
            x: 0.5,
            y: 0.0,
            coordinateSpace: .screenshotNormalized
        )

        let movementPoint = AskNugumiCoordinateMapper.screenPoint(
            for: target,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )
        let markerPoint = AskNugumiCoordinateMapper.exactScreenPoint(
            for: target,
            screenFrame: screenFrame
        )

        XCTAssertEqual(movementPoint.y, 760, accuracy: 0.001)
        XCTAssertEqual(markerPoint.y, 800, accuracy: 0.001)
    }

    func testAnswerTargetPresentationKeepsPetStillAndShowsExactMarker() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let target = AskNugumiPetTarget(
            x: 0.82,
            y: 0.18,
            coordinateSpace: .screenshotNormalized
        )

        let presentation = AskNugumiPetAnswerTargetPresentationPolicy.presentation(
            for: target,
            screenFrame: screenFrame
        )

        XCTAssertNil(presentation.movementTarget)
        XCTAssertEqual(presentation.markerTarget.x, 820, accuracy: 0.001)
        XCTAssertEqual(presentation.markerTarget.y, 656, accuracy: 0.001)
    }

    func testTargetMarkerFrameCentersOnExactPoint() {
        let point = CGPoint(x: 128, y: 64)
        let frame = AskNugumiTargetMarkerMetrics.frame(centeredAt: point)

        XCTAssertEqual(frame.midX, point.x, accuracy: 0.001)
        XCTAssertEqual(frame.midY, point.y, accuracy: 0.001)
        XCTAssertEqual(frame.width, AskNugumiTargetMarkerMetrics.size)
        XCTAssertEqual(frame.height, AskNugumiTargetMarkerMetrics.size)
    }

    func testAnswerTargetMarkerUsesSeparatePanelWithoutExpandingBubblePanel() {
        let bubblePanelFrame = CGRect(x: 40, y: 86, width: 300, height: 136)
        let markerTarget = CGPoint(x: 48, y: 48)

        let presentation = AskNugumiPetAnswerTargetPanelMetrics.presentation(
            bubblePanelFrame: bubblePanelFrame,
            markerTarget: markerTarget
        )

        XCTAssertEqual(presentation.bubblePanelFrame, bubblePanelFrame)
        guard let markerPanelFrame = presentation.markerPanelFrame,
              let localMarkerTarget = presentation.localMarkerTarget
        else {
            return XCTFail("Expected a separate marker panel.")
        }
        XCTAssertEqual(markerPanelFrame.midX, markerTarget.x, accuracy: 0.001)
        XCTAssertEqual(markerPanelFrame.midY, markerTarget.y, accuracy: 0.001)
        XCTAssertEqual(localMarkerTarget.x, markerPanelFrame.width / 2, accuracy: 0.001)
        XCTAssertEqual(localMarkerTarget.y, markerPanelFrame.height / 2, accuracy: 0.001)
    }

    func testFloatingTargetPresentationPlacesButtonNearTargetAndPointsArrowBack() {
        let presentation = AskNugumiFloatingTargetPresentationPolicy.presentation(
            targetPoint: CGPoint(x: 500, y: 500),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )

        XCTAssertEqual(presentation.panelFrame.midX, 520, accuracy: 0.001)
        XCTAssertEqual(presentation.panelFrame.midY, 480, accuracy: 0.001)
        XCTAssertEqual(presentation.arrowAngleRadians, 3 * .pi / 4, accuracy: 0.001)
    }

    func testFloatingTargetPresentationClampsButtonButKeepsArrowPointingToExactTarget() {
        let presentation = AskNugumiFloatingTargetPresentationPolicy.presentation(
            targetPoint: CGPoint(x: 990, y: 10),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )

        XCTAssertLessThanOrEqual(presentation.panelFrame.maxX, 1000 + 0.001)
        XCTAssertGreaterThanOrEqual(presentation.panelFrame.minY, 0 - 0.001)
        XCTAssertEqual(presentation.arrowAngleRadians, -.pi / 4, accuracy: 0.001)
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

        XCTAssertEqual(layout.pillFrame.size.height, 38, accuracy: 0.001)
        XCTAssertEqual(layout.panelSize.height, 66, accuracy: 0.001)
        XCTAssertEqual(layout.cornerRadius, 19, accuracy: 0.001)
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
