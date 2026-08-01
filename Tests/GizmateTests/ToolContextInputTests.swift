import GizmateToolAgentCore
import XCTest

@testable import Gizmate

final class ToolContextInputTests: XCTestCase {
    /// `.ask` deliberately has no field of its own — the runner resolves the
    /// typed text and hands it over in `selection`, so a script downstream
    /// cannot tell a typed input from a selected one. If this ever diverges,
    /// every `.ask` tool silently starts running on whatever happens to be
    /// highlighted instead.
    func testAskReadsTheTypedTextFromSelection() {
        let context = ToolContext(selection: "convert 40C to F")
        XCTAssertEqual(context.arguments(for: .ask), ["convert 40C to F"])
        XCTAssertEqual(context.arguments(for: .ask), context.arguments(for: .selection))
    }

    /// An empty capsule is "nothing to work on", not an empty argument: the
    /// runner reports it instead of running the tool on "".
    func testAskWithNothingTypedYieldsNoArguments() {
        XCTAssertNil(ToolContext(selection: "").arguments(for: .ask))
    }

    /// The input resolves at run time rather than off the ring's snapshot, which
    /// is what `runTool` branches on before it dispatches.
    func testAskNeedsPromptAndNothingElseDoes() {
        XCTAssertEqual(ToolInput.allCases.filter(\.needsPrompt), [.ask])
        XCTAssertFalse(ToolInput.ask.needsCapture)
    }

    /// Spoken input lands in the same slot as typed input, for the same reason:
    /// a script or prompt downstream is handed one argument and never learns
    /// where it came from.
    func testDictationReadsTheSpokenTextFromSelection() {
        let context = ToolContext(selection: "напомни купить молоко")
        XCTAssertEqual(context.arguments(for: .dictation), ["напомни купить молоко"])
        XCTAssertEqual(context.arguments(for: .dictation), context.arguments(for: .selection))
        XCTAssertNil(ToolContext(selection: "").arguments(for: .dictation))
    }

    /// `runTool` branches on exactly one of these three before dispatching, so a
    /// dictation tool that also claimed to need the capsule or a drag would take
    /// the wrong branch and never reach the mic.
    func testDictationNeedsTheMicAndNothingElseDoes() {
        XCTAssertEqual(ToolInput.allCases.filter(\.needsDictation), [.dictation])
        XCTAssertFalse(ToolInput.dictation.needsPrompt)
        XCTAssertFalse(ToolInput.dictation.needsCapture)
        XCTAssertEqual(ToolInput.dictation.rawValue, "dictation")
    }

    /// Ring folders and manifests round-trip inputs by raw value, and the agent
    /// protocol maps `ToolAgentCandidateInputV1` across the same strings.
    func testAskRawValueIsStable() {
        XCTAssertEqual(ToolInput.ask.rawValue, "ask")
        XCTAssertEqual(ToolInput(rawValue: "ask"), .ask)
    }

    /// A prompt tool works on text the user is looking at, and there are three
    /// ways for that to arrive. The sidecar's own schema and the capability
    /// description have always offered all three, so the host has to accept all
    /// three — a candidate the model was told to write must not come back as
    /// invalid.
    func testPromptCandidateAcceptsEveryInputTheModelIsOffered() throws {
        for input in [
            ToolAgentCandidateInputV1.selection,
            .ask,
            .dictation,
            .screenshotText,
        ] {
            XCTAssertNoThrow(
                try ToolAgentCandidateV1(
                    kind: .prompt,
                    name: "Explain",
                    brief: "Explains the text.",
                    symbolName: "sparkles",
                    input: input,
                    output: .panel,
                    trigger: .always,
                    prompt: "Explain this.",
                    appliesTargetLanguage: true
                ),
                "prompt candidate should accept \(input.rawValue) input"
            )
        }
    }

    /// The inputs a prompt tool cannot work on: it only ever sees text, so a
    /// file list or a PNG path is not something it can be handed.
    func testPromptCandidateStillRejectsNonTextInputs() {
        for input in [
            ToolAgentCandidateInputV1.files,
            .screenshot,
        ] {
            XCTAssertThrowsError(
                try ToolAgentCandidateV1(
                    kind: .prompt,
                    name: "Explain",
                    brief: "Explains the text.",
                    symbolName: "sparkles",
                    input: input,
                    output: .panel,
                    trigger: .always,
                    prompt: "Explain this.",
                    appliesTargetLanguage: true
                ),
                "prompt candidate should reject \(input.rawValue) input"
            )
        }
    }
}
