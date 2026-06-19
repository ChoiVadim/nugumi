import XCTest
@testable import Nugumi

@MainActor
final class OnboardingFlowTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private let autoShownKey = "mainWindowAutoShownV1"

    /// Snapshot the onboarding-related defaults so these tests don't leak state
    /// into the real app defaults (OnboardingModel reads UserDefaults.standard).
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for key in [OnboardingModel.featureTourCompletedKey, OnboardingModel.introPlayedKey, autoShownKey] {
            saved[key] = defaults.object(forKey: key)
        }
        // Tour already seen, intro already played: keeps the constructor on the
        // permissions page instead of routing to intro/feature.
        defaults.set(true, forKey: OnboardingModel.featureTourCompletedKey)
        defaults.set(true, forKey: OnboardingModel.introPlayedKey)
    }

    override func tearDown() {
        for (key, value) in saved {
            if let value { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    /// Declining Screen Recording mid-setup must not strand the user on the
    /// permissions page: "Set up later" should still reach the engine choice.
    func testSkipFromPermissionsReachesFinaleWhenScreenRecordingDeclined() {
        defaults.set(false, forKey: autoShownKey)

        let model = OnboardingModel(mode: .firstRun)
        model.axTrusted = true       // Accessibility granted...
        model.scrTrusted = false     // ...Screen Recording declined.
        // Force the state under test — on a machine where both permissions are
        // already granted (e.g. the dev's Mac) the constructor would otherwise
        // skip straight to .finale, which is exactly why the bug hides locally.
        model.page = .permissions

        XCTAssertEqual(model.nextPermission, .screenRecording)

        model.skipAction()

        XCTAssertEqual(model.page, .finale)
    }

    /// Review mode (reopened from Help, after initial setup) keeps the old
    /// behavior: skipping just dismisses, it does not jump to the engine choice.
    func testSkipFromPermissionsInReviewModeDoesNotJumpToFinale() {
        defaults.set(true, forKey: autoShownKey)

        let model = OnboardingModel(mode: .review)
        model.axTrusted = true
        model.scrTrusted = false
        model.page = .permissions

        model.skipAction()

        XCTAssertEqual(model.page, .permissions)
    }
}
