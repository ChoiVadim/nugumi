import XCTest
@testable import Nugumi

final class CloudHTTPErrorTests: XCTestCase {

    func testExtractsProviderErrorMessage() {
        let body = #"{"error":{"message":"This request requires more credits.","code":402}}"#.data(using: .utf8)
        XCTAssertEqual(CloudHTTPError.extractMessage(from: body), "This request requires more credits.")
    }

    func testExtractsStringErrorAndTopLevelMessage() {
        XCTAssertEqual(
            CloudHTTPError.extractMessage(from: #"{"error":"bad request"}"#.data(using: .utf8)),
            "bad request"
        )
        XCTAssertEqual(
            CloudHTTPError.extractMessage(from: #"{"message":"nope"}"#.data(using: .utf8)),
            "nope"
        )
    }

    func testExtractReturnsNilOnGarbageOrEmpty() {
        XCTAssertNil(CloudHTTPError.extractMessage(from: "not json".data(using: .utf8)))
        XCTAssertNil(CloudHTTPError.extractMessage(from: Data()))
        XCTAssertNil(CloudHTTPError.extractMessage(from: nil))
    }

    func testFriendlyMessageIsHumanForKnownCodes() {
        // No raw "HTTP 402" leaks for the codes users actually hit.
        XCTAssertFalse(CloudHTTPError.friendlyMessage(status: 402).contains("402"))
        XCTAssertTrue(CloudHTTPError.friendlyMessage(status: 402).lowercased().contains("credit"))
        XCTAssertTrue(CloudHTTPError.friendlyMessage(status: 503).lowercased().contains("try again"))
        // An unmapped code still degrades gracefully (includes the number).
        XCTAssertTrue(CloudHTTPError.friendlyMessage(status: 418).contains("418"))
    }

    func testDetailPrefersBodyMessageOverStatusMap() {
        let body = #"{"error":{"message":"Insufficient credits — top up to continue."}}"#.data(using: .utf8)
        XCTAssertEqual(
            CloudHTTPError.detail(status: 402, body: body),
            "Insufficient credits — top up to continue."
        )
        // Falls back to the friendly map when there's no usable body.
        XCTAssertEqual(
            CloudHTTPError.detail(status: 402, body: nil),
            CloudHTTPError.friendlyMessage(status: 402)
        )
    }
}
