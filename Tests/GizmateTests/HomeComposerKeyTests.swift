import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Gizmate

/// The composer's key monitor sees every keystroke the window gets while the
/// composer has focus, so what it declines to touch matters as much as what it
/// claims. These pin both halves.
final class HomeComposerKeyTests: XCTestCase {
    func testShiftReturnIsALineBreak() {
        XCTAssertEqual(HomeComposerKey.of(modifiers: .shift, keyCode: kVK_Return), .newline)
    }

    /// The Return on a full keyboard's number pad is a different key code, and
    /// somebody using it means the same thing by it.
    func testShiftKeypadEnterIsALineBreak() {
        XCTAssertEqual(
            HomeComposerKey.of(modifiers: .shift, keyCode: kVK_ANSI_KeypadEnter), .newline
        )
    }

    func testCommandVTakesAPicture() {
        XCTAssertEqual(HomeComposerKey.of(modifiers: .command, keyCode: kVK_ANSI_V), .pastePicture)
    }

    /// Return alone is send, and stays SwiftUI's `onSubmit` — intercepting it
    /// here would be two different pieces of code deciding what send means.
    func testBareReturnIsLeftAlone() {
        XCTAssertEqual(HomeComposerKey.of(modifiers: [], keyCode: kVK_Return), .passThrough)
    }

    /// ⌥Return is SwiftUI's own line break for a vertical `TextField`. ⇧Return
    /// is the second way in, not a replacement, so this key must reach the
    /// field editor untouched and produce exactly the same edit.
    func testOptionReturnIsLeftToSwiftUI() {
        XCTAssertEqual(HomeComposerKey.of(modifiers: .option, keyCode: kVK_Return), .passThrough)
    }

    /// The modifier match is exact rather than a `.contains`, so a chord that
    /// merely includes shift or command keeps whatever it means elsewhere.
    /// This is the defect a `.contains(.shift)` would ship: ⇧⌘Return silently
    /// becoming a line break, and ⇧⌘V silently eating a paste.
    func testAChordThatMerelyIncludesTheModifierIsLeftAlone() {
        XCTAssertEqual(
            HomeComposerKey.of(modifiers: [.shift, .command], keyCode: kVK_Return), .passThrough
        )
        XCTAssertEqual(
            HomeComposerKey.of(modifiers: [.shift, .command], keyCode: kVK_ANSI_V), .passThrough
        )
    }

    /// `capsLock`, `numericPad` and `function` all arrive in `modifierFlags`
    /// and none of them is a modifier anyone pressed on purpose — they are
    /// also all inside `deviceIndependentFlagsMask`, which is why comparing
    /// against that mask is not enough. Caps lock left on used to stop ⌘V
    /// taking a picture, silently, for as long as it stayed on.
    func testFlagsNobodyPressedDoNotChangeWhatAKeyMeans() {
        XCTAssertEqual(
            HomeComposerKey.of(modifiers: [.shift, .capsLock], keyCode: kVK_Return), .newline
        )
        XCTAssertEqual(
            HomeComposerKey.of(modifiers: [.command, .capsLock], keyCode: kVK_ANSI_V),
            .pastePicture
        )
        XCTAssertEqual(
            HomeComposerKey.of(
                modifiers: [.shift, .numericPad, .function], keyCode: kVK_ANSI_KeypadEnter
            ),
            .newline
        )
    }
}
