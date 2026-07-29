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

    /// Ring folders and manifests round-trip inputs by raw value, and the agent
    /// protocol maps `ToolAgentCandidateInputV1` across the same strings.
    func testAskRawValueIsStable() {
        XCTAssertEqual(ToolInput.ask.rawValue, "ask")
        XCTAssertEqual(ToolInput(rawValue: "ask"), .ask)
    }
}
