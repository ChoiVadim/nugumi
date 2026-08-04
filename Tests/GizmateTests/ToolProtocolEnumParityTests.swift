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
}
