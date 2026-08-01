import XCTest
@testable import Gizmate

/// Every built-in but Summarize owns exactly one shortcut, and no two actions
/// may ship the same default — a collision means one of them silently never
/// fires for anyone who never opens the settings.
final class BuiltInShortcutTests: XCTestCase {

    func testEveryBuiltInExceptSummarizeHasAShortcut() {
        for id in RingActionID.allCases where id != .summarize {
            XCTAssertNotNil(id.shortcutAction, "\(id) has no shortcut action")
        }
        XCTAssertNil(RingActionID.summarize.shortcutAction)
    }

    func testNoTwoBuiltInsShareAShortcutAction() {
        let actions = RingActionID.allCases.compactMap(\.shortcutAction)
        XCTAssertEqual(actions.count, Set(actions.map(\.rawValue)).count)
    }

    func testNoTwoActionsShipTheSameDefaultShortcut() {
        var seen: [GlobalShortcut] = []
        for action in GlobalShortcutAction.allCases {
            let shortcut = action.defaultShortcut
            XCTAssertFalse(seen.contains(shortcut), "\(action) ships a default already taken")
            seen.append(shortcut)
        }
        XCTAssertFalse(
            seen.contains(GlobalShortcutAction.askGizmateAlias),
            "a default collides with the reserved ⌃⌥A Ask alias"
        )
    }

    func testActionIDsAreUniqueAndClearOfTheAliasID() {
        let ids = GlobalShortcutAction.allCases.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertFalse(ids.contains(100), "id 100 is reserved for the Ask alias")
    }

    /// Every shipped default has to be a shortcut the registrar can actually
    /// install — an invalid one falls back silently and the key never works.
    func testEveryDefaultShortcutIsValid() {
        for action in GlobalShortcutAction.allCases {
            XCTAssertTrue(action.defaultShortcut.isValid, "\(action) ships an invalid default")
        }
    }

    // MARK: - Retiring the mode-following selection key

    private func scratchDefaults() -> (UserDefaults, () -> Void) {
        let suiteName = "BuiltInShortcutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func store(_ shortcut: GlobalShortcut, at key: String, in defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(shortcut), forKey: key)
    }

    private let custom = GlobalShortcut(
        keyCode: 11, modifiers: [.control, .command], keyEquivalent: "b", keyDisplay: "B"
    )

    /// A user who rebound ⌃⌥T keeps their key, pointed at Explain — which is
    /// what it already did for anyone on the default mode.
    func testRetiredBindingMovesToExplainOnTheDefaultMode() {
        let (defaults, cleanup) = scratchDefaults()
        defer { cleanup() }
        store(custom, at: "globalShortcut.translateOrReply", in: defaults)

        GlobalShortcutStore.migrateRetiredSelectionShortcut(defaults: defaults)

        XCTAssertEqual(GlobalShortcutStore.shortcut(for: .explainSelection, defaults: defaults), custom)
        XCTAssertNil(defaults.data(forKey: "globalShortcut.translateOrReply"))
    }

    /// Someone whose default mode was Reply had ⌃⌥T *replying*. Landing it on
    /// Explain would silently change what their key does.
    func testRetiredBindingFollowsTheReplyDefaultMode() {
        let (defaults, cleanup) = scratchDefaults()
        defer { cleanup() }
        store(custom, at: "globalShortcut.translateOrReply", in: defaults)
        defaults.set(FloatingButtonDefaultMode.smartReply.rawValue, forKey: "floatingButtonDefaultMode")

        GlobalShortcutStore.migrateRetiredSelectionShortcut(defaults: defaults)

        XCTAssertEqual(GlobalShortcutStore.shortcut(for: .replyToSelection, defaults: defaults), custom)
        XCTAssertEqual(
            GlobalShortcutStore.shortcut(for: .explainSelection, defaults: defaults),
            GlobalShortcutAction.explainSelection.defaultShortcut
        )
    }

    /// A fresh install has no legacy key and must come out on the shipped
    /// defaults, not on whatever the migration felt like writing.
    func testMigrationIsANoOpWithoutALegacyBinding() {
        let (defaults, cleanup) = scratchDefaults()
        defer { cleanup() }

        GlobalShortcutStore.migrateRetiredSelectionShortcut(defaults: defaults)

        XCTAssertNil(defaults.data(forKey: GlobalShortcutAction.explainSelection.defaultsKey))
        XCTAssertEqual(
            GlobalShortcutStore.shortcut(for: .explainSelection, defaults: defaults).keyDisplay,
            "T"
        )
    }

    /// Running twice must not resurrect anything, and must not overwrite a key
    /// the user set on Explain itself.
    func testMigrationNeverClobbersAnExistingBinding() {
        let (defaults, cleanup) = scratchDefaults()
        defer { cleanup() }
        let explicit = GlobalShortcut(
            keyCode: 35, modifiers: [.control, .option, .shift], keyEquivalent: "p", keyDisplay: "P"
        )
        store(custom, at: "globalShortcut.translateOrReply", in: defaults)
        store(explicit, at: GlobalShortcutAction.explainSelection.defaultsKey, in: defaults)

        GlobalShortcutStore.migrateRetiredSelectionShortcut(defaults: defaults)
        GlobalShortcutStore.migrateRetiredSelectionShortcut(defaults: defaults)

        XCTAssertEqual(GlobalShortcutStore.shortcut(for: .explainSelection, defaults: defaults), explicit)
    }

    /// Anything not owned by a built-in must stay in `.app`, which is the only
    /// group Settings → Shortcuts renders. Otherwise it is registered but
    /// unreachable from any screen.
    func testUnownedActionsAreReachableFromSettings() {
        let owned = Set(RingActionID.allCases.compactMap(\.shortcutAction).map(\.rawValue))
        for action in GlobalShortcutAction.allCases where !owned.contains(action.rawValue) {
            XCTAssertEqual(
                action.group, .app,
                "\(action) belongs to no built-in and is not in Settings either"
            )
        }
    }
}
