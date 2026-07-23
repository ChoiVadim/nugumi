import XCTest
@testable import Nugumi

final class KakaoKeyDerivationTests: XCTestCase {
    let uuid = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

    func testDatabaseNameShapeAndDeterminism() {
        let a = KakaoKeyDerivation.databaseName(userId: 12345, uuid: uuid)
        let b = KakaoKeyDerivation.databaseName(userId: 12345, uuid: uuid)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 78)
        XCTAssertTrue(a.allSatisfy { $0.isHexDigit })
    }

    func testSecureKeyShapeAndDeterminism() {
        let a = KakaoKeyDerivation.secureKey(userId: 12345, uuid: uuid)
        let b = KakaoKeyDerivation.secureKey(userId: 12345, uuid: uuid)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 256)
    }

    func testDifferentUserIdChangesKey() {
        XCTAssertNotEqual(
            KakaoKeyDerivation.secureKey(userId: 1, uuid: uuid),
            KakaoKeyDerivation.secureKey(userId: 2, uuid: uuid)
        )
    }

    /// Golden regression vector. These values were captured from this exact
    /// implementation (userId: 12345, uuid: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
    /// and pinned here to catch future refactors that silently change the
    /// derivation's composition. This does NOT independently validate the
    /// values against a real KakaoTalk install/reference implementation —
    /// that correctness check happens later, against a live KakaoTalk DB
    /// (see Task 10).
    func testKnownAnswerVector() {
        XCTAssertEqual(
            KakaoKeyDerivation.databaseName(userId: 12345, uuid: uuid),
            "41d955f9bda54b4af4c5ef87c2954421e0fc1efb939c01b77077b29dd8d55364706a0e98db7259"
        )
        XCTAssertEqual(
            KakaoKeyDerivation.secureKey(userId: 12345, uuid: uuid),
            "09370703034c75bc9a381e686d3221ff7c2c6d062e30540ec6e487b6eab65083eb3757e9e398d5c6a160f360f6a6c52efeb03a511d20f9f4c60f542231a2cd7d1c2cd8caaef29d505291d493e1fb570ac8baa17692343a3a7bac6ed3027b57b46ccade990bcbddc434153acf16dc03eedac58b2645183d036d6e180eaeb2c67f"
        )
    }
}
