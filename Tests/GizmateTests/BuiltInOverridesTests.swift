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
        XCTAssertTrue(store.voiceOffBuiltIns().isEmpty)
        XCTAssertTrue(store.notesOffBuiltIns().isEmpty)
    }

    @MainActor
    func testSavedOverrideWinsOverShippedValue() {
        let (store, cleanup) = store()
        defer { cleanup() }

        store.save(
            BuiltInOverride(name: "Speak", symbol: "waveform.circle", usesNotes: false),
            for: .dictate
        )

        XCTAssertEqual(store.name(for: .dictate), "Speak")
        XCTAssertEqual(store.icon(for: .dictate), .symbol("waveform.circle"))
        XCTAssertEqual(store.notesOffBuiltIns(), [.dictate])
        XCTAssertTrue(store.voiceOffBuiltIns().isEmpty)
    }

    /// Blobs written before the two context toggles existed carry `isEnabled`
    /// and neither new key. They must decode as "both on" — a throw here would
    /// take the user's edited prompts and names down with them.
    @MainActor
    func testLegacyBlobDecodesWithBothContextSourcesOn() throws {
        let suiteName = "BuiltInOverridesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacy = #"{"dictate":{"name":"Speak","isEnabled":false}}"#
        defaults.set(Data(legacy.utf8), forKey: "builtInOverrides.v1")

        let store = BuiltInOverridesStore(defaults: defaults)
        XCTAssertEqual(store.name(for: .dictate), "Speak")
        XCTAssertTrue(store.voiceOffBuiltIns().isEmpty)
        XCTAssertTrue(store.notesOffBuiltIns().isEmpty)
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
        XCTAssertTrue(store.voiceOffBuiltIns().isEmpty)
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

        store.save(BuiltInOverride(name: "Speak", usesVoice: false), for: .dictate)
        store.resetToDefault(.dictate)

        XCTAssertEqual(store.name(for: .dictate), RingActionID.dictate.label)
        XCTAssertTrue(store.voiceOffBuiltIns().isEmpty)
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

    // MARK: - Ring integration

    private var allHandlers: RingActionHandlers {
        RingActionHandlers(
            explain: {}, rewrite: {}, reply: {}, ask: {},
            capture: {}, dictate: {}, live: {}
        )
    }

    @MainActor
    func testRenamedBuiltInShowsItsNewLabel() {
        let slots = RingBuilder.slots(
            configuration: RingConfiguration(
                layout: RingLayout(slots: [.builtIn(.dictate)]),
                tools: [],
                overrides: [.dictate: BuiltInOverride(name: "Speak")]
            ),
            handlers: allHandlers,
            dismiss: {}
        )

        XCTAssertEqual(slots[0]?.label, "Speak")
    }

    /// An untouched ring must build exactly as it did before overrides existed.
    @MainActor
    func testRingWithNoOverridesIsUnchanged() {
        let layout = RingLayout(slots: [.builtIn(.explain), .builtIn(.dictate)])
        let slots = RingBuilder.slots(
            configuration: RingConfiguration(layout: layout, tools: []),
            handlers: allHandlers,
            dismiss: {}
        )

        XCTAssertEqual(slots[0]?.label, RingActionID.explain.label)
        XCTAssertEqual(slots[1]?.label, RingActionID.dictate.label)
    }
}
