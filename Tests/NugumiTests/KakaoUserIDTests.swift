import XCTest
@testable import Nugumi

final class KakaoUserIDTests: XCTestCase {
    func testDirectKeyWins() {
        let ids = KakaoUserID.candidates(from: ["userId": 987654321])
        XCTAssertEqual(ids.first, 987654321)
    }

    func testWindowFrameSuffix() {
        // "NSWindow Frame FSChatWindowFrame_<id>" → id extracted.
        let ids = KakaoUserID.candidates(from: [
            "NSWindow Frame FSChatWindowFrame_555111": "0 0 400 600"
        ])
        XCTAssertTrue(ids.contains(555111))
    }

    func testNoIdsFound() {
        XCTAssertTrue(KakaoUserID.candidates(from: ["unrelated": "x"]).isEmpty)
    }
}
