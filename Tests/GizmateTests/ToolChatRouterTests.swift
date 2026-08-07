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
