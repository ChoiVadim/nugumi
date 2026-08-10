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
        guard case let .card(card) = cell else {
            return XCTFail("expected a card")
        }
        XCTAssertEqual(card.title, .key("name"))
        XCTAssertEqual(card.subtitle, .key("size"))
        XCTAssertEqual(card.icon, .file(key: "path"))
        XCTAssertEqual(card.drag, .file(key: "path"))
        XCTAssertEqual(card.tap, .reveal(key: "path"))
        XCTAssertEqual(card.details, [])
        XCTAssertNil(card.meter)
        XCTAssertNil(card.chart)

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

    /// A `file:` icon contributes nothing here — only a `symbol:` name is a
    /// glyph the OS has to actually resolve, which is what `iconSymbols`
    /// exists to let `SurfaceLayoutCheck` verify at build time.
    func testAFileIconContributesNoIconSymbol() throws {
        let layout = try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(folderHub.utf8))
        XCTAssertEqual(layout.iconSymbols, [])
    }

    func testIconSymbolsTheLayoutNames() throws {
        let json = #"{"node":"list","empty":"x","row":{"node":"card","title":"$n","icon":"symbol:folder"}}"#
        let layout = try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(json.utf8))
        XCTAssertEqual(layout.iconSymbols, ["folder"])
    }

    /// `"symbol:$glyph"` binds a row key the same way every other modifier's
    /// `$` does. It is a row key, not a glyph, so it belongs to
    /// `referencedKeys` and `symbolKeys` and to neither `iconSymbols` (which
    /// `SurfaceLayoutCheck` resolves against the OS) nor `fileKeys` (which it
    /// checks for a leading "/").
    func testABoundIconIsAKeyRatherThanAGlyph() throws {
        let json = #"""
        {"node":"list","empty":"x","row":{"node":"card","title":"$n","icon":"symbol:$glyph"}}
        """#
        let layout = try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(json.utf8))
        XCTAssertEqual(
            layout,
            .list(row: .card(.init(title: .key("n"), icon: .symbolKey(key: "glyph"))),
                  empty: "x")
        )
        XCTAssertEqual(layout.referencedKeys, ["n", "glyph"])
        XCTAssertEqual(layout.symbolKeys, ["glyph"])
        XCTAssertEqual(layout.iconSymbols, [])
        XCTAssertEqual(layout.fileKeys, [])

        let round = try JSONDecoder().decode(
            ToolAgentLayoutV1.self, from: JSONEncoder().encode(layout)
        )
        XCTAssertEqual(round, layout)
    }

    /// Neither decodes to anything that draws: `"symbol:$"` names no key and
    /// `"symbol:"` names no glyph. The sidecar's schema refuses both too —
    /// the two validators disagreeing is what sends a candidate to the host
    /// with no repair diagnostic attached.
    func testAnIconThatNamesNeitherKeyNorGlyphIsRefused() {
        for icon in ["symbol:$", "symbol:"] {
            let json = #"{"node":"card","title":"$n","icon":"\#(icon)"}"#
            XCTAssertThrowsError(
                try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(json.utf8)),
                icon
            )
        }
    }

    /// The readings a stats panel is made of: extra lines, a bar and a graph.
    /// `details` holds ordinary bindings so a line can be fixed text, while
    /// `meter` and `chart` take a key and nothing else — a fixed bar would be
    /// a picture of data that isn't there.
    func testACardCarriesDetailsAMeterAndAChart() throws {
        let json = #"""
        {"node":"list","empty":"x","row":{"node":"card","title":"$name",
         "details":["$system","$user","Idle"],"meter":"$load","chart":"$history"}}
        """#
        let layout = try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(json.utf8))
        guard case let .list(row, _) = layout, case let .card(card) = row else {
            return XCTFail("expected a list of cards")
        }
        XCTAssertEqual(card.details, [.key("system"), .key("user"), .literal("Idle")])
        XCTAssertEqual(card.meter, "load")
        XCTAssertEqual(card.chart, "history")
        XCTAssertEqual(layout.referencedKeys, ["name", "system", "user", "load", "history"])
        XCTAssertEqual(layout.meterKeys, ["load"])
        XCTAssertEqual(layout.chartKeys, ["history"])
        // Neither is a file, so neither may be dragged into the check that
        // demands a leading "/".
        XCTAssertEqual(layout.fileKeys, [])

        let round = try JSONDecoder().decode(
            ToolAgentLayoutV1.self, from: JSONEncoder().encode(layout)
        )
        XCTAssertEqual(round, layout)
    }

    /// A card with none of the three re-encodes without an empty `details`
    /// array — the decoder's own strict key set would otherwise have to accept
    /// a key that means nothing, and a round trip must produce the document it
    /// started from.
    func testACardWithoutDetailsEncodesNoDetailsKey() throws {
        let layout = ToolAgentLayoutV1.card(.init(title: .key("name")))
        let json = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
        XCTAssertFalse(json.contains("details"))
    }

    func testMoreDetailLinesThanACardHoldsIsRejected() {
        let lines = (0...ToolAgentLayoutCardV1.maximumDetails)
            .map { "\"$line\($0)\"" }
            .joined(separator: ",")
        let json = #"{"node":"card","title":"$n","details":[\#(lines)]}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(json.utf8))
        ) {
            XCTAssertEqual($0 as? ToolAgentFailureCodeV1, .invalidProtocol)
        }
    }

    func testAMeterOrChartWithoutAKeyIsRejected() {
        for json in [
            #"{"node":"card","title":"$n","meter":"0.5"}"#,
            #"{"node":"card","title":"$n","chart":"1,2,3"}"#,
            #"{"node":"card","title":"$n","meter":"$"}"#,
        ] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(json.utf8)), json
            ) {
                XCTAssertEqual($0 as? ToolAgentFailureCodeV1, .invalidProtocol, json)
            }
        }
    }

    /// A grid cell's height is its own column's width, so these three have
    /// nowhere to go in one. Reported by name so the diagnostic can say which.
    func testRowOnlyFieldsAreVisibleInsideAGrid() throws {
        let json = #"""
        {"node":"grid","minimumWidth":120,"empty":"x",
         "cell":{"node":"card","title":"$name","details":["$a"],"meter":"$load"}}
        """#
        let layout = try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(json.utf8))
        XCTAssertEqual(layout.rowOnlyFieldsInsideAGrid, ["details", "meter"])
    }

    func testAListOfTheSameCardsCarriesNoGridComplaint() throws {
        let json = #"""
        {"node":"list","empty":"x",
         "row":{"node":"card","title":"$name","details":["$a"],"meter":"$load"}}
        """#
        let layout = try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(json.utf8))
        XCTAssertEqual(layout.rowOnlyFieldsInsideAGrid, [])
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
        ) {
            XCTAssertEqual($0 as? ToolAgentFailureCodeV1, .invalidProtocol)
        }
    }

    func testAnUnknownNodeIsRejected() {
        let json = #"{"node":"webview","url":"https://example.com"}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(json.utf8))
        ) {
            XCTAssertEqual($0 as? ToolAgentFailureCodeV1, .invalidProtocol)
        }
    }

    func testAnUnknownModifierPrefixIsRejected() {
        let json = #"{"node":"card","title":"$n","drag":"folder:$path"}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(json.utf8))
        ) {
            XCTAssertEqual($0 as? ToolAgentFailureCodeV1, .invalidProtocol)
        }
    }

    /// A modifier that acts on a file needs a key to read the path out of, so a
    /// literal there is a candidate that would draw a card nothing can drag.
    func testAFileModifierWithoutAKeyIsRejected() {
        let json = #"{"node":"card","title":"$n","drag":"file:Downloads"}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(json.utf8))
        ) {
            XCTAssertEqual($0 as? ToolAgentFailureCodeV1, .invalidProtocol)
        }
    }

    func testNestingDeeperThanThreeIsRejected() {
        // Non-blank `empty` copy throughout, so this fails for nesting depth
        // and not for the unrelated blank-string rule below.
        let deep = #"{"node":"grid","minimumWidth":96,"empty":"x","cell":"#
            + #"{"node":"list","empty":"x","row":"#
            + #"{"node":"list","empty":"x","row":{"node":"text","value":"x"}}}}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(deep.utf8))
        ) {
            XCTAssertEqual($0 as? ToolAgentFailureCodeV1, .invalidProtocol)
        }
    }

    /// `minimumWidth` outside `48...400` is a stated limit; without a test for
    /// it, the bound could quietly disappear during a later refactor.
    func testMinimumWidthOutsideBoundsIsRejected() {
        let json = #"{"node":"grid","minimumWidth":16,"empty":"","cell":{"node":"text","value":"x"}}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(json.utf8))
        ) {
            XCTAssertEqual($0 as? ToolAgentFailureCodeV1, .invalidProtocol)
        }
    }

    /// Same reasoning for the 120-byte cap on `empty` copy.
    func testEmptyOverTheByteLimitIsRejected() {
        let tooLong = String(repeating: "x", count: ToolAgentLayoutV1.maximumEmptyBytes + 1)
        let json = #"{"node":"list","empty":""# + tooLong + #"","row":{"node":"text","value":"x"}}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(json.utf8))
        ) {
            XCTAssertEqual($0 as? ToolAgentFailureCodeV1, .invalidProtocol)
        }
    }

    /// The other half of M14: `"$"` alone binds nothing, on either side of
    /// the host/sidecar boundary. `protocol.ts` gained the matching
    /// refinement in the same pass — this pins the Swift half so the two
    /// can't drift back apart.
    func testABareDollarTitleIsRejected() {
        let json = #"{"node":"card","title":"$"}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(json.utf8))
        ) {
            XCTAssertEqual($0 as? ToolAgentFailureCodeV1, .invalidProtocol)
        }
    }

    /// A blank `empty` copy puts a bare panel on the user's screen edge with
    /// nothing explaining why it's there, so it is rejected even though it
    /// is well inside the byte limit. Both repeaters share the same guard.
    func testBlankEmptyStringIsRejected() {
        let list = #"{"node":"list","empty":"","row":{"node":"text","value":"x"}}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(list.utf8))
        ) {
            XCTAssertEqual($0 as? ToolAgentFailureCodeV1, .invalidProtocol)
        }
        let grid = #"{"node":"grid","minimumWidth":96,"empty":"","cell":{"node":"text","value":"x"}}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(ToolAgentLayoutV1.self, from: Data(grid.utf8))
        ) {
            XCTAssertEqual($0 as? ToolAgentFailureCodeV1, .invalidProtocol)
        }
    }
}
