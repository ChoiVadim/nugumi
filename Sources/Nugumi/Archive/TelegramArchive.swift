import Foundation
import CommonCrypto
import ScreenCaptureKit
import Vision

// Telegram-for-macOS (ru.keepcoder.Telegram) stores its chat history in a
// SQLCipher-v4 "Postbox" database. Unlike KakaoTalk, message bodies are not
// plaintext SQL — they're a bespoke keyed-object binary serialization. This
// file is a text-only port of that reader: enough to pull message text +
// author + timestamp, and peer display names. Anything it can't parse is
// skipped rather than crashed. Ported/verified against telecrawl's Go reader.

enum TelegramKey {
    /// The Postbox SQLCipher key lives in `.tempkeyEncrypted`, AES-256-CBC
    /// encrypted under SHA-512 of the local passcode. With no user passcode set
    /// (the common case) the passcode is the constant `"no-matter-key"`. The
    /// 48-byte plaintext is the raw 32-byte key followed by the 16-byte salt.
    /// (No checksum verification — the SQLCipher open itself validates the key,
    /// so a user-set passcode surfaces as a failed open, not a bad checksum.)
    static func derive(tempkey: Data) -> (keyHex: String, saltHex: String)? {
        guard tempkey.count >= 48 else { return nil }
        let pw = Data("no-matter-key".utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        pw.withUnsafeBytes { _ = CC_SHA512($0.baseAddress, CC_LONG(pw.count), &digest) }
        let aesKey = Array(digest[0..<32])
        let iv = Array(digest[48..<64])
        guard let plain = aesCBCDecrypt([UInt8](tempkey), key: aesKey, iv: iv), plain.count >= 48
        else { return nil }
        return (hex(Array(plain[0..<32])), hex(Array(plain[32..<48])))
    }

    private static func aesCBCDecrypt(_ data: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0), // CBC, no padding
            key, key.count, iv,
            data, data.count,
            &out, out.count, &moved
        )
        guard status == kCCSuccess else { return nil }
        return Array(out[0..<moved])
    }

    static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    /// Message keys in table `t7` are 20 bytes, big-endian:
    /// peerID(8) | namespace(4) | timestamp(4) | messageID(4).
    static func peerID(fromKey k: [UInt8]) -> Int64? {
        guard k.count >= 20 else { return nil }
        var u: UInt64 = 0
        for i in 0..<8 { u = (u << 8) | UInt64(k[i]) }
        return Int64(bitPattern: u)
    }

    static func timestamp(fromKey k: [UInt8]) -> Int32 {
        guard k.count >= 20 else { return 0 }
        var u: UInt32 = 0
        for i in 12..<16 { u = (u << 8) | UInt32(k[i]) }
        return Int32(bitPattern: u)
    }

    /// The 8-byte big-endian peerID prefix, for `t7` key range scans.
    static func be8(_ v: Int64) -> [UInt8] {
        let u = UInt64(bitPattern: v)
        return (0..<8).map { UInt8((u >> (8 * (7 - $0))) & 0xFF) }
    }
}

enum PostboxError: Error { case short, unknownType(UInt8) }

/// Little-endian byte reader over a Postbox payload.
final class PostboxReader {
    private let b: [UInt8]
    private(set) var off = 0
    init(_ bytes: [UInt8]) { b = bytes }
    var isAtEnd: Bool { off >= b.count }

    func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, off + n <= b.count else { throw PostboxError.short }
        defer { off += n }
        return b[off..<off + n]
    }
    func u8() throws -> UInt8 { try take(1).first! }
    func i8() throws -> Int8 { Int8(bitPattern: try u8()) }
    func u32() throws -> UInt32 {
        var v: UInt32 = 0
        for (i, byte) in try take(4).enumerated() { v |= UInt32(byte) << (8 * i) }
        return v
    }
    func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    func u64() throws -> UInt64 {
        var v: UInt64 = 0
        for (i, byte) in try take(8).enumerated() { v |= UInt64(byte) << (8 * i) }
        return v
    }
    func i64() throws -> Int64 { Int64(bitPattern: try u64()) }
    func f64() throws -> Double { Double(bitPattern: try u64()) }
    func bytes() throws -> [UInt8] {
        let n = try i32()
        guard n >= 0 else { throw PostboxError.short }
        return Array(try take(Int(n)))
    }
    func string() throws -> String { String(decoding: try bytes(), as: UTF8.self) }
    func shortString() throws -> String {
        let n = Int(try u8())
        return String(decoding: try take(n), as: UTF8.self)
    }
}

