import XCTest
@testable import GizmateToolAgentCore

final class ToolAgentLayoutTests: XCTestCase {
    private let folderHub = """
    {"node":"grid","minimumWidth":96,"empty":"Nothing in Downloads",
     "cell":{"node":"card","title":"$name","subtitle":"$size",
             "icon":"file:$path","drag":"file:$path","tap":"reveal:$path"}}
    """

    func testTheFolderHubDecodesAndReEncodes() throws {
        let layout = try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(folderHub.utf8))
        guard case let .grid(cell, minimumWidth, empty) = layout else {
            return XCTFail("expected a grid")
        }
        XCTAssertEqual(minimumWidth, 96)
        XCTAssertEqual(empty, "Nothing in Downloads")
        guard case let .card(title, subtitle, icon, drag, tap) = cell else {
            return XCTFail("expected a card")
        }
        XCTAssertEqual(title, .key("name"))
        XCTAssertEqual(subtitle, .key("size"))
        XCTAssertEqual(icon, .file(key: "path"))
        XCTAssertEqual(drag, .file(key: "path"))
        XCTAssertEqual(tap, .reveal(key: "path"))

        let round = try JSONDecoder().decode(
            ToolAgentLayoutV1.self,
            from: JSONEncoder().encode(layout)
        )
        XCTAssertEqual(round, layout)
    }

    func testKeysTheLayoutReferences() throws {
        let layout = try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(folderHub.utf8))
        XCTAssertEqual(layout.referencedKeys, ["name", "size", "path"])
        XCTAssertEqual(layout.fileKeys, ["path"])
    }

    func testALiteralTitleIsNotAKey() throws {
        let json = #"{"node":"text","value":"Downloads"}"#
        let layout = try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(json.utf8))
        XCTAssertEqual(layout, .text(.literal("Downloads")))
        XCTAssertEqual(layout.referencedKeys, [])
    }

    /// Strict keys, the same contract `ToolAgentAskUserRequestV1` holds: a
    /// field the model invented is a misunderstanding, not a nicety to ignore.
    func testAnUnknownKeyIsRejected() {
        let json = #"{"node":"text","value":"x","colour":"red"}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(json.utf8))
        )
    }

    func testAnUnknownNodeIsRejected() {
        let json = #"{"node":"webview","url":"https://example.com"}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(json.utf8))
        )
    }

    func testAnUnknownModifierPrefixIsRejected() {
        let json = #"{"node":"card","title":"$n","drag":"folder:$path"}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(json.utf8))
        )
    }

    /// A modifier that acts on a file needs a key to read the path out of, so a
    /// literal there is a candidate that would draw a card nothing can drag.
    func testAFileModifierWithoutAKeyIsRejected() {
        let json = #"{"node":"card","title":"$n","drag":"file:Downloads"}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(json.utf8))
        )
    }

    func testNestingDeeperThanThreeIsRejected() {
        let deep = #"{"node":"grid","minimumWidth":96,"empty":"","cell":"#
            + #"{"node":"list","empty":"","row":"#
            + #"{"node":"list","empty":"","row":{"node":"text","value":"x"}}}}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(deep.utf8))
        )
    }
}
