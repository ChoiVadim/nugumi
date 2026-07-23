import XCTest
@testable import Nugumi

final class ChatTranscriptTests: XCTestCase {
    private func lines(_ n: Int) -> [ChatLine] {
        (0..<n).map { ChatLine(sender: "U\($0 % 2)", text: "msg \($0)", date: Date(timeIntervalSince1970: Double($0))) }
    }

    func testKeepsNewestWhenOverMessageCap() {
        let out = ChatTranscript.format(lines(10), maxMessages: 3, tokenBudget: 100_000)
        XCTAssertTrue(out.contains("msg 9"))
        XCTAssertFalse(out.contains("msg 6"))   // only last 3 kept
        XCTAssertTrue(out.hasPrefix("U1: msg 7")) // oldest-of-kept first
    }

    func testTokenBudgetTrimsFromOldestEnd() {
        // ~4 chars/token; a tiny budget keeps only the newest line.
        let out = ChatTranscript.format(lines(50), maxMessages: 50, tokenBudget: 3)
        XCTAssertTrue(out.contains("msg 49"))
        XCTAssertFalse(out.contains("msg 0"))
    }
}
