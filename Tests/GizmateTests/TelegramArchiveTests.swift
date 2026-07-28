import XCTest
import CommonCrypto
@testable import Gizmate

/// Minimal Postbox encoder — the inverse of `Postbox`/`PostboxReader`, used to
/// build fixtures so the decoder is checked against known inputs (no real chat
/// data). Mirrors the little-endian, length-prefixed wire format.
private enum Enc {
    static func le32(_ v: Int32) -> [UInt8] {
        let u = UInt32(bitPattern: v); return (0..<4).map { UInt8((u >> (8 * $0)) & 0xFF) }
    }
    static func le64(_ v: Int64) -> [UInt8] {
        let u = UInt64(bitPattern: v); return (0..<8).map { UInt8((u >> (8 * $0)) & 0xFF) }
    }
    static func string(_ s: String) -> [UInt8] { le32(Int32(s.utf8.count)) + Array(s.utf8) }
    static func shortString(_ s: String) -> [UInt8] { [UInt8(s.utf8.count)] + Array(s.utf8) }

    /// A type-5 object value: typeHash(0) + size + entries.
    static func object(_ entries: [(String, [UInt8])]) -> [UInt8] {
        var body: [UInt8] = []
        for (k, v) in entries { body += shortString(k) + v }
        return le32(0) + le32(Int32(body.count)) + body
    }
    static func stringValue(_ s: String) -> [UInt8] { [4] + string(s) }        // type 4
    static func objectValue(_ entries: [(String, [UInt8])]) -> [UInt8] { [5] + object(entries) }  // type 5
    static func int64Value(_ v: Int64) -> [UInt8] { [1] + le64(v) }            // type 1

    /// A peer record blob: top-level entry "_" → object.
    static func peer(_ fields: [(String, [UInt8])]) -> [UInt8] {
        shortString("_") + objectValue(fields)
    }

    /// A minimal t7 message record (version 0, no data-flags, no forward).
    static func message(author: Int64?, text: String) -> [UInt8] {
        var out: [UInt8] = [0]              // i8 version = 0
        out += le32(0) + le32(0)            // two u32
        out += [0]                          // u8 dataFlags = 0
        out += le32(0) + le32(0)            // flags, tags
        out += [0]                          // i8 forward flags = 0
        if let a = author { out += [1] + le64(a) } else { out += [0] }
        out += string(text)
        return out
    }

    /// 20-byte big-endian t7 key.
    static func messageKey(peer: Int64, namespace: Int32, timestamp: Int32, msgID: UInt32) -> [UInt8] {
        func be64(_ v: Int64) -> [UInt8] { let u = UInt64(bitPattern: v); return (0..<8).map { UInt8((u >> (8 * (7 - $0))) & 0xFF) } }
        func be32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * (3 - $0))) & 0xFF) } }
        return be64(peer) + be32(UInt32(bitPattern: namespace)) + be32(UInt32(bitPattern: timestamp)) + be32(msgID)
    }
}

final class TelegramArchiveTests: XCTestCase {

    // MARK: Postbox peer / object decoding

    func testPeerDisplayFullName() throws {
        let blob = Enc.peer([("fn", Enc.stringValue("Alice")), ("ln", Enc.stringValue("Smith"))])
        XCTAssertEqual(Postbox.peerDisplay(try Postbox.decodeEntries(blob)), "Alice Smith")
    }

    func testPeerDisplayTitleThenUsername() throws {
        let group = Enc.peer([("t", Enc.stringValue("Team Chat"))])
        XCTAssertEqual(Postbox.peerDisplay(try Postbox.decodeEntries(group)), "Team Chat")
        let user = Enc.peer([("un", Enc.stringValue("bob"))])
        XCTAssertEqual(Postbox.peerDisplay(try Postbox.decodeEntries(user)), "@bob")
    }

    func testSelfPeerIDShape() throws {
        // t0 key=2 value: "_" object carrying peerId (int64, type 1).
        let blob = Enc.peer([("peerId", Enc.int64Value(1_815_092_465))])
        let entries = try Postbox.decodeEntries(blob)
        let root = entries["_"] as? [String: Any]
        XCTAssertEqual(root?["peerId"] as? Int64, 1_815_092_465)
    }

    // MARK: t7 message record decoding

    func testReadMessageWithAuthorAndText() {
        let blob = Enc.message(author: 42, text: "hey there")
        let msg = Postbox.readMessage(blob)
        XCTAssertEqual(msg?.text, "hey there")
        XCTAssertEqual(msg?.author, 42)
    }

