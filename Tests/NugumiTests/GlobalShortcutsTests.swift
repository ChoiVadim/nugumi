import AppKit
import XCTest
@testable import Nugumi

final class GlobalShortcutsTests: XCTestCase {
    // Every combo action defaults to ⌃⌥ + its mnemonic letter.
    func testComboDefaultsUseControlOptionBase() {
        let expected: [GlobalShortcutAction: String] = [
            .translateOrReply: "T",
            .translateSelection: "R",
            .toggleWritingLanguage: "G",
            .screenshotArea: "S",
            .liveTranslation: "L",
            .toggleInvisibility: "I",
        ]
        for (action, letter) in expected {
            let shortcut = action.defaultShortcut
            XCTAssertEqual(shortcut.kind, .combo, "\(action) should be a combo")
            XCTAssertEqual(shortcut.modifiers, [.control, .option], "\(action) should use ⌃⌥")
            XCTAssertEqual(shortcut.keyDisplay, letter, "\(action) wrong mnemonic letter")
        }
    }

    func testAskNugumiKeepsDoubleTapControl() {
        let shortcut = GlobalShortcutAction.askNugumi.defaultShortcut
        XCTAssertEqual(shortcut.kind, .doubleTap)
        XCTAssertEqual(shortcut.modifiers, [.control])
    }

    func testAskNugumiAliasIsControlOptionA() {
        let alias = GlobalShortcutAction.askNugumiAlias
        XCTAssertEqual(alias.modifiers, [.control, .option])
        XCTAssertEqual(alias.keyDisplay, "A")
        XCTAssertEqual(alias.displayString, "⌃⌥A")
    }

    // No two triggers collide: every combo default plus the alias is distinct.
    func testNoDefaultShortcutCollisions() {
        var combos = GlobalShortcutAction.allCases
            .map(\.defaultShortcut)
            .filter { $0.kind == .combo }
        combos.append(GlobalShortcutAction.askNugumiAlias)
        for i in combos.indices {
            for j in combos.indices where j > i {
                XCTAssertNotEqual(combos[i], combos[j], "default shortcut collision")
            }
        }
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
