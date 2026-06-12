import XCTest
@testable import Nugumi

final class AnalyticsTests: XCTestCase {
    func testAnonymousDeviceIDIsStableAndLooksLikeUUID() {
        let suiteName = "AnalyticsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = PrivacySafeAnalytics.anonymousDeviceID(defaults: defaults)
        let second = PrivacySafeAnalytics.anonymousDeviceID(defaults: defaults)

        XCTAssertEqual(first, second)
        XCTAssertNotNil(UUID(uuidString: first))
    }

    func testEventPayloadOnlyKeepsWhitelistedPrivacySafeProperties() throws {
        let event = PrivacySafeAnalytics.makePayload(
            event: .translateCompleted,
            distinctID: "device-123",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            properties: [
                "mode": "selection",
                "target_language": "ko",
                "permission": "accessibility",
                "accessibility_status": "granted",
                "screen_recording_status": "missing",
                "source_event": "translate_completed",
                "source_text": "private selected text",
                "result_text": "private model output",
                "api_key": "secret",
                "screenshot": "pixels"
            ],
            environment: AnalyticsEnvironment(
                appVersion: "1.2.3",
                build: "45",
                osVersion: "macOS 15.0",
                architecture: "arm64"
            )
        )

        XCTAssertEqual(event.event, "translate_completed")
        XCTAssertEqual(event.distinctID, "device-123")
        XCTAssertEqual(event.properties["mode"], "selection")
        XCTAssertEqual(event.properties["target_language"], "ko")
        XCTAssertEqual(event.properties["permission"], "accessibility")
        XCTAssertEqual(event.properties["accessibility_status"], "granted")
        XCTAssertEqual(event.properties["screen_recording_status"], "missing")
        XCTAssertEqual(event.properties["source_event"], "translate_completed")
        XCTAssertEqual(event.properties["app_version"], "1.2.3")
        XCTAssertEqual(event.properties["build"], "45")
        XCTAssertEqual(event.properties["os"], "macOS 15.0")
        XCTAssertEqual(event.properties["architecture"], "arm64")
        XCTAssertNil(event.properties["source_text"])
        XCTAssertNil(event.properties["result_text"])
        XCTAssertNil(event.properties["api_key"])
        XCTAssertNil(event.properties["screenshot"])
    }

    func testFunnelEventNamesCoverInstallOnboardingPermissionsFirstActionAndErrors() {
        let names = Set(AnalyticsEventName.allCases.map(\.rawValue))

        XCTAssertTrue(names.contains("app_installed"))
        XCTAssertTrue(names.contains("app_launched"))
        XCTAssertTrue(names.contains("onboarding_started"))
        XCTAssertTrue(names.contains("permissions_prompted"))
        XCTAssertTrue(names.contains("permission_granted"))
        XCTAssertTrue(names.contains("permissions_completed"))
        XCTAssertTrue(names.contains("first_useful_action_completed"))
        XCTAssertTrue(names.contains("error_occurred"))
    }

    @MainActor
    func testOneShotEventsDoNotBurnFlagWhenClientUnconfigured() {
        let suiteName = "AnalyticsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // No API key configured — the one-shot must stay available so it can
        // still fire after the app is updated to a configured build.
        let client = AnalyticsClient(defaults: defaults)
        client.trackInstallIfNeeded()

        XCTAssertFalse(defaults.bool(forKey: "analytics.appInstalledTracked.v1"))
    }

    @MainActor
    func testOneShotEventsConsumeFlagOnceWhenConfigured() {
        let suiteName = "AnalyticsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("phc_test", forKey: "analytics.posthog.apiKey")
        defaults.set("http://127.0.0.1:9/batch/", forKey: "analytics.posthog.endpoint")

        let client = AnalyticsClient(defaults: defaults)
        client.trackInstallIfNeeded()
        client.trackPermissionGrantedIfNeeded(permission: "accessibility")
        client.trackPermissionGrantedIfNeeded(permission: "screen_recording")
        client.trackPermissionsCompletedIfNeeded()
        client.trackOnboardingCompletedIfNeeded(skipped: false)

        XCTAssertTrue(defaults.bool(forKey: "analytics.appInstalledTracked.v1"))
        XCTAssertTrue(defaults.bool(forKey: "analytics.permissionGrantedTracked.accessibility.v1"))
        XCTAssertTrue(defaults.bool(forKey: "analytics.permissionGrantedTracked.screen_recording.v1"))
        XCTAssertTrue(defaults.bool(forKey: "analytics.permissionsCompletedTracked.v1"))
        XCTAssertTrue(defaults.bool(forKey: "analytics.onboardingCompletedTracked.v1"))
    }

    func testPostHogBatchRequestShape() throws {
        let payload = PrivacySafeAnalytics.makePayload(
            event: .appLaunched,
            distinctID: "device-123",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            properties: [:],
            environment: .test
        )

        let request = PostHogBatchRequest(apiKey: "phc_test", batch: [payload])
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let batch = json?["batch"] as? [[String: Any]]
        let first = batch?.first

        XCTAssertEqual(json?["api_key"] as? String, "phc_test")
        XCTAssertEqual(first?["event"] as? String, "app_launched")
        XCTAssertEqual(first?["distinct_id"] as? String, "device-123")
        XCTAssertNotNil(first?["properties"] as? [String: String])
    }
}

private extension AnalyticsEnvironment {
    static let test = AnalyticsEnvironment(
        appVersion: "test-version",
        build: "test-build",
        osVersion: "test-os",
        architecture: "test-arch"
    )
}
