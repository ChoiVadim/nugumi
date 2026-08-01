import XCTest
@testable import Gizmate

/// The store's whole job is "sparse overrides on top of shipped values", so what
/// is worth pinning down is that an unset field falls through to what shipped and
/// that a reset really removes rather than freezes today's default.
final class BuiltInOverridesTests: XCTestCase {

    @MainActor
    private func store() -> (BuiltInOverridesStore, () -> Void) {
        let suiteName = "BuiltInOverridesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (BuiltInOverridesStore(defaults: defaults), {
            defaults.removePersistentDomain(forName: suiteName)
        })
    }

    @MainActor
    func testUntouchedActionReturnsShippedValues() {
        let (store, cleanup) = store()
        defer { cleanup() }

        XCTAssertEqual(store.name(for: .dictate), RingActionID.dictate.label)
        XCTAssertEqual(store.icon(for: .explain), RingActionID.explain.icon)
        XCTAssertNil(store.prompt(for: .explain))
        XCTAssertTrue(store.isEnabled(.dictate))
    }

    @MainActor
    func testSavedOverrideWinsOverShippedValue() {
        let (store, cleanup) = store()
        defer { cleanup() }

        store.save(
            BuiltInOverride(name: "Speak", symbol: "waveform.circle", isEnabled: false),
            for: .dictate
        )

        XCTAssertEqual(store.name(for: .dictate), "Speak")
        XCTAssertEqual(store.icon(for: .dictate), .symbol("waveform.circle"))
        XCTAssertFalse(store.isEnabled(.dictate))
    }

    /// An unset field must fall through even when its neighbours are set —
    /// this is what makes a partial edit partial.
    @MainActor
    func testUnsetFieldsStillFallThrough() {
        let (store, cleanup) = store()
        defer { cleanup() }

        store.save(BuiltInOverride(name: "Speak"), for: .dictate)

        XCTAssertEqual(store.name(for: .dictate), "Speak")
        XCTAssertEqual(store.icon(for: .dictate), RingActionID.dictate.icon)
        XCTAssertTrue(store.isEnabled(.dictate))
    }

    @MainActor
    func testOverridesSurviveAReload() {
        let suiteName = "BuiltInOverridesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        BuiltInOverridesStore(defaults: defaults)
            .save(BuiltInOverride(name: "Speak"), for: .dictate)

        XCTAssertEqual(BuiltInOverridesStore(defaults: defaults).name(for: .dictate), "Speak")
    }

    @MainActor
    func testResetRestoresShippedValues() {
        let (store, cleanup) = store()
        defer { cleanup() }

        store.save(BuiltInOverride(name: "Speak", isEnabled: false), for: .dictate)
        store.resetToDefault(.dictate)

        XCTAssertEqual(store.name(for: .dictate), RingActionID.dictate.label)
        XCTAssertTrue(store.isEnabled(.dictate))
        XCTAssertNil(store.overrides[.dictate])
    }

    /// Summarize's hover label is deliberately empty (its live button wears the
    /// source app's icon), so the settings-facing name has to come from
    /// `displayName`, not `label`.
    @MainActor
    func testSummarizeFallsBackToDisplayName() {
        let (store, cleanup) = store()
        defer { cleanup() }

        XCTAssertEqual(store.displayName(for: .summarize), "Summarize")
    }
}
