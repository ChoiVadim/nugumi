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
