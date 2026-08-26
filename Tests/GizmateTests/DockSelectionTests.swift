import AppKit
import XCTest

@testable import Gizmate

/// The half of `DockSelection` that can be wrong: turning a text view's UTF-16
/// selected range into the string the ring is armed with.
@MainActor
final class DockSelectionTests: XCTestCase {
    private func textView(_ string: String, selecting range: NSRange) -> NSTextView {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.string = string
        view.setSelectedRange(range)
        return view
    }

    func testReadsTheSelectedSubstring() {
        let view = textView("hello world", selecting: NSRange(location: 6, length: 5))
        XCTAssertEqual(DockSelection.selection(in: view)?.text, "world")
    }

    /// Emoji and Korean are two UTF-16 units and one respectively — the range a
    /// text view hands back counts the former, so a `String` index would slice
    /// in the wrong place.
    func testReadsPastAnEmoji() {
        let view = textView("🌍 안녕", selecting: NSRange(location: 3, length: 2))
        XCTAssertEqual(DockSelection.selection(in: view)?.text, "안녕")
    }

    func testEmptySelectionIsNothing() {
        let view = textView("hello", selecting: NSRange(location: 2, length: 0))
        XCTAssertNil(DockSelection.selection(in: view))
    }

    /// A range left over from before the text shrank must return nil, not trap.
    func testRangePastTheEndIsNothing() {
        let view = textView("hello", selecting: NSRange(location: 0, length: 5))
        view.textStorage?.setAttributedString(NSAttributedString(string: "hi"))
        XCTAssertNil(DockSelection.selection(in: view))
    }
}
