import AppKit
import XCTest

@testable import Gizmate

/// The panel has no intrinsic layout: every box is sized from a measurement
/// taken up front. Measure at a different width than the text container is
/// actually given and the box is short by however many lines the difference
/// costs — and `layoutScrollableTextView`, reading the same measurement, then
/// concludes the text fits and switches the scroller off over content it has
/// just clipped.
final class TranslationPanelMeasurementTests: XCTestCase {
    private let resultFont = NSFont.systemFont(ofSize: 18, weight: .semibold)

    private func laidOutHeight(_ markdown: String, width: CGFloat) -> CGFloat {
        let attributed = TranslationContentView.renderedMarkdownText(
            markdown, font: resultFont, color: .white
        )
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        return ceil(layoutManager.usedRect(for: container).height)
    }

    func testTheBoxGrowsByTheLinesTheContainerActuallyWraps() {
        let box = TranslationContentView.contentWidth
        let container = TranslationContentView.textContainerWidth(inBox: box)
        XCTAssertLessThan(container, box, "no scroller gutter left to measure wrong")

        // Two single paragraphs, both above the minimum box height so neither
        // is clamped. `wrapping` is the sentence from the report: it fits two
        // lines at the box's full width and needs three in the container, so
        // measuring at the wrong one costs it a whole line. `plain` wraps the
        // same at either width, so the delta between them is exactly the text.
        let plain = "Create a separate server for Mono, with a model designed to give more "
            + "consistent results."
        let wrapping = "For the Mono server: model 7, product 3. For the existing server: "
            + "model 3, product 7."
        XCTAssertGreaterThan(
            laidOutHeight(wrapping, width: container),
            laidOutHeight(wrapping, width: box),
            "fixture does not wrap differently across the gutter, so this test proves nothing"
        )
        XCTAssertEqual(
            laidOutHeight(plain, width: container),
            laidOutHeight(plain, width: box),
            "the baseline has to be gutter-insensitive or it cannot isolate the delta"
        )

        let panelDelta = TranslationContentView.preferredHeight(sourceText: "hi", resultText: wrapping)
            - TranslationContentView.preferredHeight(sourceText: "hi", resultText: plain)
        let realDelta = laidOutHeight(wrapping, width: container)
            - laidOutHeight(plain, width: container)
        XCTAssertEqual(panelDelta, realDelta, accuracy: 1)
    }
}
