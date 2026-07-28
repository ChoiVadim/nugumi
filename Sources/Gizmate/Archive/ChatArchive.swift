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
    case telegramLocked

    var description: String {
        switch self {
        case .fullDiskAccessMissing: return "Grant Full Disk Access to summarize chats."
        case .kakaoUserIdNotFound:   return "Couldn't read KakaoTalk account data."
        case .databaseNotFound:      return "Couldn't find the chat database."
        case .databaseOpenFailed:    return "Couldn't open the chat database (it may have updated)."
        case .emptyChat:             return "No messages to summarize in this chat."
        case .chatNotMatched:        return "Couldn't tell which chat is open."
        case .telegramLocked:        return "Couldn't unlock Telegram data — a Telegram passcode may be set."
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

enum SQLValue: Equatable { case int(Int64); case text(String); case blob([UInt8]); case null }

/// A bound parameter — int for Kakao's `chatId`/limits, blob for Telegram's
/// 20-byte message-key range bounds.
enum SQLBind { case int(Int64); case blob([UInt8]) }

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

    /// Telegram-macOS Postbox: SQLCipher v4 with a 32-byte plaintext header, so
    /// the salt can't be read from the file — the raw key and salt are both
    /// supplied, `key` first (it initializes the codec) then the header size.
    /// Opened READ-ONLY in place: WAL mode lets us read concurrently with the
    /// running app and see its latest committed state. (Copying the live,
    /// actively-appended `-wal` raced Telegram and produced a torn snapshot
    /// SQLCipher rejected — surfacing as a spurious "locked" error.)
    init?(telegramDB path: String, keyHex: String, saltHex: String) {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); db = nil; return nil
        }
        _ = exec("PRAGMA key=\"x'\(keyHex)\(saltHex)'\"")
        _ = exec("PRAGMA cipher_plaintext_header_size = 32")
        guard exec("SELECT count(*) FROM sqlite_master") else { sqlite3_close(db); db = nil; return nil }
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    func query(_ sql: String, _ binds: [Int64] = []) -> [[SQLValue]] {
        query(sql, binds.map { SQLBind.int($0) })
    }

    func query(_ sql: String, _ binds: [SQLBind]) -> [[SQLValue]] {
        // SQLite must copy blob binds — the source [UInt8] is transient.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch b {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .blob(let bytes): sqlite3_bind_blob(stmt, idx, bytes, Int32(bytes.count), transient)
            }
        }
        var rows: [[SQLValue]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let n = sqlite3_column_count(stmt)
            var row: [SQLValue] = []
            for c in 0..<n {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(stmt, c)))
                case SQLITE_NULL:    row.append(.null)
                case SQLITE_BLOB:
                    if let p = sqlite3_column_blob(stmt, c) {
                        let len = Int(sqlite3_column_bytes(stmt, c))
                        row.append(.blob([UInt8](UnsafeRawBufferPointer(start: p, count: len))))
                    } else { row.append(.blob([])) }
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
        // `AlertKakaoIDsList` holds account/friend ids (kakaocli's candidate source).
        if let list = prefs["AlertKakaoIDsList"] as? [Any] {
            for item in list {
                if let n = item as? Int { add(n) }
                else if let s = item as? String, let n = Int(s) { add(n) }
            }
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

    /// The empty-account SHA-512 (`sha512` of no active account) — never brute-force it.
    private static let emptyAccountRevisionHash =
        "31bca02094eb78126a517b206a88c73cfa9ec6f704c7030d18212cace820f025f00bf0ea68dbf3f3a5436ca63b53bf7bf80ad8d5de7d8359d0b7fed9dbc3ab99"

    /// Newer KakaoTalk stores the logged-in account's own id ONLY as a SHA-512
    /// hash in a `DESIGNATEDFRIENDSREVISION:<sha512hex>` preference key. Recover
    /// it by brute-forcing the preimage (ids are < 1e9), matching kakaocli.
    /// Cached in UserDefaults per-hash so the multi-second search runs at most
    /// once per account.
    static func recoveredIDs(in prefs: [String: Any]) -> [Int] {
        let prefix = "DESIGNATEDFRIENDSREVISION:"
        var ids: [Int] = []
        for key in prefs.keys where key.hasPrefix(prefix) {
            let hash = String(key.dropFirst(prefix.count)).lowercased()
            guard hash.count == 128, hash != emptyAccountRevisionHash else { continue }
            let cacheKey = "gizmate.kakao.uid.\(hash)"
            if let cached = UserDefaults.standard.object(forKey: cacheKey) as? Int {
                if cached > 0, !ids.contains(cached) { ids.append(cached) }
                continue
            }
            if let id = bruteForceSHA512Preimage(targetHex: hash) {
                UserDefaults.standard.set(id, forKey: cacheKey)
                if !ids.contains(id) { ids.append(id) }
            }
        }
        return ids
    }

    /// Find `i` in `0..<maxId` where `sha512(decimal(i)) == targetHex`.
    /// Multi-threaded, allocation-free inner loop; early-exits once found.
    static func bruteForceSHA512Preimage(targetHex: String, maxId: Int = 1_000_000_000) -> Int? {
        guard targetHex.count == 128 else { return nil }
        let chars = Array(targetHex.utf8)
        func hexVal(_ c: UInt8) -> Int? {
            switch c {
            case 0x30...0x39: return Int(c - 0x30)
            case 0x61...0x66: return Int(c - 0x61 + 10)
            case 0x41...0x46: return Int(c - 0x41 + 10)
            default: return nil
            }
        }
        let target = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        defer { target.deallocate() }
        for i in 0..<64 {
            guard let hi = hexVal(chars[i * 2]), let lo = hexVal(chars[i * 2 + 1]) else { return nil }
            target[i] = UInt8(hi << 4 | lo)
        }
        // Split the range into small blocks handed out by GCD across all cores,
        // so the block that contains the answer is reached quickly (contiguous
        // per-core chunks would make the finding core scan its whole chunk alone)
        // and pending blocks early-exit the moment any core finds it. The inner
        // loop uses raw pointers — no per-iteration array/closure overhead.
        let blockSize = 1_000_000
        let numBlocks = (maxId + blockSize - 1) / blockSize
        let lock = NSLock()
        var found: Int?
        DispatchQueue.concurrentPerform(iterations: numBlocks) { b in
            lock.lock(); let doneEarly = found != nil; lock.unlock()
            if doneEarly { return }
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 20)
            let dig = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
            defer { buf.deallocate(); dig.deallocate() }
            let start = b * blockSize
            let end = min(start + blockSize, maxId)
            var i = start
            while i < end {
                var len: Int
                if i == 0 { buf[0] = 48; len = 1 }
                else {
                    var x = i, d = 0
                    while x > 0 { x /= 10; d += 1 }
                    len = d; x = i; var j = d - 1
                    while x > 0 { buf[j] = UInt8(48 + x % 10); x /= 10; j -= 1 }
                }
                CC_SHA512(buf, CC_LONG(len), dig)
                if memcmp(dig, target, 64) == 0 {
                    lock.lock(); if found == nil { found = i }; lock.unlock()
                    return
                }
                i += 1
            }
        }
        return found
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

    /// Merged contents of KakaoTalk's preference plists — the source for
    /// candidate/recovered user ids.
    private static func gatherPrefs() -> [String: Any] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
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
        return prefs
    }

    /// Runs the (UserDefaults-cached) SHA-512 userId recovery ahead of time so
    /// the first summary isn't blocked on the multi-second brute force. Safe to
    /// call repeatedly and off the main thread — a cache hit returns instantly.
    static func prewarmUserId() {
        _ = KakaoUserID.recoveredIDs(in: gatherPrefs())
    }

    static func open() throws -> KakaoArchive {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let container = "\(home)/Library/Containers/com.kakao.KakaoTalkMac/Data/Library/Application Support/com.kakao.KakaoTalkMac"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: container) else {
            throw ChatArchiveError.fullDiskAccessMissing
        }
        let uuid = try KakaoKeyDerivation.platformUUID()

        let prefs = gatherPrefs()
        var candidates = KakaoUserID.candidates(from: prefs)
        // Newer KakaoTalk hides the own id behind a SHA-512 hash — recover it.
        candidates += KakaoUserID.recoveredIDs(in: prefs).filter { !candidates.contains($0) }
        guard !candidates.isEmpty else { throw ChatArchiveError.kakaoUserIdNotFound }

        // Primary path: a candidate's derived filename exists AND its key opens the DB.
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

        // Fallback (matches kakaocli): the derived filename may not match on
        // newer builds — scan the container for the 78-hex-char DB file, then
        // try each candidate's key against that one file.
        if let hex78 = try? NSRegularExpression(pattern: "^[0-9a-f]{78}(\\.db)?$"),
           let dbFile = files.first(where: {
               hex78.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
           }) {
            let dbPath = "\(container)/\(dbFile)"
            for userId in candidates {
                let key = KakaoKeyDerivation.secureKey(userId: userId, uuid: uuid)
                if let db = SQLCipherDatabase(path: dbPath, passphrase: key) {
                    return KakaoArchive(db: db)
                }
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
        switch id {
        case "com.kakao.KakaoTalkMac":  return { try KakaoArchive.open() }
        case "ru.keepcoder.Telegram":   return { try TelegramArchive.open() }
        default:                        return nil
        }
    }
}

