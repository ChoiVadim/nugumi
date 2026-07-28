import XCTest
import CSQLCipher

final class SQLCipherLinkTests: XCTestCase {
    func testEncryptedRoundTrip() {
        let path = NSTemporaryDirectory() + "cipher-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA key='secret';", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE t(v TEXT); INSERT INTO t VALUES('hi');", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        // Reopen with the WRONG key: the first read must fail.
        db = nil
        XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA key='wrong';", nil, nil, nil), SQLITE_OK)
        XCTAssertNotEqual(sqlite3_exec(db, "SELECT count(*) FROM sqlite_master;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        // Reopen with the RIGHT key: read must succeed.
        db = nil
        XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA key='secret';", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "SELECT count(*) FROM sqlite_master;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
    }
}
