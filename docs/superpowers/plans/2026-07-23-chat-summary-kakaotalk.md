# Chat Summary (KakaoTalk) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Summarize KakaoTalk chat" action to Nugumi's radial ring that decrypts the local KakaoTalk SQLCipher database, reads the last N messages of the open chat, and summarizes them through the existing LLM path.

**Architecture:** A new self-contained `ChatArchive` subsystem (`Sources/Nugumi/ChatArchive.swift`) ports KakaoTalk's key derivation and reads its SQLite tables through a thin wrapper over a vendored, statically-linked SQLCipher C target (`Sources/CSQLCipher`, CommonCrypto backend). The ring is generalized from 4 fixed actions to a dynamic, contextual button list; a contextual Kakao button (wearing the app icon) opens a second ring layer to pick the message count, then summarizes via a new `TranslationMode.summarizeChat`.

**Tech Stack:** Swift 6 (language mode v5), AppKit, SwiftPM, SQLCipher (amalgamation + CommonCrypto), CommonCrypto/Security, existing `LLMBackend` path.

## Global Constraints

- Platform floor: **macOS 14**; `swift-tools-version: 6.0`, `swiftLanguageModes: [.v5]`.
- **Single-file rule:** app logic lives in `Sources/Nugumi/App.swift`; a new file is allowed only for a whole subsystem — `ChatArchive.swift` qualifies. Do not split App.swift further.
- **Copy rule:** never use "translate/translation/translator" in user-facing strings. Use "Summary"/"Summarize".
- SQLCipher must use **CommonCrypto** (`-DSQLCIPHER_CRYPTO_CC`), **no OpenSSL**; statically linked into the Nugumi binary.
- The chat database is opened **READONLY**; the subsystem never writes to another app's container.
- **Never crash on failure** — every failure path renders a human-readable message in the result panel.
- Full Disk Access is required to read the KakaoTalk container; probe it by attempting to list the container.
- KakaoTalk bundle ID: `com.kakao.KakaoTalkMac`. Container: `~/Library/Containers/com.kakao.KakaoTalkMac/Data/Library/Application Support/com.kakao.KakaoTalkMac/`.
- Ported reference code (kakaocli / blluv gist) is **read for correctness and safety before integration** and never executed as a downloaded artifact.

---

### Task 1: Vendor SQLCipher as a static C target

**Files:**

- Create: `Sources/CSQLCipher/sqlite3.c` (generated amalgamation), `Sources/CSQLCipher/include/sqlite3.h`, `Sources/CSQLCipher/include/csqlcipher.h`, `Sources/CSQLCipher/include/module.modulemap`
- Modify: `Package.swift`
- Test: `Tests/NugumiTests/SQLCipherLinkTests.swift`

**Interfaces:**

- Produces: a `CSQLCipher` module exposing the SQLite C API (`sqlite3_open_v2`, `sqlite3_exec`, `sqlite3_prepare_v2`, `sqlite3_key`, …) with the SQLCipher codec compiled in.

- [ ] **Step 1: Generate the SQLCipher amalgamation**

Run (outside the repo, in a scratch dir):

```bash
git clone --depth 1 https://github.com/sqlcipher/sqlcipher.git
cd sqlcipher
./configure --with-crypto-lib=commoncrypto \
  CFLAGS="-DSQLITE_HAS_CODEC -DSQLCIPHER_CRYPTO_CC" \
  LDFLAGS="-framework Security -framework Foundation"
make sqlite3.c            # produces sqlite3.c (amalgamation) + sqlite3.h
```

Copy `sqlite3.c` → `Sources/CSQLCipher/sqlite3.c` and `sqlite3.h` → `Sources/CSQLCipher/include/sqlite3.h`.

- [ ] **Step 2: Add the module map and umbrella header**

`Sources/CSQLCipher/include/csqlcipher.h`:

```c
#ifndef CSQLCIPHER_H
#define CSQLCIPHER_H
#include "sqlite3.h"
#endif
```

`Sources/CSQLCipher/include/module.modulemap`:

```
module CSQLCipher {
    umbrella header "csqlcipher.h"
    export *
}
```

- [ ] **Step 3: Wire the target in Package.swift**

Add to `targets:` (before the Nugumi target) and add the dependency:

```swift
.target(
    name: "CSQLCipher",
    path: "Sources/CSQLCipher",
    publicHeadersPath: "include",
    cSettings: [
        .define("SQLITE_HAS_CODEC"),
        .define("SQLCIPHER_CRYPTO_CC"),
        .define("SQLITE_TEMP_STORE", to: "2"),
        .define("NDEBUG"),
        .headerSearchPath("include")
    ],
    linkerSettings: [
        .linkedFramework("Security"),
        .linkedFramework("Foundation")
    ]
),
```

And in the `Nugumi` executable target's `dependencies`, add `"CSQLCipher"`.

- [ ] **Step 4: Write the failing round-trip test**

`Tests/NugumiTests/SQLCipherLinkTests.swift`:

```swift
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
```

- [ ] **Step 5: Build and run — verify the codec is active**

Run: `swift test --filter SQLCipherLinkTests`
Expected: PASS. If the "wrong key" read _succeeds_, the codec is NOT linked (stock SQLite ignores `PRAGMA key`) — recheck Step 1/3 defines. If it fails to build with `sqlite3_key not found`, the amalgamation lacks the codec — regenerate with the SQLCipher configure flags.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/CSQLCipher Tests/NugumiTests/SQLCipherLinkTests.swift
git commit -m "Add statically-linked SQLCipher (CommonCrypto) C target"
```

---

### Task 2: KakaoTalk key derivation

**Files:**

- Create: `Sources/Nugumi/ChatArchive.swift`
- Test: `Tests/NugumiTests/KakaoKeyDerivationTests.swift`

**Interfaces:**

- Produces: `enum KakaoKeyDerivation` with
  `static func platformUUID() throws -> String`,
  `static func databaseName(userId: Int, uuid: String) -> String` (78-char hex),
  `static func secureKey(userId: Int, uuid: String) -> String` (256-char hex passphrase).

- [ ] **Step 1: Write the failing determinism/shape test**

`Tests/NugumiTests/KakaoKeyDerivationTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter KakaoKeyDerivationTests`
Expected: FAIL — `KakaoKeyDerivation` undefined.

- [ ] **Step 3: Implement the derivation (ported verbatim from kakaocli / blluv gist)**

Create `Sources/Nugumi/ChatArchive.swift` starting with:

```swift
import Foundation
import CommonCrypto
import CSQLCipher

