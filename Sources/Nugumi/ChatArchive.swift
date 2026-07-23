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

enum SQLValue: Equatable { case int(Int64); case text(String); case null }

final class SQLCipherDatabase {
    private var db: OpaquePointer?

    init?(path: String, passphrase: String?) {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); db = nil; return nil
        }
        if let passphrase {
            // Try SQLCipher compatibility 3 then 4 (older vs newer KakaoTalk builds).
            var opened = false
            for compat in [3, 4] {
                _ = exec("PRAGMA cipher_default_compatibility = \(compat)")
                _ = exec("PRAGMA key='\(passphrase)'")
                if exec("SELECT count(*) FROM sqlite_master") { opened = true; break }
            }
            guard opened else { sqlite3_close(db); db = nil; return nil }
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
        // Swift disallows an unparenthesized trailing closure directly in a for-in
        // sequence expression, so the .filter/.map chain is hoisted out first.
        let extraPlists = ((try? FileManager.default.contentsOfDirectory(atPath: prefDir)) ?? [])
            .filter { $0.hasPrefix("com.kakao.KakaoTalkMac.") && $0.hasSuffix(".plist") }
            .map { "\(prefDir)/\($0)" }
        for path in [
            "\(home)/Library/Preferences/com.kakao.KakaoTalkMac.plist",
            "\(prefDir)/com.kakao.KakaoTalkMac.plist"
        ] + extraPlists {
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

extension ChatArchive {
    /// The chat whose title matches the frontmost window title, else the most
    /// recently-active chat. Returns (chat, matchedByTitle).
    func chat(forWindowTitle title: String?, fallbackLimit: Int = 30) throws -> (ChatSummary, Bool) {
        let chats = try recentChats(limit: fallbackLimit)
        guard !chats.isEmpty else { throw ChatArchiveError.emptyChat }
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            let needle = title.trimmingCharacters(in: .whitespaces).lowercased()
            if let hit = chats.first(where: {
                let t = $0.title.lowercased()
                return !t.isEmpty && (needle.contains(t) || t.contains(needle))
            }) { return (hit, true) }
        }
        return (chats[0], false)
    }
}

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
