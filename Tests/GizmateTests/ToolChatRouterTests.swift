import XCTest
@testable import Gizmate

/// Which of three things a message typed into Home's chat is asking for.
///
/// Worth pinning because the two ways it can be wrong cost very different
/// amounts. Reading an answer as a build request makes the app start writing
/// software nobody asked for; reading a build request as an answer costs one
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

    // MARK: - Reading Gizmate's own reply

    func testABareBuildStartsABuildWithNoBriefOfItsOwn() {
        XCTAssertEqual(
            ToolChatRouter.directive(in: "BUILD", tools: []), .build(brief: nil)
        )
    }

    /// The brief is the reason one agent beats two. "Yes, do that" describes
    /// nothing on its own, and only the agent holding the conversation can say
    /// what "that" was.
    func testTheBriefTravelsWithTheDirective() {
        XCTAssertEqual(
            ToolChatRouter.directive(in: "BUILD: renames screenshots by date", tools: []),
            .build(brief: "renames screenshots by date")
        )
    }

    func testAnEmptyBriefIsNoBrief() {
        XCTAssertEqual(
            ToolChatRouter.directive(in: "BUILD:   ", tools: []), .build(brief: nil)
        )
    }

    func testEditNamesItsTool() {
        let prices = tool("Prices")
        XCTAssertEqual(
            ToolChatRouter.directive(in: "EDIT: Prices", tools: [prices]), .edit(id: prices.id)
        )
    }

    func testEditIsCaseInsensitiveAboutTheName() {
        let prices = tool("Prices")
        XCTAssertEqual(
            ToolChatRouter.directive(in: "edit: prices", tools: [prices]), .edit(id: prices.id)
        )
    }

    /// The model naming a tool that does not exist is a hallucination, and the
    /// answer to one is the cheap side, not the closest guess.
    func testEditNamingNothingIsProse() {
        XCTAssertNil(
            ToolChatRouter.directive(in: "EDIT: Weather", tools: [tool("Prices")])
        )
    }

    /// The failure this guards is a directive quoted inside a real answer. A
    /// reply explaining what BUILD means must not build anything.
    func testADirectiveMustOwnTheFirstLine() {
        for reply in [
            "",
            "sure!",
            "I think you want a tool. BUILD: something",
            "Here is what I would do:\nBUILD: a thing",
            "EDIT",
            "BUILDINGS are expensive",
        ] {
            XCTAssertNil(
                ToolChatRouter.directive(in: reply, tools: [tool("Prices")]),
                "reply: \(reply)"
            )
        }
    }

    /// Everything after the first line is the model padding a command it was
    /// told not to explain. The command still stands.
    func testATrailingExplanationDoesNotVoidTheDirective() {
        XCTAssertEqual(
            ToolChatRouter.directive(in: "BUILD: a grammar fixer\nOn it!", tools: []),
            .build(brief: "a grammar fixer")
        )
    }

    // MARK: - Holding the stream back

    /// Nothing is shown until the reply proves it is prose, because a directive
    /// typing itself out in front of the user is the machinery showing through.
    func testAPartialThatCouldStillBecomeADirectiveIsHeld() {
        for partial in ["", " ", "B", "BUI", "BUILD", "BUILD:", "BUILD: a gizmo that", "ED"] {
            XCTAssertTrue(
                ToolChatRouter.mayBeDirective(partial), "partial: \(partial)"
            )
        }
    }

    /// And the moment it cannot be one, it shows. A held answer is a stalled
    /// answer, so this must be decided in a few characters and never wait for
    /// the reply to finish.
    func testAPartialThatCannotBeADirectiveIsShownAtOnce() {
        for partial in ["I can", "Buildings", "BUILDING", "Sure", "That depends"] {
            XCTAssertFalse(
                ToolChatRouter.mayBeDirective(partial), "partial: \(partial)"
            )
        }
    }

    // MARK: - What the agent is told it has

    func testTheGizmoNamesAreListedSoEditCanNameOne() {
        let listing = ToolChatRouter.knownTools([tool("Prices"), tool("Notes")])
        XCTAssertTrue(listing.contains("Prices"))
        XCTAssertTrue(listing.contains("Notes"))
    }

    func testWithNoGizmosTheAgentIsToldEditIsImpossible() {
        XCTAssertTrue(ToolChatRouter.knownTools([]).contains("no gizmos"))
    }

    /// A gizmo with no name cannot be named, so listing it invites an EDIT that
    /// resolves to nothing.
    func testAnUnnamedGizmoIsNotOffered() {
        XCTAssertTrue(ToolChatRouter.knownTools([tool("")]).contains("no gizmos"))
    }
}
