import AppKit
import XCTest
@testable import Gizmate

final class GlobalShortcutsTests: XCTestCase {
    // Every combo action defaults to ⌃⌥ + its mnemonic letter.
    func testComboDefaultsUseControlOptionBase() {
        let expected: [GlobalShortcutAction: String] = [
            .explainSelection: "T",
            .replyToSelection: "Y",
            .translateSelection: "R",
            .toggleWritingLanguage: "G",
            .screenshotArea: "S",
            .liveTranslation: "L",
            .toggleInvisibility: "I",
            .dictate: "D",
            .saveNote: "N",
        ]
        for (action, letter) in expected {
            let shortcut = action.defaultShortcut
            XCTAssertEqual(shortcut.kind, .combo, "\(action) should be a combo")
            XCTAssertEqual(shortcut.modifiers, [.control, .option], "\(action) should use ⌃⌥")
            XCTAssertEqual(shortcut.keyDisplay, letter, "\(action) wrong mnemonic letter")
        }
    }

    func testAskGizmateKeepsDoubleTapControl() {
        let shortcut = GlobalShortcutAction.askGizmate.defaultShortcut
        XCTAssertEqual(shortcut.kind, .doubleTap)
        XCTAssertEqual(shortcut.modifiers, [.control])
    }

    func testAskGizmateAliasIsControlOptionA() {
        let alias = GlobalShortcutAction.askGizmateAlias
        XCTAssertEqual(alias.modifiers, [.control, .option])
        XCTAssertEqual(alias.keyDisplay, "A")
        XCTAssertEqual(alias.displayString, "⌃⌥A")
    }

    // No two triggers collide: every combo default plus the alias is distinct.
    func testNoDefaultShortcutCollisions() {
        var combos = GlobalShortcutAction.allCases
            .map(\.defaultShortcut)
            .filter { $0.kind == .combo }
        combos.append(GlobalShortcutAction.askGizmateAlias)
        for i in combos.indices {
            for j in combos.indices where j > i {
                XCTAssertNotEqual(combos[i], combos[j], "default shortcut collision")
            }
        }
    }

    // ⌃⇧Tab (and any ⌃⇧+key where Shift is released while Control is held)
    // must NOT fire the double-tap-⌃ detector. The modifier set walks
    // {}→{⌃}→{⌃⇧}→{⌃}→{} — the {⌃⇧}→{⌃} step used to look like a fresh
    // Control press and misfire Ask Gizmate.
    func testControlShiftTabDoesNotTriggerDoubleTap() {
        var state = DoubleTapState()
        let t0 = Date()
        let steps: [(NSEvent.ModifierFlags, TimeInterval)] = [
            ([.control], 0.00),          // ⌃ down
            ([.control, .shift], 0.02),  // + ⇧
            ([.control], 0.05),          // ⇧ up, ⌃ still held  <- phantom "down"
            ([], 0.08),                  // ⌃ up
        ]
        for (mods, dt) in steps {
            let fired = state.step(
                supportedActive: mods, modifier: [.control],
                now: t0.addingTimeInterval(dt), interval: 0.30
            )
            XCTAssertFalse(fired, "⌃⇧Tab must never fire double-tap ⌃")
        }
    }

    // Double-tapping the COMBO ⌃⇧Tab (press ⌃⇧Tab, release, repeat, fast) must
    // not fire: the Shift appearing each round cancels the pending ⌃ tap.
    func testDoubleTapControlShiftTabDoesNotFire() {
        var state = DoubleTapState()
        let t0 = Date()
        // Two full ⌃⇧Tab gestures within the window; Shift is always present.
        let seq: [(NSEvent.ModifierFlags, TimeInterval)] = [
            ([.control], 0.00), ([.control, .shift], 0.02), ([.control], 0.05), ([], 0.07),
            ([.control], 0.12), ([.control, .shift], 0.14), ([.control], 0.17), ([], 0.19),
        ]
        for (mods, dt) in seq {
            XCTAssertFalse(
                state.step(supportedActive: mods, modifier: [.control], now: t0.addingTimeInterval(dt), interval: 0.30),
                "double ⌃⇧Tab must never fire"
            )
        }
    }