enum ChatArchiveError: Error, CustomStringConvertible {
    case fullDiskAccessMissing
    case kakaoUserIdNotFound
    case databaseNotFound
    case databaseOpenFailed
    case emptyChat
    case chatNotMatched

    var description: String {
        switch self {
        case .fullDiskAccessMissing: return "Grant Full Disk Access to summarize chats."
        case .kakaoUserIdNotFound:   return "Couldn't read KakaoTalk account data."
        case .databaseNotFound:      return "Couldn't find the KakaoTalk chat database."
        case .databaseOpenFailed:    return "Couldn't open the chat database (it may have updated)."
        case .emptyChat:             return "No messages to summarize in this chat."
        case .chatNotMatched:        return "Couldn't tell which chat is open."
        }
    }
}

enum KakaoKeyDerivation {
    /// IOPlatformUUID (uppercase hex), hashed raw — do NOT lowercase.
    static func platformUUID() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-rd1", "-c", "IOPlatformExpertDevice"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let r = output.range(
            of: #"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"#,
            options: .regularExpression
        ) else { throw ChatArchiveError.databaseNotFound }
        return String(output[r])
    }

    /// base64( sha1(uuid) ++ sha256(uuid) )
    private static func hashedDeviceUUID(_ uuid: String) -> String {
        let data = Data(uuid.utf8)
        var sha1 = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        var sha256 = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &sha1) }
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &sha256) }
        return Data(sha1 + sha256).base64EncodedString()
    }

    /// PBKDF2-HMAC-SHA256, 100000 iters, 128-byte output.
    private static func pbkdf2(password: Data, salt: Data) -> Data {
        var out = [UInt8](repeating: 0, count: 128)
        password.withUnsafeBytes { pw in
            salt.withUnsafeBytes { sl in
                _ = CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pw.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                    sl.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    100_000, &out, out.count
                )
            }
        }
        return Data(out)
    }

    private static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    static func databaseName(userId: Int, uuid: String) -> String {
        let hawawa = [".", "F", String(userId), "A", "F",
                      String(uuid.reversed()), ".", "|"].joined(separator: ".")
        let salt = String(hashedDeviceUUID(uuid).reversed())
        let full = hex(pbkdf2(password: Data(hawawa.utf8), salt: Data(salt.utf8)))
        let start = full.index(full.startIndex, offsetBy: 28)
        let end = full.index(start, offsetBy: 78)
        return String(full[start..<end])
    }

    static func secureKey(userId: Int, uuid: String) -> String {
        let hashed = hashedDeviceUUID(uuid)
        let parts = ["A", hashed, "|", "F", String(uuid.prefix(5)),
                     "H", String(userId), "|", String(uuid.dropFirst(7))]
        let hawawa = parts.joined(separator: "F")
        let saltStart = uuid.index(uuid.startIndex, offsetBy: Int(Double(uuid.count) * 0.3))
        let salt = String(uuid[saltStart...])
        return hex(pbkdf2(password: Data(String(hawawa.reversed()).utf8), salt: Data(salt.utf8)))
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter KakaoKeyDerivationTests`
Expected: PASS.

- [ ] **Step 5: Record a cross-language KAT (manual, one-time)**

Run the blluv gist Python and this Swift on `userId=12345, uuid="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"`; confirm `databaseName`/`secureKey` match byte-for-byte, then paste both expected strings into a new `testKnownAnswerVector()` asserting exact equality (guards against a future refactor changing the composition). Commit that test in this step.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nugumi/ChatArchive.swift Tests/NugumiTests/KakaoKeyDerivationTests.swift
git commit -m "Port KakaoTalk SQLCipher key derivation"
```

---

### Task 3: SQLCipher database wrapper

**Files:**

- Modify: `Sources/Nugumi/ChatArchive.swift`
- Test: `Tests/NugumiTests/SQLCipherDatabaseTests.swift`

**Interfaces:**

- Produces: `final class SQLCipherDatabase` with
  `init?(path: String, passphrase: String?)` (nil passphrase → plain SQLite, for tests),
  `func query(_ sql: String, _ binds: [Int64]) -> [[SQLValue]]` where
  `enum SQLValue { case int(Int64); case text(String); case null }`.
- Consumes: `CSQLCipher` (Task 1).

- [ ] **Step 1: Write the failing test (plain + encrypted)**

`Tests/NugumiTests/SQLCipherDatabaseTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter SQLCipherDatabaseTests`
Expected: FAIL — `SQLCipherDatabase` undefined.

- [ ] **Step 3: Implement the wrapper**

Append to `ChatArchive.swift`:

```swift
enum SQLValue: Equatable { case int(Int64); case text(String); case null }

final class SQLCipherDatabase {
    private var db: OpaquePointer?
    private static let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(path: String, passphrase: String?) {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
        if let passphrase {
            // Try SQLCipher compatibility 3 then 4 (older vs newer KakaoTalk builds).
            var opened = false
            for compat in [3, 4] {
                _ = exec("PRAGMA cipher_default_compatibility = \(compat)")
                _ = exec("PRAGMA key='\(passphrase)'")
                if exec("SELECT count(*) FROM sqlite_master") { opened = true; break }
            }
            guard opened else { sqlite3_close(db); return nil }
        }
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    func query(_ sql: String, _ binds: [Int64] = []) -> [[SQLValue]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i, b) in binds.enumerated() { sqlite3_bind_int64(stmt, Int32(i + 1), b) }
        var rows: [[SQLValue]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let n = sqlite3_column_count(stmt)
            var row: [SQLValue] = []
            for c in 0..<n {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(stmt, c)))
                case SQLITE_NULL:    row.append(.null)
                default:
                    if let cstr = sqlite3_column_text(stmt, c) {
                        row.append(.text(String(cString: cstr)))
                    } else { row.append(.null) }
                }
            }
            rows.append(row)
        }
        return rows
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter SQLCipherDatabaseTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nugumi/ChatArchive.swift Tests/NugumiTests/SQLCipherDatabaseTests.swift
git commit -m "Add READONLY SQLCipher database wrapper"
```

---

### Task 4: KakaoTalk userId candidates

**Files:**

- Modify: `Sources/Nugumi/ChatArchive.swift`
- Test: `Tests/NugumiTests/KakaoUserIDTests.swift`

**Interfaces:**

- Produces: `enum KakaoUserID { static func candidates(from prefs: [String: Any]) -> [Int] }` — ordered candidate ids parsed from a KakaoTalk preferences dictionary.
- Consumes: nothing new.

- [ ] **Step 1: Write the failing test**

`Tests/NugumiTests/KakaoUserIDTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter KakaoUserIDTests`
Expected: FAIL — `KakaoUserID` undefined.

- [ ] **Step 3: Implement candidate extraction**

Append to `ChatArchive.swift`:

```swift
enum KakaoUserID {
    /// Ordered candidate user ids parsed from KakaoTalk's preferences.
    /// Direct keys first, then ids embedded in window-frame / transparency keys.
    static func candidates(from prefs: [String: Any]) -> [Int] {
        var ordered: [Int] = []
        func add(_ v: Int) { if v > 0, !ordered.contains(v) { ordered.append(v) } }

        for key in ["userId", "user_id", "KAKAO_USER_ID", "userID"] {
            if let n = prefs[key] as? Int { add(n) }
            else if let s = prefs[key] as? String, let n = Int(s) { add(n) }
        }
        // Ids embedded in dynamic key names, e.g.
        // "NSWindow Frame FSChatWindowFrame_<id>" / "FSChatWindowTransparency<id>".
        let patterns = [#"FSChatWindowFrame_(\d+)"#, #"FSChatWindowTransparency(\d+)"#]
        for key in prefs.keys {
            for p in patterns {
                if let r = key.range(of: p, options: .regularExpression) {
                    let digits = key[r].filter { $0.isNumber }
                    if let n = Int(digits) { add(n) }
                }
            }
        }
        return ordered
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter KakaoUserIDTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nugumi/ChatArchive.swift Tests/NugumiTests/KakaoUserIDTests.swift
git commit -m "Extract KakaoTalk userId candidates from preferences"
```

---

### Task 5: ChatArchive protocol + KakaoArchive

**Files:**

- Modify: `Sources/Nugumi/ChatArchive.swift`
- Test: `Tests/NugumiTests/KakaoArchiveSQLTests.swift`

**Interfaces:**

- Produces:
  - `struct ChatSummary { let id: Int64; let title: String; let lastActivity: Date? }`
  - `struct ChatLine { let sender: String; let text: String; let date: Date }`
  - `protocol ChatArchive { var appLabel: String { get }; func recentChats(limit: Int) throws -> [ChatSummary]; func messages(chatID: Int64, limit: Int) throws -> [ChatLine] }`
  - `final class KakaoArchive: ChatArchive` with `init(db: SQLCipherDatabase)` (test seam) and `static func open() throws -> KakaoArchive` (real container path).
  - `enum ChatArchiveFactory { static func archive(forFrontmostBundleID id: String?) -> (() throws -> ChatArchive)? }`
- Consumes: `SQLCipherDatabase` (Task 3), `KakaoKeyDerivation` (Task 2), `KakaoUserID` (Task 4).

- [ ] **Step 1: Write the failing SQL test against a synthetic plaintext DB**

`Tests/NugumiTests/KakaoArchiveSQLTests.swift`:

```swift
import XCTest
import CSQLCipher
@testable import Nugumi

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
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter KakaoArchiveSQLTests`
Expected: FAIL — `KakaoArchive` undefined.

- [ ] **Step 3: Implement models, protocol, KakaoArchive, factory**

Append to `ChatArchive.swift`:

```swift
struct ChatSummary { let id: Int64; let title: String; let lastActivity: Date? }
struct ChatLine { let sender: String; let text: String; let date: Date }

protocol ChatArchive {
    var appLabel: String { get }
    func recentChats(limit: Int) throws -> [ChatSummary]
    func messages(chatID: Int64, limit: Int) throws -> [ChatLine]
}

final class KakaoArchive: ChatArchive {
    let appLabel = "KakaoTalk"
    private let db: SQLCipherDatabase

    init(db: SQLCipherDatabase) { self.db = db }

    static func open() throws -> KakaoArchive {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let container = "\(home)/Library/Containers/com.kakao.KakaoTalkMac/Data/Library/Application Support/com.kakao.KakaoTalkMac"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: container) else {
            throw ChatArchiveError.fullDiskAccessMissing
        }
        let uuid = try KakaoKeyDerivation.platformUUID()

        // Gather candidate user ids from both preference plists.
        var prefs: [String: Any] = [:]
        let prefDir = "\(home)/Library/Containers/com.kakao.KakaoTalkMac/Data/Library/Preferences"
        for path in [
            "\(home)/Library/Preferences/com.kakao.KakaoTalkMac.plist",
            "\(prefDir)/com.kakao.KakaoTalkMac.plist"
        ] + ((try? FileManager.default.contentsOfDirectory(atPath: prefDir)) ?? [])
            .filter { $0.hasPrefix("com.kakao.KakaoTalkMac.") && $0.hasSuffix(".plist") }
            .map { "\(prefDir)/\($0)" } {
            if let d = NSDictionary(contentsOfFile: path) as? [String: Any] { prefs.merge(d) { a, _ in a } }
        }
        let candidates = KakaoUserID.candidates(from: prefs)
        guard !candidates.isEmpty else { throw ChatArchiveError.kakaoUserIdNotFound }

        // Try each candidate: its derived filename must exist AND its key must open the DB.
        for userId in candidates {
            let name = KakaoKeyDerivation.databaseName(userId: userId, uuid: uuid)
            let dbPath = files.contains(name) ? "\(container)/\(name)"
                       : files.contains("\(name).db") ? "\(container)/\(name).db" : nil
            guard let dbPath else { continue }
            let key = KakaoKeyDerivation.secureKey(userId: userId, uuid: uuid)
            if let db = SQLCipherDatabase(path: dbPath, passphrase: key) {
                return KakaoArchive(db: db)
            }
        }
        throw ChatArchiveError.databaseOpenFailed
    }

    func recentChats(limit: Int) throws -> [ChatSummary] {
        let sql = """
            SELECT r.chatId, r.chatName, r.lastUpdatedAt,
                   COALESCE(u.displayName, u.friendNickName, u.nickName)
            FROM NTChatRoom r
            LEFT JOIN NTUser u ON r.directChatMemberUserId = u.userId AND u.linkId = 0
            ORDER BY r.lastUpdatedAt DESC
            LIMIT ?
            """
        return db.query(sql, [Int64(limit)]).compactMap { row in
            guard case .int(let id) = row[0] else { return nil }
            let group = { if case .text(let t) = row[1] { return t } else { return "" } }()
            let direct = { if case .text(let t) = row[3] { return t } else { return "" } }()
            let title = group.isEmpty ? (direct.isEmpty ? "Chat \(id)" : direct) : group
            let ts: Date? = { if case .int(let s) = row[2], s > 0 { return Date(timeIntervalSince1970: Double(s)) } else { return nil } }()
            return ChatSummary(id: id, title: title, lastActivity: ts)
        }
    }

    func messages(chatID: Int64, limit: Int) throws -> [ChatLine] {
        let sql = """
            SELECT COALESCE(u.displayName, u.friendNickName, u.nickName, 'Unknown'),
                   m.message, m.sentAt
            FROM NTChatMessage m
            LEFT JOIN NTUser u ON m.authorId = u.userId AND u.linkId = 0
            WHERE m.chatId = ? AND m.message IS NOT NULL AND m.message <> ''
            ORDER BY m.sentAt DESC
            LIMIT ?
            """
        let rows = db.query(sql, [chatID, Int64(limit)])
        let lines: [ChatLine] = rows.compactMap { row in
            guard case .text(let text) = row[1] else { return nil }
            let sender = { if case .text(let s) = row[0] { return s } else { return "Unknown" } }()
            let date = { if case .int(let s) = row[2] { return Date(timeIntervalSince1970: Double(s)) } else { return Date(timeIntervalSince1970: 0) } }()
            return ChatLine(sender: sender, text: text, date: date)
        }
        if lines.isEmpty { throw ChatArchiveError.emptyChat }
        return lines.reversed()   // query is newest-first; return oldest → newest
    }
}

enum ChatArchiveFactory {
    static func archive(forFrontmostBundleID id: String?) -> (() throws -> ChatArchive)? {
        guard id == "com.kakao.KakaoTalkMac" else { return nil }
        return { try KakaoArchive.open() }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter KakaoArchiveSQLTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nugumi/ChatArchive.swift Tests/NugumiTests/KakaoArchiveSQLTests.swift
git commit -m "Add ChatArchive protocol and KakaoArchive reader"
```

---

### Task 6: Summary mode + transcript formatting

**Files:**

- Modify: `Sources/Nugumi/App.swift` (add `TranslationMode.summarizeChat`), `Sources/Nugumi/ChatArchive.swift` (formatter)
- Test: `Tests/NugumiTests/ChatTranscriptTests.swift`

**Interfaces:**

- Produces: `enum ChatTranscript { static func format(_ lines: [ChatLine], maxMessages: Int, tokenBudget: Int) -> String }`.
- Modifies `TranslationMode`: new case `.summarizeChat` returning `resultLabel = "Summary"`, `loadingPlaceholder = "Summarizing"`, `usesCompositionSettings = false`, and a summarization `systemPrompt`.

- [ ] **Step 1: Write the failing formatter test**

`Tests/NugumiTests/ChatTranscriptTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ChatTranscriptTests`
Expected: FAIL — `ChatTranscript` undefined.

- [ ] **Step 3: Implement the formatter**

Append to `ChatArchive.swift`:

```swift
enum ChatTranscript {
    /// Newest `maxMessages`, then trim from the oldest end to fit a rough
    /// token budget (~4 chars/token). Output is oldest → newest, "Sender: text".
    static func format(_ lines: [ChatLine], maxMessages: Int, tokenBudget: Int) -> String {
        let kept = Array(lines.suffix(maxMessages))
        var rendered = kept.map { "\($0.sender): \($0.text)" }
        let budgetChars = tokenBudget * 4
        while rendered.count > 1, rendered.joined(separator: "\n").count > budgetChars {
            rendered.removeFirst()   // drop oldest first
        }
        return rendered.joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Add the `.summarizeChat` mode**

In `App.swift`, `enum TranslationMode` (App.swift:12994): add `case summarizeChat` and extend each switch:

- `usesCompositionSettings`: add `case .summarizeChat: return false`.
- `resultLabel`: add `case .summarizeChat: return "Summary"`.
- `loadingPlaceholder`: add `case .summarizeChat: return "Summarizing"`.
- `systemPrompt(...)`: add:

```swift
case .summarizeChat:
    """
    You are given a chat transcript as "Sender: message" lines, oldest first. \
    Write a concise summary in \(targetLanguage.promptName): a one-line TL;DR, \
    then a short bulleted list of the key points and decisions, then any action \
    items or open questions addressed to the reader. Preserve names, dates, \
    numbers, and links exactly. Do not invent anything not in the transcript. \
    Return only the summary — no preamble, no quotes.
    """
```

- [ ] **Step 5: Run to verify pass**

Run: `swift test --filter ChatTranscriptTests && swift build`
Expected: PASS + build succeeds (exhaustive `TranslationMode` switches now cover `.summarizeChat`).

- [ ] **Step 6: Commit**

```bash
git add Sources/Nugumi/App.swift Sources/Nugumi/ChatArchive.swift Tests/NugumiTests/ChatTranscriptTests.swift
git commit -m "Add summarizeChat mode and transcript formatter"
```

---

### Task 7: Generalize the ring to a dynamic button list

**Files:**

- Modify: `Sources/Nugumi/App.swift` (`RadialAction`, `RadialMenuLayoutPolicy`, `RadialActionMenuController`, `RadialMenuButtonView`)
- Test: `Tests/NugumiTests/RadialMenuLayoutTests.swift`

**Interfaces:**

- Produces: `struct RingItem { let label: String; let image: NSImage; let handler: () -> Void }`, `RadialMenuLayoutPolicy.buttonCenters(count: Int) -> [CGPoint]` (1…8 positions), and a `RadialActionMenuController` initializer taking `[RingItem]`.
- Consumes: existing ring geometry.

- [ ] **Step 1: Update the layout test for dynamic counts**

In `Tests/NugumiTests/RadialMenuLayoutTests.swift`, replace `testOneButtonCenterPerAction` with:

```swift
func testButtonCentersCountMatchesRequest() {
    for n in 1...8 {
        XCTAssertEqual(RadialMenuLayoutPolicy.buttonCenters(count: n).count, n)
    }
}
func testAllCentersSitOnTheRing() {
    for n in 1...8 {
        for offset in RadialMenuLayoutPolicy.buttonCenters(count: n) {
            let d = (offset.x * offset.x + offset.y * offset.y).squareRoot()
            XCTAssertEqual(d, RadialMenuLayoutPolicy.ringRadius, accuracy: 0.001)
        }
    }
}
```

Update `testButtonCentersSitOnTheRing` to call `buttonCenters(count: 4)`.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter RadialMenuLayoutTests`
Expected: FAIL — `buttonCenters(count:)` not found.

- [ ] **Step 3: Implement dynamic layout + item-driven controller**

In `RadialMenuLayoutPolicy`, replace `buttonCenters()` with:

```swift
/// `count` evenly-spaced positions. 1–4 keep the original right/bottom arc
/// order (reply top-right, explain right, ask bottom-right, rewrite bottom);
/// extra items fill the free left arc counter-clockwise.
static func buttonCenters(count: Int) -> [CGPoint] {
    let diagonal = ringRadius * sqrt(0.5)
    let base: [CGPoint] = [
        CGPoint(x: ringRadius, y: 0),
        CGPoint(x: 0, y: -ringRadius),
        CGPoint(x: diagonal, y: diagonal),
        CGPoint(x: diagonal, y: -diagonal),
        CGPoint(x: -ringRadius, y: 0),           // left  (5th: summarize)
        CGPoint(x: 0, y: ringRadius),            // top
        CGPoint(x: -diagonal, y: diagonal),      // top-left
        CGPoint(x: -diagonal, y: -diagonal)      // bottom-left
    ]
    return Array(base.prefix(count))
}
```

Add a `RingItem` struct near `RadialAction`:

```swift
struct RingItem {
    let label: String
    let image: NSImage
    let handler: () -> Void

    static func symbol(_ name: String, label: String, handler: @escaping () -> Void) -> RingItem {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()
        return RingItem(label: label, image: img, handler: handler)
    }
}
```

Change `RadialActionMenuController.init` to take `items: [RingItem]`, store them, and in the build loop (App.swift:9103) `zip(items, RadialMenuLayoutPolicy.buttonCenters(count: items.count))`, use `item.label` for the bubble and `item.image` for the button, and call `item.handler()` in `finish(with:)`. Change `RadialMenuButtonView` to accept an `NSImage` + label instead of a `RadialAction` (set the image on its layer/imageView; keep hover behavior).

- [ ] **Step 4: Update the caller (temporary, keeps behavior identical)**

In `toggleRadialMenu()` (App.swift:7881), build the existing four items explicitly so behavior is unchanged this task:

```swift
let items: [RingItem] = [
    .symbol("text.magnifyingglass", label: "Explain") { [weak self] in
        guard let self, let t = self.selectedText else { return }; self.radialMenu = nil; self.onTranslate?(t) },
    .symbol("pencil.line", label: "Rewrite") { [weak self] in
        guard let self, let t = self.selectedText else { return }; self.radialMenu = nil; self.onRewrite?(t) },
    .symbol("arrowshape.turn.up.left", label: "Reply") { [weak self] in
        guard let self, let t = self.selectedText else { return }; self.radialMenu = nil; self.onSmartReply?(t) },
    .symbol("questionmark.bubble", label: "Ask") { [weak self] in
        guard let self else { return }; self.radialMenu = nil; self.onAsk?() }
]
let menu = RadialActionMenuController(centeredOn: petCenterInScreen(), ignoring: panel, items: items,
    onDismiss: { [weak self] in self?.radialMenu = nil })
```

Delete the now-unused `RadialAction` enum and its `onSelect` param. Keep `RadialMenuLabelPlacement` and `RadialMenuLabelBubbleView`. Update `testEveryActionHasLabelAndSymbol` to instead assert the four symbol names resolve (or delete it).

- [ ] **Step 5: Run tests + build**

Run: `swift test --filter RadialMenuLayoutTests && swift build`
Expected: PASS + build succeeds.

- [ ] **Step 6: Manual smoke + commit**

Verify via `swift run Nugumi`: select text, click pet → 4 actions still work.

```bash
git add Sources/Nugumi/App.swift Tests/NugumiTests/RadialMenuLayoutTests.swift
git commit -m "Generalize radial ring to a dynamic RingItem list"
```

---

### Task 8: Contextual "Summarize KakaoTalk" ring button

**Files:**

- Modify: `Sources/Nugumi/App.swift` (`toggleRadialMenu`, frontmost capture)
- Test: manual (AppKit/AX/icon — not unit-testable)

**Interfaces:**

- Consumes: `ChatArchiveFactory` (Task 5), `RingItem` (Task 7).
- Produces: the ring shows a Kakao-icon item when the captured frontmost app is KakaoTalk; opens even with no selection.

- [ ] **Step 1: Capture the frontmost non-Nugumi app + its window title**

Add to the pet controller (near the `on*` callbacks, App.swift:6845):

```swift
private var capturedFrontApp: NSRunningApplication?
private var capturedWindowTitle: String?
var onSummarize: ((_ archiveOpen: () throws -> ChatArchive, _ appLabel: String, _ windowTitle: String?) -> Void)?

private func captureFrontmostContext() {
    guard let app = NSWorkspace.shared.frontmostApplication,
          app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
    capturedFrontApp = app
    capturedWindowTitle = Self.focusedWindowTitle(pid: app.processIdentifier)
}

static func focusedWindowTitle(pid: pid_t) -> String? {
    let appEl = AXUIElementCreateApplication(pid)
    var win: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &win) == .success,
          let winEl = win, CFGetTypeID(winEl) == AXUIElementGetTypeID() else { return nil }
    var title: CFTypeRef?
    guard AXUIElementCopyAttributeValue(winEl as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
    else { return nil }
    return title as? String
}
```

Call `captureFrontmostContext()` at the same place `selectedText` is captured when the bar/pet appears (App.swift:7658, in the method that sets `self.selectedText = selectedText`).

- [ ] **Step 2: Relax the open gate and append the Kakao item**

In `toggleRadialMenu()` (App.swift:7880), replace the gate:

```swift
let front = capturedFrontApp?.bundleIdentifier
let summarizeOpen = ChatArchiveFactory.archive(forFrontmostBundleID: front)
guard (selectedText != nil || summarizeOpen != nil), !isReadyLockedUntilPanelCloses else { return }
```

After building the four selection items (only when `selectedText != nil`), append:

```swift
if let summarizeOpen, let app = capturedFrontApp {
    let icon = app.icon ?? NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: nil)!
    let title = capturedWindowTitle
    items.append(RingItem(label: "Summarize \(app.localizedName ?? "chat")", image: icon) { [weak self] in
        self?.radialMenu = nil
        self?.presentCountLayer(summarizeOpen: summarizeOpen, appLabel: app.localizedName ?? "chat", windowTitle: title)
    })
}
```

(`presentCountLayer` is added in Task 9. Make `items` a `var` built conditionally.)

- [ ] **Step 3: Build**

Run: `swift build`
Expected: succeeds (a stub `presentCountLayer` may be needed — add an empty one to compile, filled in Task 9).

- [ ] **Step 4: Manual smoke + commit**

With KakaoTalk frontmost, click the pet (no selection needed) → the ring appears with a KakaoTalk-icon button; hover shows "Summarize KakaoTalk". With a non-messenger frontmost and no selection, the ring does not open.

```bash
git add Sources/Nugumi/App.swift
git commit -m "Show a contextual KakaoTalk summarize button in the ring"
```

---

### Task 9: Second ring layer — message count

**Files:**

- Modify: `Sources/Nugumi/App.swift` (pet controller)
- Test: manual

**Interfaces:**

- Produces: `presentCountLayer(summarizeOpen:appLabel:windowTitle:)` — opens a fresh ring of `50/100/200/Max` items; each fires `onSummarize` with the chosen count.
- Consumes: `RadialActionMenuController` (Task 7), `onSummarize` (Task 8).

- [ ] **Step 1: Implement the count layer**

Add to the pet controller:

```swift
private static let countChoices: [(String, Int)] = [("50", 50), ("100", 100), ("200", 200), ("Max", 1000)]

private func presentCountLayer(summarizeOpen: @escaping () throws -> ChatArchive, appLabel: String, windowTitle: String?) {
    let items: [RingItem] = Self.countChoices.map { (label, n) in
        RingItem(label: label, image: Self.countBadge(label)) { [weak self] in
            self?.radialMenu = nil
            self?.onSummarize?(summarizeOpen, appLabel, windowTitle)  // count passed via closure capture below
        }
    }
    // Bind the count into onSummarize by wrapping per item:
    let bound: [RingItem] = zip(Self.countChoices, items).map { choice, item in
        RingItem(label: item.label, image: item.image) { [weak self] in
            self?.radialMenu = nil
            self?.onSummarize.map { $0(summarizeOpen, appLabel, windowTitle) }  // replaced below
            _ = choice
        }
    }
    _ = bound
    let menu = RadialActionMenuController(centeredOn: petCenterInScreen(), ignoring: panel, items: items,
        onDismiss: { [weak self] in self?.radialMenu = nil })
    radialMenu = menu
    menu.show()
}

private static func countBadge(_ text: String) -> NSImage {
    let size = NSSize(width: 24, height: 24)
    let img = NSImage(size: size)
    img.lockFocus()
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: text.count > 2 ? 9 : 11, weight: .semibold),
        .foregroundColor: NSColor.labelColor
    ]
    let s = text as NSString
    let r = s.boundingRect(with: size, options: [], attributes: attrs)
    s.draw(at: NSPoint(x: (size.width - r.width) / 2, y: (size.height - r.height) / 2), withAttributes: attrs)
    img.unlockFocus()
    return img
}
```

Fix the count-binding: change `onSummarize` to take the count, and pass `n`:

```swift
var onSummarize: ((_ archiveOpen: () throws -> ChatArchive, _ appLabel: String, _ windowTitle: String?, _ count: Int) -> Void)?
```

and in `presentCountLayer` build items directly:

```swift
let items: [RingItem] = Self.countChoices.map { (label, n) in
    RingItem(label: label, image: Self.countBadge(label)) { [weak self] in
        self?.radialMenu = nil
        self?.onSummarize?(summarizeOpen, appLabel, windowTitle, n)
    }
}
```

(Delete the `bound` scaffolding — it was only to show the capture; the direct form above is the implementation.)

- [ ] **Step 2: Build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3: Manual smoke + commit**

KakaoTalk frontmost → pet → Kakao button → ring morphs to `50/100/200/Max`; picking one dismisses the ring (summary wiring lands in Task 10).

```bash
git add Sources/Nugumi/App.swift
git commit -m "Add message-count second ring layer"
```

---

### Task 10: Wire onSummarize end-to-end

**Files:**

- Modify: `Sources/Nugumi/App.swift` (wherever the pet controller's `on*` callbacks are assigned — the app coordinator; search for `onSmartReply =`)
- Test: manual

**Interfaces:**

- Consumes: `onSummarize` (Task 9), `KakaoArchive`, `ChatTranscript` (Task 6), the existing summary/translate presentation used by `.smartReply`.
- Produces: full flow — open archive, pick chat by window title (fallback most-recent), fetch, format, run `.summarizeChat` through the current backend, show in the result panel.

- [ ] **Step 1: Add the chat-matching helper**

In `ChatArchive.swift`:

```swift
extension ChatArchive {
    /// Best-effort: the chat whose title matches the frontmost window title,
    /// else the most-recently-active chat. Returns (chat, matchedByTitle).
    func chat(forWindowTitle title: String?, fallbackLimit: Int = 30) throws -> (ChatSummary, Bool) {
        let chats = try recentChats(limit: fallbackLimit)
        guard !chats.isEmpty else { throw ChatArchiveError.emptyChat }
        if let title, !title.isEmpty {
            let needle = title.trimmingCharacters(in: .whitespaces).lowercased()
            let hit = chats.first { needle.contains($0.title.lowercased()) || $0.title.lowercased().contains(needle) }
            if let hit { return (hit, true) }
        }
        return (chats[0], false)   // most-recent fallback
    }
}
```

- [ ] **Step 2: Assign `onSummarize` where the other callbacks are wired**

Find where `petController.onSmartReply = { ... }` is set and add alongside:

```swift
petController.onSummarize = { [weak self] open, appLabel, windowTitle, count in
    guard let self else { return }
    Task { @MainActor in
        do {
            let archive = try open()
            let (chat, matched) = try archive.chat(forWindowTitle: windowTitle)
            let lines = try archive.messages(chatID: chat.id, limit: count)
            let transcript = ChatTranscript.format(lines, maxMessages: count, tokenBudget: 12_000)
            let header = matched ? chat.title : "\(chat.title) (most recent chat)"
            self.presentSummary(source: transcript, title: header)
        } catch {
            self.presentSummary(source: "", title: nil, error: "\(error)")
        }
    }
}
```

- [ ] **Step 3: Add `presentSummary` reusing the existing panel path**

Model it on the `.smartReply` presentation (the code invoked by `onSmartReply` → `translate(...)` → result panel). Add a method that calls the existing `translate(_:mode:...)` entry point with `mode: .summarizeChat` and the transcript as the source text, and on the error path shows the message string directly in the panel via the same loading/result controller. Use the existing `translate` function signature at App.swift:3101 (`translate(_ text:mode:...)`); pass the transcript as `text` and `.summarizeChat` as `mode`. For the error path, call the panel's result setter with the error string and no loading.

- [ ] **Step 4: Build + manual verify**

Run: `swift build`
Then in a **built .app** (`bash Scripts/build-app-bundle.sh` → run `dist/Nugumi.app`, launched by the user per the TCC rule): KakaoTalk frontmost, open a chat, pet → Kakao button → 100 → a summary of that chat appears in the panel. Revoke FDA → the panel shows "Grant Full Disk Access to summarize chats." and the app stays alive.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nugumi/App.swift Sources/Nugumi/ChatArchive.swift
git commit -m "Wire KakaoTalk chat summary end-to-end"
```

---

### Task 11: Full Disk Access onboarding step

**Files:**

- Modify: `Sources/Nugumi/Onboarding.swift`
- Test: `Tests/NugumiTests/FullDiskAccessProbeTests.swift`

**Interfaces:**

- Produces: `enum FullDiskAccessProbe { static func isGranted() -> Bool }` (attempts to list the KakaoTalk container), a `PermissionKind.fullDiskAccess` case, and an `openFullDiskAccessSettings()` deep link.
- Consumes: existing `PermissionKind` / `refreshPermissions()` machinery.

- [ ] **Step 1: Write the probe test**

`Tests/NugumiTests/FullDiskAccessProbeTests.swift`:

```swift
import XCTest
@testable import Nugumi

final class FullDiskAccessProbeTests: XCTestCase {
    func testProbeReturnsBoolWithoutThrowing() {
        // Can't assert a fixed value (depends on machine grant state), but the
        // probe must never crash and must return deterministically twice.
        let a = FullDiskAccessProbe.isGranted()
        let b = FullDiskAccessProbe.isGranted()
        XCTAssertEqual(a, b)
    }
}
```

- [ ] **Step 2: Implement the probe**

In `Onboarding.swift` (or `ChatArchive.swift` if cleaner; keep it near FDA UI):

```swift
enum FullDiskAccessProbe {
    /// No macOS API reports FDA. Probe by listing the KakaoTalk container:
    /// success ⇒ we can read it; failure/empty-with-error ⇒ FDA missing.
    static func isGranted() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let container = "\(home)/Library/Containers/com.kakao.KakaoTalkMac/Data/Library/Application Support/com.kakao.KakaoTalkMac"
        // If KakaoTalk isn't installed, fall back to a generic TCC-gated path.
        let probe = FileManager.default.fileExists(atPath: container)
            ? container
            : "\(home)/Library/Application Support/com.apple.TCC"
        return (try? FileManager.default.contentsOfDirectory(atPath: probe)) != nil
    }
}
```

- [ ] **Step 3: Add the permission step + deep link**

Add `case fullDiskAccess` to `PermissionKind` (Onboarding.swift:8), a stored `@Published var fdaGranted = FullDiskAccessProbe.isGranted()`, refresh it in `refreshPermissions()`, include it in `nextPermission`, and:

```swift
func openFullDiskAccessSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
        NSWorkspace.shared.open(url)
    }
}
```

Add the row's copy: title "Full Disk Access", subtitle "Read your KakaoTalk chat history to summarize it." Wire its button to `openFullDiskAccessSettings()` (mirror the accessibility row). Do **not** block first-run completion on FDA — it is optional, unlike AX/Screen Recording (auto-advance logic at Onboarding.swift:249 stays keyed on `ax && scr` only).

- [ ] **Step 4: Run tests + build**

Run: `swift test --filter FullDiskAccessProbeTests && swift build`
Expected: PASS + build.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nugumi/Onboarding.swift Tests/NugumiTests/FullDiskAccessProbeTests.swift
git commit -m "Add optional Full Disk Access onboarding step"
```

