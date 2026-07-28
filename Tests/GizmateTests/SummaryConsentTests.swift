import XCTest
@testable import Gizmate

final class SummaryConsentTests: XCTestCase {
    func testDefaultsRoundTrip() {
        let key = "summaryCloudConsent.test"
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(SummaryConsent.value(forKey: key))
        SummaryConsent.set(true, forKey: key)
        XCTAssertTrue(SummaryConsent.value(forKey: key))
        UserDefaults.standard.removeObject(forKey: key)
    }
}
