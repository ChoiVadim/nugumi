import XCTest
@testable import Nugumi

final class ModelReadyTransitionTests: XCTestCase {
    /// Regression: switching to a not-yet-installed local model (e.g. Gemma 4)
    /// used to snap back to gpt-oss:20b. Every `refresh()` cycles installed
    /// models `.ok → .checking → .ok`; recording the `.checking` blip made the
    /// trailing `.ok` look like a fresh install, re-firing the engine preset,
    /// which then healed the user's unusable pick back to the default. The blip
    /// must not be mistaken for a fresh install.
    func testCheckingBlipIsNotMistakenForFreshInstall() {
        var observed: [String: BootstrapStepStatus] = ["gpt-oss:20b": .ok]

        // refresh stamps .checking on every model
        XCTAssertFalse(ModelReadyTransition.anyBecameReady(
            previous: observed, current: ["gpt-oss:20b": .checking]))
        observed = ModelReadyTransition.merge(into: observed, current: ["gpt-oss:20b": .checking])
        XCTAssertEqual(observed["gpt-oss:20b"], .ok,
                       "the .checking blip must not erase the prior terminal memory")

        // refresh resolves the installed model back to .ok — not a new install
        XCTAssertFalse(ModelReadyTransition.anyBecameReady(
            previous: observed, current: ["gpt-oss:20b": .ok]),
            "re-confirming an already-installed model is not a fresh install")
    }

    /// A real install (not-installed → installed) must still re-apply the preset.
    func testGenuineInstallIsDetected() {
        let observed: [String: BootstrapStepStatus] = ["gemma4": .needsAction("not installed")]
        XCTAssertTrue(ModelReadyTransition.anyBecameReady(
            previous: observed, current: ["gemma4": .ok]),
            "needsAction → ok is a real install and should re-apply the preset")
    }

    /// First time an already-installed model is discovered counts as ready.
    func testFirstSightOfInstalledModelCountsAsReady() {
        XCTAssertTrue(ModelReadyTransition.anyBecameReady(
            previous: [:], current: ["gpt-oss:20b": .ok]))
    }

    /// `.working` (download progress) is preserved, so the translator-ready
    /// notification can still observe the `.working → .ok` transition.
    func testWorkingStateIsPreserved() {
        let observed = ModelReadyTransition.merge(
            into: [:], current: ["gemma4": .working("Downloading… 40%")])
        XCTAssertEqual(observed["gemma4"], .working("Downloading… 40%"))
    }
}