    // Double ⌃Tab (no Shift) is caught by the non-modifier key press cancelling
    // the pending tap — Tab is a keyDown, not a modifier.
    func testDoubleTapControlTabDoesNotFire() {
        var state = DoubleTapState()
        let t0 = Date()
        // ⌃ down, Tab pressed, release; then again within the window.
        XCTAssertFalse(state.step(supportedActive: [.control], modifier: [.control], now: t0, interval: 0.30))
        state.noteOtherKeyPressed() // Tab
        XCTAssertFalse(state.step(supportedActive: [], modifier: [.control], now: t0.addingTimeInterval(0.05), interval: 0.30))
        XCTAssertFalse(state.step(supportedActive: [.control], modifier: [.control], now: t0.addingTimeInterval(0.10), interval: 0.30),
                       "second ⌃ after a Tab keypress must not fire")
    }

    // A genuine double-tap ⌃ (down, up, down within the interval) still fires.
    func testGenuineDoubleTapControlFires() {
        var state = DoubleTapState()
        let t0 = Date()
        XCTAssertFalse(state.step(supportedActive: [.control], modifier: [.control], now: t0, interval: 0.30))
        XCTAssertFalse(state.step(supportedActive: [], modifier: [.control], now: t0.addingTimeInterval(0.05), interval: 0.30))
        XCTAssertTrue(state.step(supportedActive: [.control], modifier: [.control], now: t0.addingTimeInterval(0.10), interval: 0.30),
                      "clean second ⌃ within interval should fire")
    }

    // Two taps too far apart are not a double-tap.
    func testDoubleTapControlRespectsInterval() {
        var state = DoubleTapState()
        let t0 = Date()
        XCTAssertFalse(state.step(supportedActive: [.control], modifier: [.control], now: t0, interval: 0.30))
        XCTAssertFalse(state.step(supportedActive: [], modifier: [.control], now: t0.addingTimeInterval(0.05), interval: 0.30))
        XCTAssertFalse(state.step(supportedActive: [.control], modifier: [.control], now: t0.addingTimeInterval(0.40), interval: 0.30),
                       "second ⌃ after the window should not fire")
    }

    // Quick menu defaults to the middle mouse button ("Mouse 3") and the
    // mouse-button kind round-trips through the store's JSON encoding.
    func testQuickMenuDefaultsToMouse3AndRoundTrips() {
        let shortcut = GlobalShortcutAction.quickMenu.defaultShortcut
        XCTAssertEqual(shortcut.kind, .mouseButton)
        XCTAssertEqual(shortcut.keyCode, 2)
        XCTAssertEqual(shortcut.displayString, "Mouse 3")
        XCTAssertTrue(shortcut.isValid)

        let data = try! JSONEncoder().encode(shortcut)
        let decoded = try! JSONDecoder().decode(GlobalShortcut.self, from: data)
        XCTAssertEqual(decoded, shortcut)
    }

    // A trackpad tap needs three to five fingers: one is a click, two is a
    // secondary click, and neither can be taken away from the system.
    func testTrackpadTapValidityAndRoundTrip() {
        XCTAssertFalse(GlobalShortcut(trackpadTap: 1).isValid)
        XCTAssertFalse(GlobalShortcut(trackpadTap: 2).isValid)
        XCTAssertTrue(GlobalShortcut(trackpadTap: 3).isValid)
        XCTAssertTrue(GlobalShortcut(trackpadTap: 5).isValid)
        XCTAssertFalse(GlobalShortcut(trackpadTap: 6).isValid)

        let shortcut = GlobalShortcut(trackpadTap: 3)
        XCTAssertEqual(shortcut.displayString, "3-finger tap")
        let data = try! JSONEncoder().encode(shortcut)
        let decoded = try! JSONDecoder().decode(GlobalShortcut.self, from: data)
        XCTAssertEqual(decoded, shortcut)
        XCTAssertNotEqual(decoded, GlobalShortcut(trackpadTap: 4))
        XCTAssertNotEqual(decoded, GlobalShortcut(mouseButton: 3), "same keyCode, different kind")
    }