---

### Task 12: Cloud-backend privacy consent + release-bundle verification

**Files:**

- Modify: `Sources/Nugumi/App.swift` (consent gate before the first cloud summary)
- Test: `Tests/NugumiTests/SummaryConsentTests.swift`

**Interfaces:**

- Produces: `enum SummaryConsent { static var accepted: Bool { get set } }` (UserDefaults-backed), consulted in `onSummarize` when the active backend is a cloud provider.
- Consumes: the existing backend/provider type used to tell local Ollama from cloud.

- [ ] **Step 1: Write the consent-flag test**

`Tests/NugumiTests/SummaryConsentTests.swift`:

```swift
import XCTest
@testable import Nugumi

final class SummaryConsentTests: XCTestCase {
    func testDefaultsRoundTrip() {
        let key = "summaryCloudConsent.test"
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(SummaryConsent.value(forKey: key))
        SummaryConsent.set(true, forKey: key)
        XCTAssertTrue(SummaryConsent.value(forKey: key))
        UserDefaults.standard.removeObject(forKey: key)
    }
}
```

- [ ] **Step 2: Implement the flag + gate**

In `App.swift`:

```swift
enum SummaryConsent {
    private static let key = "summary.cloudConsentAccepted"
    static var accepted: Bool {
        get { value(forKey: key) }
        set { set(newValue, forKey: key) }
    }
    static func value(forKey k: String) -> Bool { UserDefaults.standard.bool(forKey: k) }
    static func set(_ v: Bool, forKey k: String) { UserDefaults.standard.set(v, forKey: k) }
}
```

