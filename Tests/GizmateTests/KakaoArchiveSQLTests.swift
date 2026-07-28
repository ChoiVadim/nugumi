import XCTest
import CSQLCipher
@testable import Gizmate

final class KakaoArchiveSQLTests: XCTestCase {
    private func seed() -> SQLCipherDatabase {
        let path = NSTemporaryDirectory() + "kakao-\(UUID().uuidString).db"
        var raw: OpaquePointer?
        sqlite3_open_v2(path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        sqlite3_exec(raw, """
            CREATE TABLE NTUser(userId INTEGER, linkId INTEGER, displayName TEXT, friendNickName TEXT, nickName TEXT);
            CREATE TABLE NTChatRoom(chatId INTEGER, type INTEGER, chatName TEXT, directChatMemberUserId INTEGER, lastUpdatedAt INTEGER);
            CREATE TABLE NTChatMessage(logId INTEGER, chatId INTEGER, authorId INTEGER, message TEXT, type INTEGER, sentAt INTEGER);
            INSERT INTO NTUser VALUES(100,0,'Alice',NULL,NULL),(200,0,'Bob',NULL,NULL);
            INSERT INTO NTChatRoom VALUES(9,0,NULL,100,1700000200);
            INSERT INTO NTChatMessage VALUES(1,9,100,'hey',1,1700000100),(2,9,200,'yo',1,1700000200);
        """, nil, nil, nil)
        sqlite3_close(raw)
        return SQLCipherDatabase(path: path, passphrase: nil)!
    }

    func testRecentChatsResolvesDirectName() throws {
        let archive = KakaoArchive(db: seed())
        let chats = try archive.recentChats(limit: 10)
        XCTAssertEqual(chats.first?.id, 9)
        XCTAssertEqual(chats.first?.title, "Alice")   // direct chat → member name
    }

    func testMessagesOrderedOldestFirstWithSenders() throws {
        let archive = KakaoArchive(db: seed())
        let msgs = try archive.messages(chatID: 9, limit: 10)
        XCTAssertEqual(msgs.map(\.text), ["hey", "yo"])          // oldest → newest
        XCTAssertEqual(msgs.map(\.sender), ["Alice", "Bob"])
    }
}