extension ChatArchive {
    /// Identifies the chat on screen. `ocrCandidates` are strings read from the
    /// messenger's on-screen header (Telegram, whose window title is useless and
    /// whose DB has no reliable open-chat pointer) — fuzzy-matched against chat
    /// names to survive OCR noise. Falls back to window-title matching (Kakao),
    /// then the most-recently-active chat. Returns (chat, matchedConfidently).
    func chat(
        forWindowTitle title: String?,
        ocrCandidates: [String] = [],
        fallbackLimit: Int = 30
    ) throws -> (ChatSummary, Bool) {
        let chats = try recentChats(limit: fallbackLimit)
        guard !chats.isEmpty else { throw ChatArchiveError.emptyChat }
        if let hit = ChatNameMatch.best(candidates: ocrCandidates, in: chats) {
            return (hit, true)
        }
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

/// Fuzzy-matches OCR'd header strings to a chat name. OCR of clear UI text is
/// close but not exact ("LeviosaAI" → "LeviosaAl"), and the candidate set is
/// small (recent chats), so a normalized edit-distance best-match is both
/// robust and cheap. The threshold rejects header junk ("8 members", clock).
enum ChatNameMatch {
    static func best(candidates: [String], in chats: [ChatSummary], threshold: Double = 0.6) -> ChatSummary? {
        var bestChat: ChatSummary?
        var bestScore = threshold
        for raw in candidates {
            let cand = normalize(raw)
            guard cand.count >= 2 else { continue }
            for chat in chats {
                let name = normalize(chat.title)
                guard name.count >= 2 else { continue }
                let score = similarity(cand, name)
                if score > bestScore { bestScore = score; bestChat = chat }
            }
        }
        return bestChat
    }

    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " "
        }).trimmingCharacters(in: .whitespaces)
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        if a.count >= 4, b.count >= 4, (a.contains(b) || b.contains(a)) { return 0.9 }
        let dist = levenshtein(Array(a), Array(b))
        let longer = max(a.count, b.count)
        return longer == 0 ? 0 : 1 - Double(dist) / Double(longer)
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
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