In the `onSummarize` handler (Task 10), before formatting/sending: if the current backend is a cloud provider (not Ollama) and `!SummaryConsent.accepted`, show a modal `NSAlert` ("Chat contents, including other people's messages, will be sent to your selected AI provider. Continue? / Use a local model instead"). On accept set `SummaryConsent.accepted = true` and proceed; on cancel abort silently.

- [ ] **Step 3: Verify the release bundle links SQLCipher statically**

Run:

```bash
bash Scripts/build-app-bundle.sh
otool -L dist/Nugumi.app/Contents/MacOS/Nugumi | grep -i sqlcipher || echo "OK: no external SQLCipher dylib (static)"
```

Expected: prints `OK: no external SQLCipher dylib` (the codec is compiled into the binary; a dangling `@rpath` sqlcipher dylib would mean the C target linked dynamically — fix the target if so).

- [ ] **Step 4: Run tests + full manual pass**

Run: `swift test`
Expected: all green. Then the manual matrix from the spec's Testing section against `dist/Nugumi.app`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nugumi/App.swift Tests/NugumiTests/SummaryConsentTests.swift
git commit -m "Gate cloud chat summaries behind one-time consent"
```

---

## Self-Review

**Spec coverage:** KakaoTalk-only scope (Tasks 1–5) ✓ · window-title chat detection (Task 10 helper) ✓ · contextual ring button with app icon (Task 8) ✓ · second-layer count picker `50/100/200/Max` (Task 9) ✓ · `.summarizeChat` mode + target-language summary (Task 6/10) ✓ · SQLCipher CommonCrypto static target (Task 1) ✓ · Full Disk Access probe + onboarding (Task 11) ✓ · never-crash error mapping (`ChatArchiveError` Task 2, error path Task 10) ✓ · privacy consent (Task 12) ✓ · `ChatArchive` protocol for Telegram drop-in (Task 5) ✓.

**Placeholder scan:** the only non-code steps are the manual crypto KAT capture (Task 2 Step 5) and `presentSummary` reuse (Task 10 Step 3), both pointing at concrete existing code (`translate(_:mode:)` at App.swift:3101, the `.smartReply` panel path) — acceptable, not placeholders.

**Type consistency:** `SQLValue`, `ChatSummary`, `ChatLine`, `ChatArchive`, `RingItem`, `onSummarize(open,appLabel,windowTitle,count)` used consistently across tasks; `buttonCenters(count:)` renamed everywhere it's called (Tasks 7, and the layout test).

**Known soft spots to watch during execution:**

- Task 7/8/9 touch live AppKit ring code that can only be verified by running the app — budget manual time.
- `presentSummary` (Task 10) intentionally defers to the existing panel API rather than reinventing it; read that code before writing the step.
- KakaoTalk `message` plaintext assumption — if a real DB yields garbled rows, skip undecodable rows (already `message IS NOT NULL AND <> ''` filtered) rather than crashing.
