import XCTest
@testable import Gizmate

@MainActor
final class ToolPlacementTests: XCTestCase {
    /// The card offers an edge to exactly the outputs the dock will show, and
    /// every edge to those, so neither set can grow past the card unnoticed.
    func testEveryOutputIsOfferedAHomeAndResidentsAreOfferedEveryEdge() {
        for output in ToolOutput.allCases {
            let offered = ToolHome.offered(for: output)
            let edges = offered.compactMap { home -> DockEdge? in
                if case .edge(let edge) = home { return edge }
                return nil
            }
            if DockCatalog.dockableGizmoOutputs.contains(output) {
                XCTAssertEqual(Set(edges), Set(DockEdge.allCases), "\(output) is a resident")
                XCTAssertFalse(offered.contains(.ring), "\(output) waits on an edge, it is not summoned")
            } else {
                XCTAssertTrue(edges.isEmpty, "\(output) draws nothing before a run")
                XCTAssertTrue(offered.contains(.ring) && offered.contains(.shortcut))
            }
            XCTAssertEqual(offered.last, .nowhere, "declining is always the last row")
        }
    }

    func testHowToUseLeadsWithTheInputAndNamesTheHome() {
        var tool = GizmateTool(name: "Prices")
        tool.input = .selection
        XCTAssertEqual(
            ToolHome.ring.howToUse(tool, ringShortcut: "Mouse 3", folder: "More"),
            "Select some text, then open the ring (Mouse 3) and pick Prices inside More."
        )
        tool.input = .ask
        XCTAssertEqual(
            ToolHome.shortcut.howToUse(tool, ringShortcut: "Mouse 3"),
            "Press the key you just recorded; it asks what you want."
        )
        XCTAssertTrue(ToolHome.edge(.left).howToUse(tool, ringShortcut: "Mouse 3").hasPrefix("Move the pointer to the left edge"))
        XCTAssertTrue(ToolHome.nowhere.howToUse(tool, ringShortcut: "Mouse 3").contains("Nowhere"))
    }

    /// Saving asks; placing answers; the next message clears the card.
    func testSessionOffersThenSettlesThenResets() {
        let session = ToolBuilderChatSession()
        let tool = GizmateTool(name: "Prices")
        XCTAssertNil(session.placement)

        session.offerPlacement(tool)
        XCTAssertEqual(session.placement, .choosing(tool))

        session.settlePlacement(tool, note: "Done.", section: .ring)
        XCTAssertEqual(session.placement, .settled(tool: tool, note: "Done.", section: .ring))

        session.reset()
        XCTAssertNil(session.placement)
    }
}
