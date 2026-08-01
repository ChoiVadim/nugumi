import XCTest
@testable import Gizmate

/// A gizmo with options is the second thing in the Ring that expands (Summarize
/// was the first), and the only one that does it from user data. What matters
/// is that picking a circle runs *that* variant — the choice rides inside the
/// value, so nothing between here and the runner had to learn a new parameter.
final class GizmoOptionsRingTests: XCTestCase {

    private func configuration(_ tool: GizmateTool) -> RingConfiguration {
        RingConfiguration(layout: RingLayout(slots: [.tool(tool.id)]), tools: [tool])
    }

    @MainActor
    func testAGizmoWithOptionsBecomesAFannedParent() {
        let tool = GizmateTool(
            name: "Download",
            kind: .python,
            options: ["360p", "480p", "720p"]
        )
        var handlers = RingActionHandlers()
        handlers.tool = { _ in }

        let items = RingBuilder.slots(
            configuration: configuration(tool),
            handlers: handlers,
            dismiss: {}
        )

        let item = items.first ?? nil
        XCTAssertEqual(item?.label, "Download")
        XCTAssertEqual(item?.subLayout, .fan)
        XCTAssertEqual(item?.expandsOnHover, true)
        XCTAssertEqual(item?.subItems.compactMap { $0?.label }, ["360p", "480p", "720p"])
    }

    @MainActor
    func testPickingACircleRunsThatVariantAndDismissesFirst() {
        let tool = GizmateTool(
            name: "Download",
            kind: .python,
            options: ["360p", "480p", "720p"]
        )
        var ran: GizmateTool?
        var dismissedBeforeRun = false
        var dismissed = false
        var handlers = RingActionHandlers()
        handlers.tool = { picked in
            ran = picked
            dismissedBeforeRun = dismissed
        }

        let items = RingBuilder.slots(
            configuration: configuration(tool),
            handlers: handlers,
            dismiss: { dismissed = true }
        )
        items.first??.subItems[safe: 1]??.handler()

        XCTAssertEqual(ran?.chosenOption, "480p")
        XCTAssertEqual(ran?.id, tool.id, "the script, approval and stats all key off the id")
        XCTAssertTrue(dismissedBeforeRun, "the ring tears down before the gizmo runs")
    }

    /// The overwhelming majority of gizmos have no options, and they must keep
    /// drawing as one plain button that fires on click.
    @MainActor
    func testAGizmoWithNoOptionsIsStillAPlainButton() {
        let tool = GizmateTool(name: "Slugify", kind: .python)
        var ran: GizmateTool?
        var handlers = RingActionHandlers()
        handlers.tool = { ran = $0 }

        let items = RingBuilder.slots(
            configuration: configuration(tool),
            handlers: handlers,
            dismiss: {}
        )
        let item = items.first ?? nil
        XCTAssertEqual(item?.expandsOnHover, false)
        item?.handler()
        XCTAssertEqual(ran?.id, tool.id)
        XCTAssertNil(ran?.chosenOption)
    }
}
