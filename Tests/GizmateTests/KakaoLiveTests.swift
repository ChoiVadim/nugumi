import XCTest
@testable import Gizmate

/// Live end-to-end check against the real KakaoTalk database on this machine.
/// Skipped unless `NUGUMI_LIVE_KAKAO=1` and Full Disk Access is granted to the
/// test runner — it is a manual verification tool, never a CI gate.
final class KakaoLiveTests: XCTestCase {
    func testOpenRealDatabase() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NUGUMI_LIVE_KAKAO"] == "1")
        let archive = try KakaoArchive.open()
        let chats = try archive.recentChats(limit: 5)
        XCTAssertFalse(chats.isEmpty, "expected at least one chat")
        print("LIVE KAKAO: \(chats.count) recent chats; first = '\(chats.first?.title ?? "?")'")
        if let first = chats.first {
            let msgs = try archive.messages(chatID: first.id, limit: 10)
            print("LIVE KAKAO: '\(first.title)' last \(msgs.count) msgs; newest = '\(msgs.last?.text.prefix(40) ?? "")'")
            XCTAssertFalse(msgs.isEmpty)
        }
    }
}
