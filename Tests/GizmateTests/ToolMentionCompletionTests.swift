import XCTest
@testable import Gizmate

/// Completing a `@tool-name` while it is being typed.
///
/// All of it is string work, which is why it is a type of its own rather than
/// state inside the composer: a popup is easy to look at and hard to reason
/// about, and every way this can be wrong is "which @ did they mean".
final class ToolMentionCompletionTests: XCTestCase {
    private func tool(_ name: String) -> GizmateTool {
        GizmateTool(name: name, kind: .python, input: .selection, output: .panel)
    }

    // MARK: - What is being typed

    func testABareAtOpensAMention() {
        XCTAssertEqual(ToolMentionCompletion.activeFragment(in: "@"), "")
    }

    func testTheFragmentIsWhateverFollowsTheLastAt() {
        XCTAssertEqual(ToolMentionCompletion.activeFragment(in: "change @Pri"), "Pri")
    }

    /// Tool names have spaces in them, so the fragment has to be allowed to.
    /// Nothing needs to guess where the name ends: a fragment past the real
    /// name matches nothing and the list goes away on its own.
    func testAFragmentMaySpanSpaces() {
        XCTAssertEqual(ToolMentionCompletion.activeFragment(in: "@Price wat"), "Price wat")
    }

    /// The one that would fire while typing an email address.
    func testAnAtInTheMiddleOfAWordIsNotAMention() {
        XCTAssertNil(ToolMentionCompletion.activeFragment(in: "write to vadim@example"))
    }

    /// Completion is about what is being typed now. An `@` with a newline after
    /// it is one the user has already moved on from.
    func testAMentionDoesNotSurviveANewline() {
        XCTAssertNil(ToolMentionCompletion.activeFragment(in: "@Prices\nand also"))
    }

    func testProseFollowingAnAtEventuallyStopsBeingAName() {
        let long = "@" + String(repeating: "x", count: ToolMentionCompletion.maximumFragment + 1)
        XCTAssertNil(ToolMentionCompletion.activeFragment(in: long))
    }

    func testTextWithNoAtIsNotAMention() {
        XCTAssertNil(ToolMentionCompletion.activeFragment(in: "just talking"))
    }

    // MARK: - What is offered

    /// A bare `@` is a picker, not a character you have to guess after.
    func testAnEmptyFragmentOffersEverything() {
        let all = [tool("Prices"), tool("Todo")]
        XCTAssertEqual(
            ToolMentionCompletion.matches(for: "", among: all).map(\.name), ["Prices", "Todo"]
        )
    }

    func testMatchingIsByPrefixAndIgnoresCase() {
        let all = [tool("Prices"), tool("Todo")]
        XCTAssertEqual(
            ToolMentionCompletion.matches(for: "pri", among: all).map(\.name), ["Prices"]
        )
    }

    func testAFragmentPastTheNameOffersNothing() {
        XCTAssertTrue(
            ToolMentionCompletion.matches(for: "Prices every hour", among: [tool("Prices")]).isEmpty
        )
    }

    func testANamelessToolIsNeverOffered() {
        XCTAssertTrue(ToolMentionCompletion.matches(for: "", among: [tool("")]).isEmpty)
    }

    func testTheListIsCapped() {
        let many = (1...20).map { tool("Tool \($0)") }
        XCTAssertEqual(ToolMentionCompletion.matches(for: "", among: many, limit: 3).count, 3)
    }

    // MARK: - Picking one

    /// The half-typed name must not be left sitting in front of the full one.
    func testPickingReplacesTheFragmentRatherThanAppending() {
        XCTAssertEqual(
            ToolMentionCompletion.completing("change @Pri", with: tool("Prices")),
            "change @Prices "
        )
    }

    /// The trailing space is what `ToolChatRouter.mentioned` needs to find a
    /// name that prose follows.
    func testTheCompletedNameIsFollowedByASpace() {
        XCTAssertEqual(ToolMentionCompletion.completing("@", with: tool("Prices")), "@Prices ")
    }

    /// Typing on after a completed mention offers nothing, which is what closes
    /// the list.
    ///
    /// Not by `activeFragment` going nil — it stays non-nil, because a fragment
    /// is allowed to span spaces so that "Price watcher" can be typed at all.
    /// Whether a list appears is `matches` having something in it, and that is
    /// the honest question: a fragment that has run past every name matches
    /// nothing. (An earlier version of this test asserted the fragment itself
    /// closed, which would have meant no name with a space in it could ever be
    /// completed.)
    func testTypingOnAfterAMentionOffersNothing() {
        let prices = tool("Prices")
        let text = ToolMentionCompletion.completing("@", with: prices) + "louder"
        XCTAssertTrue(ToolMentionCompletion.matches(for: "Prices louder", among: [prices]).isEmpty)
        XCTAssertEqual(ToolChatRouter.mentioned(in: text, among: [prices]), prices.id)
    }

    /// The two halves have to agree, or a name picked from the list is one the
    /// router then fails to recognise.
    func testAPickedNameIsOneTheRouterFinds() {
        let prices = tool("Prices")
        let text = ToolMentionCompletion.completing("make @Pri", with: prices) + "quieter"
        XCTAssertEqual(ToolChatRouter.mentioned(in: text, among: [prices]), prices.id)
    }
}