enum Postbox {
    /// Decodes a keyed-object payload (table `t2` peers, `t0` state) into a
    /// dictionary. Values follow a tagged union of 14 types; the top level is a
    /// flat set of entries whose `"_"` key holds the root object.
    static func decodeEntries(_ bytes: [UInt8]) throws -> [String: Any] {
        let r = PostboxReader(bytes)
        var out: [String: Any] = [:]
        while !r.isAtEnd {
            // Tolerant: keep the fields decoded so far and stop at the first one
            // we can't parse (an unknown value type or a truncated tail). The
            // fields we care about — peer names, `ts` — come early, so a weird
            // trailing field must not discard the whole record.
            guard let key = try? r.shortString() else { break }
            do {
                if let val = try readValue(r) { out[key] = val }
            } catch { break }
        }
        return out
    }

    private static func readObject(_ r: PostboxReader) throws -> [String: Any] {
        _ = try r.i32()                       // typeHash (unused here)
        let size = try r.i32()
        guard size >= 0 else { throw PostboxError.short }
        return try decodeEntries(Array(try r.take(Int(size))))
    }

    private static func count(_ r: PostboxReader) throws -> Int {
        let n = try r.i32()
        guard n >= 0 else { throw PostboxError.short }
        return Int(n)
    }

    private static func readValue(_ r: PostboxReader) throws -> Any? {
        let t = try r.u8()
        switch t {
        case 0:  return Int64(try r.i32())
        case 1:  return try r.i64()
        case 2:  return try r.u8() != 0
        case 3:  return try r.f64()
        case 4:  return try r.string()
        case 5:  return try readObject(r)
        case 6:  return try (0..<count(r)).map { _ in Int64(try r.i32()) }
        case 7:  return try (0..<count(r)).map { _ in try r.i64() }
        case 8:  return try (0..<count(r)).map { _ in try readObject(r) }
        case 9:  return try (0..<count(r)).map { _ in [try readObject(r), try readObject(r)] }
        case 10: return try r.bytes()
        case 11: return nil
        case 12: return try (0..<count(r)).map { _ in try r.string() }
        case 13: return try (0..<count(r)).map { _ in try r.bytes() }
        default: throw PostboxError.unknownType(t)
        }
    }

    /// Human-readable name for a decoded peer record: full name, else title
    /// (groups/channels), else @username.
    static func peerDisplay(_ entries: [String: Any]) -> String {
        let p = (entries["_"] as? [String: Any]) ?? entries
        func s(_ k: String) -> String { (p[k] as? String)?.trimmingCharacters(in: .whitespaces) ?? "" }
        let fn = s("fn"), ln = s("ln")
        if !fn.isEmpty || !ln.isEmpty { return (fn + " " + ln).trimmingCharacters(in: .whitespaces) }
        if !s("t").isEmpty { return s("t") }
        if !s("un").isEmpty { return "@" + s("un") }
        return ""
    }

    /// A `t7` message record: a fixed flag-driven layout (NOT the keyed-object
    /// format). Reads only up to the text + author fields — media, attributes
    /// and referenced resources after the text are intentionally left unread.
    /// Returns nil for an unrecognized version or a truncated payload.
    static func readMessage(_ bytes: [UInt8]) -> (text: String, author: Int64?)? {
        let r = PostboxReader(bytes)
        do {
            guard try r.i8() == 0 else { return nil }   // version gate
            _ = try r.u32(); _ = try r.u32()
            let df = try r.u8()
            if df & (1 << 0) != 0 { _ = try r.i64() }
            if df & (1 << 1) != 0 { _ = try r.u32() }
            if df & (1 << 2) != 0 { _ = try r.i64() }
            if df & (1 << 3) != 0 { _ = try r.u32() }
            if df & (1 << 4) != 0 { _ = try r.u32() }
            if df & (1 << 5) != 0 { _ = try r.i64(); _ = try r.i64() }
            _ = try r.u32()                              // flags
            _ = try r.u32()                              // tags
            try readForwardInfo(r)
            var author: Int64?
            if try r.i8() == 1 { author = try r.i64() }
            return (try r.string(), author)
        } catch { return nil }
    }

