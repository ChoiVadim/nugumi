import GizmateToolAgentCore
import XCTest

@testable import Gizmate

/// `ToolAgentLiveBuilder` converts a saved gizmo into the builder protocol's
/// shape by raw string, falling back to `.notify` / `.none` when the string is
/// unknown (`ToolAgentLiveBuilder.swift:135-136`, and the reverse at 478-479).
/// The fallback is right for a gizmo written by a newer version, and silently
/// destructive for a case someone added on only one side: the user opens their
/// Read-aloud gizmo in the chat builder and it comes back as Notify.
///
/// Nothing else fails when the two enums drift — not the build, not a run — so
/// this is the check.
final class ToolProtocolEnumParityTests: XCTestCase {
    func testEveryOutputSurvivesTheRoundTripToTheBuilderProtocol() {
        for output in ToolOutput.allCases {
            let encoded = ToolAgentCandidateOutputV1(rawValue: output.rawValue)
            XCTAssertNotNil(
                encoded,
                "ToolOutput.\(output.rawValue) has no ToolAgentCandidateOutputV1 case; "
                    + "editing such a gizmo in the builder would silently turn it into Notify."
            )
            XCTAssertEqual(encoded.flatMap { ToolOutput(rawValue: $0.rawValue) }, output)
        }
    }

    func testEveryInputSurvivesTheRoundTripToTheBuilderProtocol() {
        for input in ToolInput.allCases {
            let encoded = ToolAgentCandidateInputV1(rawValue: input.rawValue)
            XCTAssertNotNil(
                encoded,
                "ToolInput.\(input.rawValue) has no ToolAgentCandidateInputV1 case; "
                    + "editing such a gizmo in the builder would silently turn it into Nothing."
            )
            XCTAssertEqual(encoded.flatMap { ToolInput(rawValue: $0.rawValue) }, input)
        }
    }

    /// The editor is what the user picks from, and the protocol is what the chat
    /// builder validates against. When the editor offers more than the protocol
    /// accepts, saving works and opening that gizmo in the builder throws
    /// `invalidCandidate` — a gizmo the user can create but not edit.
    func testTheEditorOffersActionGizmosExactlyWhatTheProtocolAccepts() {
        let offered = Set(
            ToolEditorPanel.outputs(for: .native).compactMap {
                ToolAgentCandidateOutputV1(rawValue: $0.rawValue)
            }
        )
        XCTAssertEqual(offered, ToolAgentCandidateOutputV1.nativeDeliverable)
        XCTAssertFalse(offered.contains(.panel), "an Action has no model to write a panel's answer")
        XCTAssertFalse(offered.contains(.annotate), "an Action has no model to decide what to draw")
    }

    /// The other three kinds carry a model or a script, so nothing is withheld.
    func testEveryOtherKindIsOfferedEveryResult() {
        for kind in [ToolKind.prompt, .agent, .python] {
            XCTAssertEqual(ToolEditorPanel.outputs(for: kind), ToolOutput.allCases)
        }
    }

    /// The eval suite is the only thing that drives a real build end to end, so
    /// an input or result no case asks for ships having never been generated
    /// once. That is exactly how `drawnScreen` reached a user before it reached
    /// a test. Cheap to keep honest: adding a case to `ToolEvalSuite` is one
    /// literal, and this fails the moment the enum grows without one.
    func testTheEvalSuiteAsksForEveryInputAndEveryResult() {
        let missingInputs = Set(ToolInput.allCases)
            .subtracting(ToolEvalSuite.all.compactMap(\.input))
        let missingOutputs = Set(ToolOutput.allCases)
            .subtracting(ToolEvalSuite.all.compactMap(\.output))
        XCTAssertEqual(
            missingInputs.map(\.rawValue).sorted(), [],
            "no eval case asks for a gizmo with these inputs"
        )
        XCTAssertEqual(
            missingOutputs.map(\.rawValue).sorted(), [],
            "no eval case asks for a gizmo with these results"
        )
    }

    /// Every input the editor offers a prompt gizmo has to survive the builder's
    /// own validation.
    ///
    /// This has now failed twice for the same reason: a case was added to the
    /// enum, to the sidecar schema and to the capability description, while the
    /// allowlist inside `ToolAgentCandidateV1.validate` stayed where it was.
    /// Both times the model wrote exactly the candidate it had been told to
    /// write and the user saw "The model returned an invalid agent action",
    /// which names neither the field nor the value that was refused.
    func testEveryPromptPairingTheEditorOffersPassesCandidateValidation() throws {
        for input in ToolInput.allCases {
            for output in ToolEditorPanel.outputs(for: .prompt) {
                guard let wireInput = ToolAgentCandidateInputV1(rawValue: input.rawValue),
                      let wireOutput = ToolAgentCandidateOutputV1(rawValue: output.rawValue)
                else {
                    return XCTFail("\(input.rawValue)/\(output.rawValue) has no protocol case")
                }
                XCTAssertNoThrow(
                    try ToolAgentCandidateV1(
                        kind: .prompt,
                        name: "Explain",
                        brief: "Explains the thing.",
                        symbolName: "sparkles",
                        input: wireInput,
                        output: wireOutput,
                        trigger: .always,
                        prompt: "Explain what this is."
                    ),
                    "a prompt gizmo the editor offers as \(input.rawValue) → "
                        + "\(output.rawValue) is rejected by the builder"
                )
            }
        }
    }
}
