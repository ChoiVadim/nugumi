import XCTest
import AppKit
@testable import Nugumi

final class ReviseFollowUpTests: XCTestCase {
    private let renderFont = NSFont.systemFont(ofSize: 16, weight: .semibold)

    func testMarkdownTableRendersWithoutRawPipes() {
        let md = "| Letter | Means |\n|--------|-------|\n| A | Atomicity |\n| C | Consistency |"
        let rendered = TranslationContentView.renderedMarkdownText(md, font: renderFont, color: .white).string

        // Pipes and the separator rule are consumed — not shown as literal text.
        XCTAssertFalse(rendered.contains("|"))
        XCTAssertFalse(rendered.contains("---"))
        // Cell contents survive.
        for cell in ["Letter", "Means", "Atomicity", "Consistency"] {
            XCTAssertTrue(rendered.contains(cell), "missing cell: \(cell)")
        }
    }

    func testMarkdownHeaderAndListMarkersAreConverted() {
        let header = TranslationContentView.renderedMarkdownText("# Title here", font: renderFont, color: .white).string
        XCTAssertFalse(header.contains("#"))
        XCTAssertTrue(header.contains("Title here"))

        let list = TranslationContentView.renderedMarkdownText("- first\n- second", font: renderFont, color: .white).string
        XCTAssertTrue(list.contains("•"))
        XCTAssertFalse(list.contains("- first"))
    }

    func testStreamingRenderDefersBlockFormatting() {
        // While streaming, block syntax (table pipes) is left raw — formatting it
        // mid-stream is what caused the reflow/twitch. The final render formats it.
        let md = "| A | B |\n|---|---|\n| 1 | 2 |"
        let streaming = TranslationContentView.renderedStreamingText(md, font: renderFont, color: .white).string
        XCTAssertTrue(streaming.contains("|"))

        let final = TranslationContentView.renderedMarkdownText(md, font: renderFont, color: .white).string
        XCTAssertFalse(final.contains("|"))
    }

    func testPlainTextRoundTripsUnchanged() {
        // Regression guard: ordinary translations (no markdown) come through intact.
        let plain = "Just a normal sentence."
        let rendered = TranslationContentView.renderedMarkdownText(plain, font: renderFont, color: .white).string
        XCTAssertEqual(rendered, plain)
    }

    func testComposeReviseInputLabelsSectionsInOrder() {
        let out = TranslationMode.composeReviseInput(
            source: "Consistency",
            previous: "It means the data stays correct.",
            instruction: "make it shorter"
        )

        XCTAssertTrue(out.contains("Original text:"))
        XCTAssertTrue(out.contains("Your previous response:"))
        XCTAssertTrue(out.contains("Revision request:"))
        XCTAssertTrue(out.contains("Consistency"))
        XCTAssertTrue(out.contains("It means the data stays correct."))
        XCTAssertTrue(out.contains("make it shorter"))

        // The model relies on the section order to know what to revise.
        let original = out.range(of: "Original text:")!.lowerBound
        let previous = out.range(of: "Your previous response:")!.lowerBound
        let request = out.range(of: "Revision request:")!.lowerBound
        XCTAssertTrue(original < previous && previous < request)
    }

    func testFollowUpFooterAddsExactlyItsHeight() {
        // Mid-range content so neither the min nor max clamp is hit and the
        // delta is purely the footer.
        let source = String(repeating: "alpha beta gamma delta ", count: 8)
        let result = String(repeating: "one two three four five six seven ", count: 10)

        let without = TranslationContentView.preferredHeight(sourceText: source, resultText: result, showsFollowUp: false)
        let with = TranslationContentView.preferredHeight(sourceText: source, resultText: result, showsFollowUp: true)

        XCTAssertGreaterThan(TranslationContentView.followUpFooterHeight, 0)
        XCTAssertEqual(with - without, TranslationContentView.followUpFooterHeight, accuracy: 0.5)
    }

    func testHidingSourceShrinksPanel() {
        let source = String(repeating: "alpha beta gamma delta ", count: 8)
        let result = String(repeating: "one two three four five six seven ", count: 10)

        let withSource = TranslationContentView.preferredHeight(sourceText: source, resultText: result, showsSource: true)
        let withoutSource = TranslationContentView.preferredHeight(sourceText: source, resultText: result, showsSource: false)

        XCTAssertLessThan(withoutSource, withSource)
    }
}
