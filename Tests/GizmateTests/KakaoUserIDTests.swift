import XCTest
import CryptoKit
@testable import Gizmate

final class KakaoUserIDTests: XCTestCase {
    func testDirectKeyWins() {
        let ids = KakaoUserID.candidates(from: ["userId": 987654321])
        XCTAssertEqual(ids.first, 987654321)
    }

    func testAlertKakaoIDsListCandidates() {
        // Newer KakaoTalk exposes account/friend ids only via this key.
        let ids = KakaoUserID.candidates(from: ["AlertKakaoIDsList": [25411718, 344940307, "388584983"]])
        XCTAssertTrue(ids.contains(25411718))
        XCTAssertTrue(ids.contains(344940307))
        XCTAssertTrue(ids.contains(388584983))
    }

    func testBruteForceRecoversSHA512Preimage() {
        // The real fix path: recover a userId from sha512(decimal(id)). Small
        // maxId keeps this fast in the unoptimized test build; the real 1e9
        // search runs in the optimized app off the main thread (and is cached).
        let n = 98_765
        let hash = SHA512.hash(data: Data(String(n).utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(KakaoUserID.bruteForceSHA512Preimage(targetHex: hash, maxId: 200_000), n)
    }

    func testBruteForceRejectsUnfindablePreimage() {
        let hash = SHA512.hash(data: Data("999999".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertNil(KakaoUserID.bruteForceSHA512Preimage(targetHex: hash, maxId: 100))
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