    func testReadMessageOutgoingNoAuthor() {
        let msg = Postbox.readMessage(Enc.message(author: nil, text: "sent by me"))
        XCTAssertEqual(msg?.text, "sent by me")
        XCTAssertNil(msg?.author)
    }

    func testReadMessageUnknownVersionIsSkipped() {
        var blob = Enc.message(author: 1, text: "x")
        blob[0] = 9   // non-zero version
        XCTAssertNil(Postbox.readMessage(blob))
    }

    func testReadMessageTruncatedIsSkipped() {
        let blob = Array(Enc.message(author: 1, text: "hello").prefix(6))
        XCTAssertNil(Postbox.readMessage(blob))
    }

    // MARK: message-key parsing

    func testKeyRoundTrip() {
        let key = Enc.messageKey(peer: 1_815_092_465, namespace: 0, timestamp: 1_700_000_000, msgID: 7)
        XCTAssertEqual(TelegramKey.peerID(fromKey: key), 1_815_092_465)
        XCTAssertEqual(TelegramKey.timestamp(fromKey: key), 1_700_000_000)
    }

    func testBE8MatchesKeyPrefix() {
        let key = Enc.messageKey(peer: -1_000_000_000_042, namespace: 2, timestamp: 1, msgID: 1)
        XCTAssertEqual(TelegramKey.be8(-1_000_000_000_042), Array(key.prefix(8)))
    }

    func testPeerIDRejectsShortKey() {
        XCTAssertNil(TelegramKey.peerID(fromKey: [0, 1, 2]))
    }

    // MARK: tempkey derivation (AES-256-CBC under SHA-512 of the passcode)

    func testDeriveRecoversKeyAndSalt() throws {
        let key = [UInt8](repeating: 0xAB, count: 32)
        let salt = [UInt8](repeating: 0xCD, count: 16)
        let plaintext = key + salt + [UInt8](repeating: 0, count: 16)   // 64-byte block

        // Encrypt with the same passcode-derived key/iv derive() expects.
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        let pw = Array("no-matter-key".utf8)
        CC_SHA512(pw, CC_LONG(pw.count), &digest)
        let aesKey = Array(digest[0..<32]); let iv = Array(digest[48..<64])
        var enc = [UInt8](repeating: 0, count: plaintext.count + kCCBlockSizeAES128)
        var moved = 0
        let st = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                         aesKey, aesKey.count, iv, plaintext, plaintext.count, &enc, enc.count, &moved)
        XCTAssertEqual(st, Int32(kCCSuccess))

        let derived = TelegramKey.derive(tempkey: Data(enc[0..<moved]))
        XCTAssertEqual(derived?.keyHex, TelegramKey.hex(key))
        XCTAssertEqual(derived?.saltHex, TelegramKey.hex(salt))
    }

    func testDeriveRejectsShortTempkey() {
        XCTAssertNil(TelegramKey.derive(tempkey: Data([1, 2, 3])))
    }

    // MARK: open-chat OCR fuzzy matching (ChatNameMatch)

    private func chat(_ id: Int64, _ title: String) -> ChatSummary {
        ChatSummary(id: id, title: title, lastActivity: nil)
    }

    func testMatchToleratesOCRError() {
        let chats = [chat(1, "Shiba Inu"), chat(2, "LeviosaAI"), chat(3, "Gizmate CTO")]
        // Vision reads the capital I in "LeviosaAI" as a lowercase l.
        XCTAssertEqual(ChatNameMatch.best(candidates: ["LeviosaAl", "8 members"], in: chats)?.id, 2)
    }

    func testMatchExactWins() {
        let chats = [chat(1, "Shiba Inu"), chat(2, "LeviosaAI")]
        XCTAssertEqual(ChatNameMatch.best(candidates: ["Shiba Inu"], in: chats)?.id, 1)
    }

    func testMatchRejectsHeaderJunk() {
        let chats = [chat(1, "Shiba Inu"), chat(2, "LeviosaAI")]
        // Subtitle / status strings must not match any chat.
        XCTAssertNil(ChatNameMatch.best(candidates: ["8 members", "last seen recently"], in: chats))
    }

    func testMatchEmptyCandidatesIsNil() {
        XCTAssertNil(ChatNameMatch.best(candidates: [], in: [chat(1, "Shiba Inu")]))
    }

    func testMatchNoConfidentMatchIsNil() {
        // An unrelated on-screen string shouldn't force a wrong chat.
        XCTAssertNil(ChatNameMatch.best(candidates: ["Zzzzxq"], in: [chat(1, "Shiba Inu"), chat(2, "LeviosaAI")]))
    }
}