    // Three fingers land, none travels, all leave quickly: one 3-finger tap,
    // even when they lift one at a time. A drag or a slow hold is not a tap.
    func testTrackpadTapStateRecognisesCleanTapOnly() {
        func touch(_ id: Int, _ x: CGFloat, down: Bool = true) -> TrackpadTapState.Touch {
            TrackpadTapState.Touch(id: AnyHashable(id), position: CGPoint(x: x, y: 0.5), down: down)
        }
        let t0 = Date(timeIntervalSince1970: 1_000)
        var state = TrackpadTapState()

        XCTAssertNil(state.step(touches: [touch(1, 0.3)], now: t0))
        XCTAssertNil(state.step(touches: [touch(1, 0.3), touch(2, 0.5), touch(3, 0.7)], now: t0.addingTimeInterval(0.02)))
        XCTAssertNil(state.step(touches: [touch(1, 0.3, down: false), touch(2, 0.5), touch(3, 0.7)], now: t0.addingTimeInterval(0.10)))
        XCTAssertEqual(state.step(touches: [touch(2, 0.5, down: false), touch(3, 0.7, down: false)], now: t0.addingTimeInterval(0.15)), 3)

        // Reset after firing: a lone finger afterwards reads as 1, not 3.
        XCTAssertNil(state.step(touches: [touch(4, 0.3)], now: t0.addingTimeInterval(1)))
        XCTAssertEqual(state.step(touches: [touch(4, 0.3, down: false)], now: t0.addingTimeInterval(1.05)), 1)

        // Travel spoils it.
        XCTAssertNil(state.step(touches: [touch(1, 0.3), touch(2, 0.5), touch(3, 0.7)], now: t0.addingTimeInterval(2)))
        XCTAssertNil(state.step(touches: [touch(1, 0.4), touch(2, 0.6), touch(3, 0.8)], now: t0.addingTimeInterval(2.05)))
        XCTAssertNil(state.step(touches: [touch(1, 0.4, down: false), touch(2, 0.6, down: false), touch(3, 0.8, down: false)], now: t0.addingTimeInterval(2.10)))

        // Holding too long spoils it.
        XCTAssertNil(state.step(touches: [touch(1, 0.3), touch(2, 0.5), touch(3, 0.7)], now: t0.addingTimeInterval(3)))
        XCTAssertNil(state.step(touches: [touch(1, 0.3, down: false), touch(2, 0.5, down: false), touch(3, 0.7, down: false)], now: t0.addingTimeInterval(3.5)))
    }

    // Left/right clicks must never validate as global shortcuts.
    func testPrimaryMouseButtonsAreInvalidShortcuts() {
        XCTAssertFalse(GlobalShortcut(mouseButton: 0).isValid)
        XCTAssertFalse(GlobalShortcut(mouseButton: 1).isValid)
        XCTAssertTrue(GlobalShortcut(mouseButton: 3).isValid)
    }

    // Groups partition the action set: each action lands in exactly one group,
    // and the groups together cover every action.
    func testGroupsPartitionAllActions() {
        let grouped = ShortcutGroup.allCases.flatMap { group in
            GlobalShortcutAction.allCases.filter { $0.group == group }
        }
        XCTAssertEqual(grouped.count, GlobalShortcutAction.allCases.count)
        XCTAssertEqual(Set(grouped), Set(GlobalShortcutAction.allCases))
    }
}
