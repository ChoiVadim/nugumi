import XCTest
@testable import Gizmate

/// Which of three things a message typed into Home's chat is asking for.
///
/// Worth pinning because the two ways it can be wrong cost very different
/// amounts. Reading a question as a build request makes the app start writing
/// software nobody asked for; reading a build request as a question costs one
/// more sentence. Every ambiguous case here resolves to the cheap side.
final class ToolChatRouterTests: XCTestCase {
    private func tool(_ name: String) -> GizmateTool {
        GizmateTool(name: name, kind: .python, input: .selection, output: .panel)
    }

    // MARK: - Mentions

    func testAMentionNamesItsTool() {
        let prices = tool("Prices")
        XCTAssertEqual(
            ToolChatRouter.mentioned(in: "@Prices check twice a day", among: [prices]),
            prices.id
        )
    }

    func testAMentionIsFoundAnywhereInTheMessage() {
        let prices = tool("Prices")
        XCTAssertEqual(
            ToolChatRouter.mentioned(in: "please make @Prices quieter", among: [prices]),
            prices.id
        )
    }

    /// The one that would silently address the wrong gizmo: matching the
    /// shorter name leaves the rest of the real name sitting in the message as
    /// prose, and the user watches a tool they did not name get rewritten.
    func testTheLongestMatchingNameWins() {
        let short = tool("Price")
        let long = tool("Price watcher")
        XCTAssertEqual(
            ToolChatRouter.mentioned(in: "@Price watcher every hour", among: [short, long]),
            long.id
        )
    }

    func testAMentionIsCaseInsensitive() {
        let prices = tool("Prices")
        XCTAssertEqual(
            ToolChatRouter.mentioned(in: "@prices louder", among: [prices]),
            prices.id
        )
    }

    func testAnAtSignThatNamesNothingIsNotAMention() {
        XCTAssertNil(
            ToolChatRouter.mentioned(in: "email me @ 5pm", among: [tool("Prices")])
        )
    }

    /// A stray `@` earlier in the message must not stop the real one being
    /// found — the scan continues past a miss rather than giving up on it.
    func testAStrayAtSignBeforeARealMentionIsSkipped() {
        let prices = tool("Prices")
        XCTAssertEqual(
            ToolChatRouter.mentioned(in: "ping me @ noon about @Prices", among: [prices]),
            prices.id
        )
    }

    func testAToolWithNoNameCannotBeMentioned() {
        XCTAssertNil(ToolChatRouter.mentioned(in: "@ anything", among: [tool("")]))
    }

    // MARK: - Reading the model back

    func testBuildIsRecognised() {
        XCTAssertEqual(ToolChatRouter.intent(from: "BUILD", tools: []), .build)
    }

    func testTalkIsRecognised() {
        XCTAssertEqual(ToolChatRouter.intent(from: "TALK", tools: []), .talk)
    }

    func testEditNamesItsTool() {
        let prices = tool("Prices")
        XCTAssertEqual(
            ToolChatRouter.intent(from: "EDIT: Prices", tools: [prices]), .edit(prices.id)
        )
    }

    func testEditIsCaseInsensitiveAboutTheName() {
        let prices = tool("Prices")
        XCTAssertEqual(
            ToolChatRouter.intent(from: "edit: prices", tools: [prices]), .edit(prices.id)
        )
    }

    /// The model naming a tool that does not exist is a hallucination, and the
    /// answer to one is the cheap side, not the closest guess.
    func testEditNamingNothingFallsBackToTalk() {
        XCTAssertEqual(
            ToolChatRouter.intent(from: "EDIT: Weather", tools: [tool("Prices")]), .talk
        )
    }

    func testAnythingUnrecognisedFallsBackToTalk() {
        for reply in ["", "sure!", "I think the user wants a tool", "EDIT", "MAYBE"] {
            XCTAssertEqual(
                ToolChatRouter.intent(from: reply, tools: [tool("Prices")]), .talk,
                "reply: \(reply)"
            )
        }
    }
}

/// What the router is shown, which is not only the message.
///
/// Intent is often in the exchange rather than in the sentence: "yes", "go on",
/// "that one" mean nothing alone and everything after the line before them. A
/// router shown one sentence makes the user restate a request they already
/// made, which is the failure this guards.
final class ToolChatRouterRecallTests: XCTestCase {
    private func tool(_ name: String) -> GizmateTool {
        GizmateTool(name: name, kind: .python, input: .selection, output: .panel)
    }

    @MainActor
    private func turn(_ q: String, _ a: String) -> ToolChatConversation.Turn {
        .init(question: q, answer: a)
    }

    @MainActor
    func testTheLastExchangesAreIncludedSoAShortReplyMeansSomething() {
        let prompt = ToolChatRouter.userPrompt(
            message: "yes please",
            tools: [],
            recent: [turn("I rename files every week", "I can build you a gizmo for that.")]
        )
        XCTAssertTrue(prompt.contains("I rename files every week"))
        XCTAssertTrue(prompt.contains("I can build you a gizmo for that."))
        XCTAssertTrue(prompt.contains("yes please"))
    }

    /// Only the last couple. A whole transcript would bury the message being
    /// sorted under everything that came before it, and cost tokens per turn
    /// forever.
    @MainActor
    func testOnlyTheMostRecentExchangesAreShown() {
        let many = (1...6).map { turn("question \($0)", "answer \($0)") }
        let prompt = ToolChatRouter.userPrompt(message: "yes", tools: [], recent: many)

        XCTAssertFalse(prompt.contains("question 1"))
        XCTAssertTrue(prompt.contains("question 6"))
        XCTAssertEqual(ToolChatRouter.recallTurns, 2)
    }

    /// A first message has no history, and must not arrive wrapped in headings
    /// describing an exchange that never happened.
    @MainActor
    func testAFirstMessageCarriesNoHistorySection() {
        let prompt = ToolChatRouter.userPrompt(message: "hello", tools: [], recent: [])
        XCTAssertFalse(prompt.contains("What was said just before"))
        XCTAssertTrue(prompt.contains("hello"))
    }
}
