import Foundation
import NugumiToolIPC
import XCTest
@testable import Nugumi

final class ProbeFixtureStreamingTests: XCTestCase {
    func testExactly64KiBIsAcceptedWithoutCancellation() async {
        let source = CountingByteSource(count: 65_536)

        let response = await ProbeFixtureLoader.load(
            response: source.response(expectedContentLength: 65_536)
        )

        XCTAssertTrue(response.accepted)
        XCTAssertEqual(response.body.count, 65_536)
        XCTAssertEqual(source.consumedCount, 65_536)
        XCTAssertEqual(source.cancelCount, 0)
        XCTAssertEqual(source.finishCount, 1)
    }

    func test64KiBPlusOneCancelsAtFirstOversizedByte() async {
        let source = CountingByteSource(count: 100_000)

        let response = await ProbeFixtureLoader.load(
            response: source.response(expectedContentLength: -1)
        )

        XCTAssertFalse(response.accepted)
        XCTAssertTrue(response.body.isEmpty)
        XCTAssertEqual(source.consumedCount, 65_537)
        XCTAssertEqual(source.cancelCount, 1)
        XCTAssertEqual(source.finishCount, 0)
    }

    func testOversizedExpectedLengthRejectsBeforeConsumingBody() async {
        let source = CountingByteSource(count: 100_000)

        let response = await ProbeFixtureLoader.load(
            response: source.response(expectedContentLength: 65_537)
        )

        XCTAssertFalse(response.accepted)
        XCTAssertEqual(source.consumedCount, 0)
        XCTAssertEqual(source.cancelCount, 1)
    }

    func testStatusAndRedirectFailClosedWithoutConsumingBody() async {
        let statusSource = CountingByteSource(count: 10)
        let redirectSource = CountingByteSource(count: 10)

        let statusResponse = await ProbeFixtureLoader.load(
            response: statusSource.response(
                statusCode: 204,
                expectedContentLength: 10
            )
        )
        let redirectResponse = await ProbeFixtureLoader.load(
            response: redirectSource.response(
                expectedContentLength: 10,
                redirected: true
            )
        )

        XCTAssertFalse(statusResponse.accepted)
        XCTAssertFalse(redirectResponse.accepted)
        XCTAssertEqual(statusSource.consumedCount, 0)
        XCTAssertEqual(redirectSource.consumedCount, 0)
        XCTAssertEqual(statusSource.cancelCount, 1)
        XCTAssertEqual(redirectSource.cancelCount, 1)
    }

    func testStreamErrorFailsClosedAndCancels() async {
        let source = CountingByteSource(count: 10, failAt: 4)

        let response = await ProbeFixtureLoader.load(
            response: source.response(expectedContentLength: -1)
        )

        XCTAssertFalse(response.accepted)
        XCTAssertTrue(response.body.isEmpty)
        XCTAssertEqual(source.consumedCount, 4)
        XCTAssertEqual(source.cancelCount, 1)
        XCTAssertEqual(source.finishCount, 0)
    }
}

private final class CountingByteSource {
    private let byteCount: Int
    private let failAt: Int?
    private(set) var consumedCount = 0
    private(set) var cancelCount = 0
    private(set) var finishCount = 0

    init(count: Int, failAt: Int? = nil) {
        byteCount = count
        self.failAt = failAt
    }

    func response(
        statusCode: Int = 200,
        expectedContentLength: Int64,
        redirected: Bool = false
    ) -> ProbeFixtureStreamResponse {
        ProbeFixtureStreamResponse(
            statusCode: statusCode,
            expectedContentLength: expectedContentLength,
            redirected: redirected,
            stream: ProbeFixtureByteStream(
                next: { [self] in
                    if consumedCount == failAt {
                        throw TestStreamError.failed
                    }
                    guard consumedCount < byteCount else { return nil }
                    consumedCount += 1
                    return 0x41
                },
                cancel: { [self] in cancelCount += 1 },
                finish: { [self] in finishCount += 1 }
            )
        )
    }
}

private enum TestStreamError: Error {
    case failed
}
