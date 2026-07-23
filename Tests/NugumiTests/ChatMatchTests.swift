import XCTest
import CSQLCipher
@testable import Nugumi

final class ChatMatchTests: XCTestCase {
    private func seed() -> SQLCipherDatabase {
        let path = NSTemporaryDirectory() + "kakao-match-\(UUID().uuidString).db"
        var raw: OpaquePointer?
        sqlite3_open_v2(path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        sqlite3_exec(raw, """
            CREATE TABLE NTUser(userId INTEGER, linkId INTEGER, displayName TEXT, friendNickName TEXT, nickName TEXT);
            CREATE TABLE NTChatRoom(chatId INTEGER, type INTEGER, chatName TEXT, directChatMemberUserId INTEGER, lastUpdatedAt INTEGER);
            CREATE TABLE NTChatMessage(logId INTEGER, chatId INTEGER, authorId INTEGER, message TEXT, type INTEGER, sentAt INTEGER);
            INSERT INTO NTUser VALUES(100,0,'Alice',NULL,NULL),(200,0,'Bob',NULL,NULL);
            INSERT INTO NTChatRoom VALUES(9,0,'Weekend Trip Planning',NULL,1700000100);
            INSERT INTO NTChatRoom VALUES(10,0,'Family Group',NULL,1700000900);
            INSERT INTO NTChatMessage VALUES(1,9,100,'hey',1,1700000050),(2,10,200,'yo',1,1700000800);
        """, nil, nil, nil)
        sqlite3_close(raw)
        return SQLCipherDatabase(path: path, passphrase: nil)!
    }

    func testTitleMatchReturnsMatchingRoom() throws {
        let archive = KakaoArchive(db: seed())
        let (chat, matched) = try archive.chat(forWindowTitle: "Weekend Trip Planning - KakaoTalk")
        XCTAssertEqual(chat.id, 9)
        XCTAssertTrue(matched)
    }

    func testNilTitleReturnsNewestRoomUnmatched() throws {
        let archive = KakaoArchive(db: seed())
        let (chat, matched) = try archive.chat(forWindowTitle: nil)
        XCTAssertEqual(chat.id, 10)   // lastUpdatedAt DESC → newest first
        XCTAssertFalse(matched)
    }

    func testNonMatchingTitleReturnsNewestRoomUnmatched() throws {
        let archive = KakaoArchive(db: seed())
        let (chat, matched) = try archive.chat(forWindowTitle: "Some Unrelated Window")
        XCTAssertEqual(chat.id, 10)
        XCTAssertFalse(matched)
    }
}