    private static func readForwardInfo(_ r: PostboxReader) throws {
        let flags = try r.i8()
        if flags == 0 { return }
        _ = try r.i64(); _ = try r.i32()
        if flags & (1 << 1) != 0 { _ = try r.i64() }
        if flags & (1 << 2) != 0 { _ = try r.i64(); _ = try r.i32(); _ = try r.i32() }
        if flags & (1 << 3) != 0 { _ = try r.string() }
        if flags & (1 << 4) != 0 { _ = try r.string() }
        if flags & (1 << 5) != 0 { _ = try r.i32() }
    }
}

final class TelegramArchive: ChatArchive {
    let appLabel = "Telegram"
    private let db: SQLCipherDatabase
    private let peerNames: [Int64: String]
    private let selfPeerID: Int64?

    private init(db: SQLCipherDatabase, peerNames: [Int64: String], selfPeerID: Int64?) {
        self.db = db
        self.peerNames = peerNames
        self.selfPeerID = selfPeerID
    }

    // The macOS app team-prefixed group container. Team ID is stable for the
    // App Store build of Telegram-for-macOS.
    private static let container = "Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/stable"

    static func open() throws -> TelegramArchive {
        let fm = FileManager.default
        let stable = fm.homeDirectoryForCurrentUser.appendingPathComponent(container)
        guard let entries = try? fm.contentsOfDirectory(atPath: stable.path) else {
            throw ChatArchiveError.fullDiskAccessMissing
        }

        let tempkeyURL = stable.appendingPathComponent(".tempkeyEncrypted")
        guard let tk = try? Data(contentsOf: tempkeyURL),
              let (keyHex, saltHex) = TelegramKey.derive(tempkey: tk) else {
            throw ChatArchiveError.databaseNotFound
        }

        // Pick the most recently written account (Telegram supports several).
        var newest: (dbFile: URL, mtime: Date)?
        for name in entries where name.hasPrefix("account-") {
            let dbFile = stable.appendingPathComponent(name)
                .appendingPathComponent("postbox/db/db_sqlite")
            guard let attrs = try? fm.attributesOfItem(atPath: dbFile.path),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            if newest == nil || mtime > newest!.mtime { newest = (dbFile, mtime) }
        }
        guard let dbFile = newest?.dbFile else { throw ChatArchiveError.databaseNotFound }

        // Open the live DB in place, read-only — no copy. WAL mode allows a
        // concurrent reader, and we never write, so Telegram's files are safe.
        guard let db = SQLCipherDatabase(telegramDB: dbFile.path, keyHex: keyHex, saltHex: saltHex) else {
            throw ChatArchiveError.telegramLocked
        }

        return TelegramArchive(
            db: db,
            peerNames: loadPeerNames(db),
            selfPeerID: loadSelfPeerID(db)
        )
    }

    private static func loadPeerNames(_ db: SQLCipherDatabase) -> [Int64: String] {
        var names: [Int64: String] = [:]
        for row in db.query("SELECT key, value FROM t2") {
            guard case .int(let peer) = row[0], case .blob(let v) = row[1],
                  let entries = try? Postbox.decodeEntries(v) else { continue }
            let display = Postbox.peerDisplay(entries)
            if !display.isEmpty { names[peer] = display }
        }
        return names
    }

    private static func loadSelfPeerID(_ db: SQLCipherDatabase) -> Int64? {
        guard let row = db.query("SELECT value FROM t0 WHERE key=2").first,
              case .blob(let v) = row[0],
              let entries = try? Postbox.decodeEntries(v),
              let root = entries["_"] as? [String: Any] else { return nil }
        return root["peerId"] as? Int64
    }

