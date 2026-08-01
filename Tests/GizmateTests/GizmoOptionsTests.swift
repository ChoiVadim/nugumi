import XCTest
@testable import Gizmate

/// `chosenOption` is the one field on a gizmo that belongs to a run rather than
/// to the gizmo. If it ever reached `tool.json`, a gizmo would start remembering
/// the last button pressed — which is not a setting anybody asked for.
final class GizmoOptionsTests: XCTestCase {

    func testOptionsSurviveEncodingAndChosenOptionDoesNot() throws {
        var tool = GizmateTool(name: "Download", options: ["360p", "480p", "720p"])
        tool.chosenOption = "480p"

        let encoded = try JSONEncoder().encode(tool)
        XCTAssertFalse(String(data: encoded, encoding: .utf8)?.contains("chosenOption") ?? true)

        let decoded = try JSONDecoder().decode(GizmateTool.self, from: encoded)
        XCTAssertEqual(decoded.options, ["360p", "480p", "720p"])
        XCTAssertNil(decoded.chosenOption)
    }

    /// A gizmo saved before options existed decodes as one with none, rather
    /// than throwing away everything else the user configured.
    func testAManifestWithNoOptionsKeyDecodes() throws {
        let json = """
        {"id":"5B9F9F3E-0000-4000-8000-000000000001","name":"Plain","kind":"prompt",\
        "prompt":"Do the thing","symbolName":"sparkles","input":"selection","output":"panel"}
        """
        let decoded = try JSONDecoder().decode(GizmateTool.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.options, [])
        XCTAssertNil(decoded.activeOption)
    }

    func testActiveOptionFallsBackToTheFirst() {
        var tool = GizmateTool(name: "Download", options: ["360p", "480p"])
        XCTAssertEqual(tool.activeOption, "360p")
        tool.chosenOption = "480p"
        XCTAssertEqual(tool.activeOption, "480p")
        XCTAssertNil(GizmateTool(name: "Plain").activeOption)
    }

    func testOneOptionIsNoChoiceAndDuplicatesAndOverflowAreDropped() {
        XCTAssertEqual(GizmateTool(name: "One", options: ["720p"]).options, [])
        XCTAssertEqual(GizmateTool(name: "Blank", options: ["720p", "   "]).options, [])
        XCTAssertEqual(
            GizmateTool(name: "Dupes", options: ["720p", " 720p ", "480p"]).options,
            ["720p", "480p"]
        )
        XCTAssertEqual(
            GizmateTool(name: "Many", options: ["a", "b", "c", "d", "e", "f"]).options,
            ["a", "b", "c", "d", "e"]
        )
    }

    func testTemplateSubstitutionOnlyHappensForAGizmoWithOptions() {
        var tool = GizmateTool(name: "Download", options: ["360p", "720p"])
        tool.chosenOption = "720p"
        XCTAssertEqual(tool.resolvingOption("save at {option}"), "save at 720p")
        XCTAssertEqual(
            GizmateTool(name: "Plain").resolvingOption("save at {option}"),
            "save at {option}"
        )
    }
}
