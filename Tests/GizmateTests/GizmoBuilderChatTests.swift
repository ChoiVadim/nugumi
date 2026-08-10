import Combine
import Foundation
import GizmateToolAgentCore
import XCTest
@testable import Gizmate

/// The builder's own transcript, and what the chat may offer once a candidate
/// is ready.
@MainActor
final class GizmoBuilderChatTests: XCTestCase {
    private func makeBuilder() -> GizmoBuilder {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GizmoBuilderChatTests.\(UUID().uuidString)")
        return GizmoBuilder(
            tools: ToolsStore(directoryURL: dir, migrateLegacy: false),
            runner: { _, _, _ in .idle },
            agent: GizmoBuilder.Agent(
                generate: { _, _, _, _, _, _ in fatalError("unused") },
                revise: { _, _, _, _, _, _, _, _ in fatalError("unused") },
                repair: { _, _, _, _, _, _, _ in fatalError("unused") }
            )
        )
    }

    /// A view holds `@ObservedObject var builder` and reads `builder.chat`,
    /// and SwiftUI does not follow that hop on its own. Without the forward,
    /// the build's running commentary stood still until something else on the
    /// builder published: leaving the section and coming back was the only
    /// reliable way to see the next step.
    func testTheChatsChangesReachAnyoneObservingTheBuilder() {
        let builder = makeBuilder()
        let heard = expectation(description: "the builder published")
        let token = builder.objectWillChange.sink { _ in heard.fulfill() }
        defer { token.cancel() }

        builder.chat.recordActivity("Writing the script…")

        wait(for: [heard], timeout: 1)
    }

    private func generated(
        kind: ToolKind,
        output: ToolOutput,
        assurance: ToolAgentAssuranceV1
    ) -> GeneratedTool {
        GeneratedTool(
            tool: GizmateTool(name: "Mac Usage", kind: kind, input: .none, output: output),
            script: "print()",
            summary: "",
            brief: "",
            assurance: assurance
        )
    }

    /// A script Gizmate could only smoke-test is the one case worth handing
    /// back: it ran, but nothing proved the answer is the wanted one.
    func testAScriptThatOnlyRanIsWorthTrying() {
        XCTAssertEqual(
            GizmoBuilder.trial(for: generated(kind: .python, output: .panel, assurance: .smoke)),
            .untried
        )
    }

    func testAScriptGizmateAlreadyVerifiedNeedsNoTrial() {
        XCTAssertEqual(
            GizmoBuilder.trial(for: generated(kind: .python, output: .panel, assurance: .verified)),
            .notNeeded
        )
    }

    /// A surface's run prints rows for a panel, not an answer: pressing "Try
    /// it" shows a person a line of JSON, which grades nothing. Judging one
    /// means looking at the edge it lives on.
    func testASurfaceIsNeverOfferedARun() {
        for assurance in [ToolAgentAssuranceV1.smoke, .unverified] {
            XCTAssertEqual(
                GizmoBuilder.trial(for: generated(kind: .python, output: .surface, assurance: assurance)),
                .notNeeded,
                "\(assurance)"
            )
        }
    }

    /// The half that used to disagree with itself: a prompt gizmo Gizmate
    /// could not verify was told to "run it once and tell me what happened",
    /// with no button anywhere to press.
    func testAGizmoWithNoRunOfItsOwnIsNeverOfferedARun() {
        for kind in [ToolKind.prompt, .native] {
            XCTAssertEqual(
                GizmoBuilder.trial(for: generated(kind: kind, output: .panel, assurance: .unverified)),
                .notNeeded,
                "\(kind)"
            )
        }
    }
}