    func recentChats(limit: Int) throws -> [ChatSummary] {
        // ponytail: O(all messages) — one ordered key scan groups by peer to
        // find each chat's latest activity. Runs once per summary, not hot; if a
        // huge t7 makes this laggy, add a per-peer index scan.
        var latest: [Int64: Int32] = [:]
        for row in db.query("SELECT key FROM t7") {
            guard case .blob(let k) = row[0], let peer = TelegramKey.peerID(fromKey: k) else { continue }
            let ts = TelegramKey.timestamp(fromKey: k)
            if ts > (latest[peer] ?? Int32.min) { latest[peer] = ts }
        }
        return latest.sorted { $0.value > $1.value }.prefix(limit).map { peer, ts in
            let title = peerNames[peer].flatMap { $0.isEmpty ? nil : $0 } ?? "Chat \(peer)"
            return ChatSummary(id: peer, title: title, lastActivity: Date(timeIntervalSince1970: Double(ts)))
        }
    }

    func messages(chatID: Int64, limit: Int) throws -> [ChatLine] {
        let lo = TelegramKey.be8(chatID) + [UInt8](repeating: 0x00, count: 12)
        let hi = TelegramKey.be8(chatID) + [UInt8](repeating: 0xFF, count: 12)
        let sql = "SELECT key, value FROM t7 WHERE key >= ? AND key <= ? ORDER BY key DESC LIMIT ?"
        let rows = db.query(sql, [.blob(lo), .blob(hi), .int(Int64(limit))])
        let lines: [ChatLine] = rows.compactMap { row in
            guard case .blob(let k) = row[0], case .blob(let v) = row[1],
                  let msg = Postbox.readMessage(v), !msg.text.isEmpty else { return nil }
            let sender: String
            if let author = msg.author, author != selfPeerID {
                sender = peerNames[author].flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown"
            } else {
                sender = "You"
            }
            let ts = TelegramKey.timestamp(fromKey: k)
            return ChatLine(sender: sender, text: msg.text, date: Date(timeIntervalSince1970: Double(ts)))
        }
        if lines.isEmpty { throw ChatArchiveError.emptyChat }
        return lines.reversed()   // query is newest-first; return oldest → newest
    }
}

/// Reads which chat is open on screen the only way Telegram-macOS exposes it:
/// off the pixels. The window title is the account name and the app is
/// AX-opaque, but the chat name is drawn in the header — so we screenshot the
/// Telegram window (occlusion-independent: we grab the window's own content,
/// not the composited screen, so Gizmo's ring on top doesn't matter) and OCR
/// the top strip. Returns header-band strings for `ChatNameMatch` to resolve.
/// Empty on any failure (no screen-recording permission, window gone) → the
/// caller falls back to the most-recent chat.
enum TelegramChatDetector {
    static let bundleID = "ru.keepcoder.Telegram"

    static func openChatTitleCandidates() async -> [String] {
        guard let image = await captureWindow() else { return [] }
        return headerStrings(in: image)
    }

    private static func captureWindow() async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            let windows = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == bundleID
                    && $0.frame.width > 300 && $0.frame.height > 200
            }
            guard let win = windows.max(by: {
                $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
            }) else { return nil }

            let config = SCStreamConfiguration()
            config.width = Int(win.frame.width) * 2          // retina-sharp for OCR
            config.height = Int(win.frame.height) * 2
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: win),
                configuration: config
            )
        } catch { return nil }
    }

    /// Text in the header band — the top slice of the RIGHT pane. Excludes the
    /// left chat-list sidebar (x < 0.35), which would otherwise offer up every
    /// visible chat name and defeat the point. Vision's boundingBox is
    /// normalized (origin bottom-left), so these fractions are resolution-free.
    private static func headerStrings(in image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["ru", "en", "ko"]
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil
        else { return [] }
        return (request.results ?? []).compactMap { obs in
            let topFraction = 1 - obs.boundingBox.maxY
            guard topFraction < 0.08, obs.boundingBox.minX > 0.35,
                  let best = obs.topCandidates(1).first, best.confidence > 0.45
            else { return nil }
            return best.string
        }
    }
}
