import XCTest

@testable import Gizmate

final class ToolIconsTests: XCTestCase {
    /// The picker pages through `matching("")`, so an empty query has to reach
    /// past the curated shelf — otherwise scrolling dead-ends at ~70 icons.
    func testEmptyQueryBrowsesWholeCatalogCuratedFirst() {
        let browse = ToolIcons.matching("")
        XCTAssertEqual(Array(browse.prefix(ToolIcons.curated.count)), ToolIcons.curated)
        XCTAssertEqual(Set(browse).count, browse.count, "no duplicates between curated and all")
        // Only meaningful when CoreGlyphs is readable; falls back to curated otherwise.
        if ToolIcons.all.count > ToolIcons.curated.count {
            XCTAssertGreaterThan(browse.count, ToolIcons.curated.count)
        }
    }

    func testQuerySearchesEveryTermAcrossDots() {
        XCTAssertTrue(ToolIcons.matching("down arrow").contains("arrow.down.circle"))
        XCTAssertTrue(ToolIcons.matching("xyzzy").isEmpty)
    }

    func testDisplayNameReadsAsWordsRatherThanAnIdentifier() {
        XCTAssertEqual(ToolIcons.displayName(for: "arrow.down.circle"), "Arrow down circle")
        XCTAssertEqual(ToolIcons.displayName(for: "sparkles"), "Sparkles")
        XCTAssertEqual(ToolIcons.displayName(for: "doc.on.doc"), "Doc on doc")
        XCTAssertEqual(ToolIcons.displayName(for: "circle.grid.2x2"), "Circle grid 2x2")
        XCTAssertEqual(
            ToolIcons.displayName(for: "bubble.left.and.bubble.right"),
            "Bubble left and bubble right"
        )
    }

    /// The picker searches all eight thousand symbols, so this runs on names
    /// nobody chose. It must never return an empty label or crash on a shape it
    /// did not expect.
    func testDisplayNameSurvivesEveryNameTheCatalogCanOffer() {
        XCTAssertEqual(ToolIcons.displayName(for: ""), "")
        XCTAssertEqual(ToolIcons.displayName(for: "."), ".")
        XCTAssertEqual(ToolIcons.displayName(for: "a"), "A")
        XCTAssertEqual(ToolIcons.displayName(for: "42.circle"), "42 circle")
        for name in ToolIcons.browsable {
            XCTAssertFalse(
                ToolIcons.displayName(for: name).isEmpty,
                "\(name) produced an empty label"
            )
        }
    }
}
