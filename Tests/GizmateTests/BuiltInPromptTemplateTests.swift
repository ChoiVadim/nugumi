import XCTest
@testable import Gizmate

/// Tokenising three ~600-word prompts is a mechanical find-replace, and a
/// dropped token does not crash — it silently strips the target language or the
/// user's writing style out of every request. These tests are the only thing
/// that notices.
final class BuiltInPromptTemplateTests: XCTestCase {

    private let language = TranslationLanguage.language(id: "en")   // promptName "English"
    private let category = AppCategory.workMessages

    private static let tokenNames = [
        "language", "app", "writingStyle", "genZ", "voice", "cleanup", "glossary",
    ]

    /// Every token-bearing block is deliberately non-empty, so a dropped token
    /// changes the output instead of resolving to "" and looking fine.
    /// No braces in the voice sample — the token assertions look for leftovers.
    private var composition: CompositionSettings {
        CompositionSettings(
            style: .casual,
            cleanup: .light,
            snippets: [],
            genZ: true,
            voiceSample: "Hi there,\n\nThanks!\n\nVadim"
        )
    }

    private func rendered(_ mode: TranslationMode) -> String {
        mode.systemPrompt(
            targetLanguage: language,
            appCategory: category,
            composition: composition
        )
    }

    // MARK: - Template fidelity

    /// Every token must actually resolve. A surviving `{language}` means the map
    /// is missing that key for this mode.
    func testNoTokenSurvivesRendering() {
        for mode in [TranslationMode.selection, .draftMessage, .smartReply] {
            let output = rendered(mode)
            for token in Self.tokenNames {
                XCTAssertFalse(
                    output.contains("{\(token)}"),
                    "\(mode) left {\(token)} unresolved"
                )
            }
        }
    }

    /// `.selection` interpolated the language in eight separate places before
    /// the refactor, so its template must carry eight `{language}` tokens.
    /// Counting is what catches "replaced the first one and moved on".
    ///
    /// Counted on the template, not the rendered output: the Gen Z block names
    /// the language too, so counting "English" in the result would measure
    /// something else and drift whenever that block is reworded.
    func testSelectionTemplateKeepsEveryLanguageToken() {
        let template = try? XCTUnwrap(TranslationMode.selection.shippedPromptTemplate)
        XCTAssertEqual(
            (template ?? "").components(separatedBy: "{language}").count - 1,
            8
        )
    }

    /// The composition blocks are spliced into the middle of the prompt, not
    /// appended, so a lost token is invisible unless the block is looked for.
    func testDraftMessageCarriesEveryCompositionBlock() {
        let output = rendered(.draftMessage)
        XCTAssertTrue(output.contains("Writing style — "))
        XCTAssertTrue(output.contains("Cleanup — "))
        XCTAssertTrue(output.contains("Voice sample — "))
        XCTAssertTrue(output.contains(category.promptHint))
    }

    func testSmartReplyCarriesEveryCompositionBlock() {
        let output = rendered(.smartReply)
        XCTAssertTrue(output.contains("Writing style — "))
        XCTAssertTrue(output.contains("Cleanup — "))
        XCTAssertTrue(output.contains("Voice sample — "))
        XCTAssertTrue(output.contains(category.promptHint))
    }

    /// `.summarizeChat` and `.summarizePage` were deliberately left interpolated.
    /// If someone tokenises them later without adding a token map, this catches
    /// it before it ships.
    func testUntokenisedModesStillCarryTheirLanguage() {
        for mode in [TranslationMode.summarizeChat, .summarizePage, .revise] {
            XCTAssertTrue(
                rendered(mode).contains(language.promptName),
                "\(mode) lost its target language"
            )
        }
    }

    // MARK: - Overrides

    /// A user override replaces the shipped instruction but keeps every layer
    /// wrapped around it — that is the entire reason the templates carry tokens.
    func testOverrideReplacesTheBodyButKeepsTheLanguage() {
        TranslationMode.promptOverrides = [.explain: "Summarise this in {language}."]
        defer { TranslationMode.promptOverrides = [:] }

        let output = rendered(.selection)

        XCTAssertTrue(output.hasPrefix("Summarise this in English."))
        XCTAssertFalse(output.contains("curious ~12-year-old"))
    }

    /// An override on one built-in must not leak into another.
    func testOverrideIsScopedToItsOwnMode() {
        TranslationMode.promptOverrides = [.explain: "Overridden."]
        defer { TranslationMode.promptOverrides = [:] }

        XCTAssertFalse(rendered(.smartReply).contains("Overridden."))
    }

    /// An empty or whitespace-only override is a user who cleared the field, not
    /// a request for an empty system prompt.
    func testBlankOverrideFallsBackToShipped() {
        TranslationMode.promptOverrides = [.explain: "   \n  "]
        defer { TranslationMode.promptOverrides = [:] }

        XCTAssertTrue(rendered(.selection).contains("curious ~12-year-old"))
    }

    // MARK: - Context toggles

    /// Explain's template has no writing-style token, so "Use my Voice" has to
    /// append the block — and switching it off has to take it away again.
    func testExplainVoiceToggleAddsAndRemovesTheStyleBlock() {
        XCTAssertTrue(rendered(.selection).contains("Writing style — "))

        TranslationMode.voiceOffBuiltIns = [.explain]
        defer { TranslationMode.voiceOffBuiltIns = [] }

        XCTAssertFalse(rendered(.selection).contains("Writing style — "))
    }

    /// Rewrite and Reply splice the style through tokens instead, so their
    /// switch is `usesCompositionSettings` — off means the caller hands the
    /// prompt no composition at all.
    func testRewriteAndReplyVoiceToggleGatesComposition() {
        XCTAssertTrue(TranslationMode.draftMessage.usesCompositionSettings)
        XCTAssertTrue(TranslationMode.smartReply.usesCompositionSettings)

        TranslationMode.voiceOffBuiltIns = [.rewrite, .reply]
        defer { TranslationMode.voiceOffBuiltIns = [] }

        XCTAssertFalse(TranslationMode.draftMessage.usesCompositionSettings)
        XCTAssertFalse(TranslationMode.smartReply.usesCompositionSettings)
    }

    /// Values are spliced in, never rescanned: a snippet or voice sample holding
    /// the literal text `{language}` must survive as written. A `reduce` of
    /// `replacingOccurrences` would substitute it.
    func testTokensInsideSubstitutedValuesAreNotRescanned() {
        let rendered = TranslationMode.renderPrompt(
            "A {voice} B",
            tokens: ["voice": "{language}", "language": "English"]
        )
        XCTAssertEqual(rendered, "A {language} B")
    }

    /// An unknown token stays put rather than vanishing, so a typo in an
    /// override is visible in the output instead of silently dropping context.
    func testUnknownTokenIsLeftVerbatim() {
        XCTAssertEqual(
            TranslationMode.renderPrompt("A {nope} B", tokens: ["language": "English"]),
            "A {nope} B"
        )
    }

    func testUnclosedBraceIsLeftVerbatim() {
        XCTAssertEqual(
            TranslationMode.renderPrompt("A {language B", tokens: ["language": "English"]),
            "A {language B"
        )
    }
}
