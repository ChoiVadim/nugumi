import XCTest
import CSQLCipher
@testable import Nugumi

final class SQLCipherDatabaseTests: XCTestCase {
    func testEncryptedOpenAndQuery() {
        let path = NSTemporaryDirectory() + "wrap-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        // Seed an encrypted DB directly via the C API.
        var raw: OpaquePointer?
        sqlite3_open_v2(path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        sqlite3_exec(raw, "PRAGMA key='k'; CREATE TABLE t(id INTEGER, v TEXT); INSERT INTO t VALUES(7,'ok');", nil, nil, nil)
        sqlite3_close(raw)

        let db = SQLCipherDatabase(path: path, passphrase: "k")
        XCTAssertNotNil(db)
        let rows = db!.query("SELECT id, v FROM t WHERE id = ?", [7])
        XCTAssertEqual(rows.count, 1)
        if case .int(let id) = rows[0][0] { XCTAssertEqual(id, 7) } else { XCTFail() }
        if case .text(let v) = rows[0][1] { XCTAssertEqual(v, "ok") } else { XCTFail() }
    }

    func testWrongPassphraseFailsToOpen() {
        let path = NSTemporaryDirectory() + "wrap-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        var raw: OpaquePointer?
        sqlite3_open_v2(path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        sqlite3_exec(raw, "PRAGMA key='right'; CREATE TABLE t(id INTEGER);", nil, nil, nil)
        sqlite3_close(raw)
        XCTAssertNil(SQLCipherDatabase(path: path, passphrase: "wrong"))
    }
}
