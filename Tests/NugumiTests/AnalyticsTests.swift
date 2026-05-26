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
        XCTAssertEqual(event.properties["app_version"], "1.2.3")
        XCTAssertEqual(event.properties["build"], "45")
        XCTAssertEqual(event.properties["os"], "macOS 15.0")
        XCTAssertEqual(event.properties["architecture"], "arm64")
        XCTAssertNil(event.properties["source_text"])
        XCTAssertNil(event.properties["result_text"])
        XCTAssertNil(event.properties["api_key"])
        XCTAssertNil(event.properties["screenshot"])
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
