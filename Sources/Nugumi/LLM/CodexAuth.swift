import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreServices
import CoreText
import CryptoKit
import Darwin
import Foundation
import ServiceManagement
import Sparkle
import SwiftUI
import UserNotifications
import Vision

struct CodexCredentials: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let accountId: String?
    let planType: String?

    func isExpiring(within seconds: TimeInterval) -> Bool {
        expiresAt.timeIntervalSinceNow < seconds
    }
}

enum CodexJWT {
    struct Claims {
        let expiresAt: Date?
        let accountId: String?
        let planType: String?
    }

    static func decode(_ jwt: String) -> Claims {
        let empty = Claims(expiresAt: nil, accountId: nil, planType: nil)
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let payload = base64URLDecode(String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return empty }

        let exp: Date? = {
            if let v = json["exp"] as? Double { return Date(timeIntervalSince1970: v) }
            if let v = json["exp"] as? Int { return Date(timeIntervalSince1970: TimeInterval(v)) }
            return nil
        }()
        let auth = json["https://api.openai.com/auth"] as? [String: Any]
        return Claims(
            expiresAt: exp,
            accountId: auth?["chatgpt_account_id"] as? String,
            planType: auth?["chatgpt_plan_type"] as? String
        )
    }

    static func base64URLDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = (4 - b64.count % 4) % 4
        if pad > 0 { b64.append(String(repeating: "=", count: pad)) }
        return Data(base64Encoded: b64)
    }
}

extension KeychainStore {
    private static var codexCache: CodexCredentials?
    private static var codexCacheLoaded = false
    private static let codexFileName = "openai.codex.tokens.json"

    private static var codexFileURL: URL {
        storageDirectory.appending(path: codexFileName, directoryHint: .notDirectory)
    }

    static func codexCredentials() -> CodexCredentials? {
        if codexCacheLoaded { return codexCache }
        codexCacheLoaded = true
        guard let data = try? Data(contentsOf: codexFileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        codexCache = try? decoder.decode(CodexCredentials.self, from: data)
        return codexCache
    }

    static func setCodexCredentials(_ creds: CodexCredentials?) {
        guard let creds else {
            try? FileManager.default.removeItem(at: codexFileURL)
            codexCache = nil
            codexCacheLoaded = true
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(creds) {
            try? data.write(to: codexFileURL, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: codexFileURL.path
            )
        }
        codexCache = creds
        codexCacheLoaded = true
    }
}

/// File-based debug log for the Codex auth flow. NSLog/os_log can get
/// silenced when the app is launched via `open` (stderr → /dev/null) and the
/// system log filter is unfriendly, so for the duration of debugging the
/// OAuth dance we mirror everything to ~/Library/Logs/Nugumi/codex.log
/// where the user can always `tail -f` it.
enum CodexDebugLog {
    private static let lock = NSLock()
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let fileURL: URL = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first!
            .appending(path: "Logs/Nugumi", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appending(path: "codex.log", directoryHint: .notDirectory)
    }()

    static func append(_ message: String) {
        let stamped = "\(formatter.string(from: Date())) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        if let data = stamped.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
        NSLog("[Nugumi/Codex] %@", message)
    }
}

// MARK: Codex OAuth client (device-code login + refresh)

/// Endpoints + flow shape mirror Hermes Agent's hermes_cli/auth.py:
/// `app_EMoamEEZ73f0CkXaXp7hrann` is the public Codex CLI client_id;
/// device-code returns {user_code, device_auth_id} then poll
/// /api/accounts/deviceauth/token until 200 returns {authorization_code,
/// code_verifier}, then exchange those at /oauth/token.
actor CodexOAuthClient {
    static let shared = CodexOAuthClient()

    private let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let issuer = "https://auth.openai.com"
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg)
    }()

    struct DeviceCodeStart {
        let userCode: String       // e.g. "LI50-8AOZ1"
        let deviceAuthID: String
        let verificationURL: URL   // https://auth.openai.com/codex/device
        let pollInterval: TimeInterval
    }

    enum CodexAuthError: LocalizedError {
        case network(String)
        case server(Int, String)
        case malformedResponse(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .network(let d): "Network error: \(d)"
            case .server(let code, let d): "Server returned HTTP \(code): \(d.prefix(200))"
            case .malformedResponse(let d): "Unexpected response: \(d)"
            case .timeout: "Login timed out after 15 minutes."
            }
        }
    }

    func startDeviceCode() async throws -> DeviceCodeStart {
        CodexDebugLog.append("startDeviceCode: requesting device code from \(issuer)")
        var req = URLRequest(url: URL(string: "\(issuer)/api/accounts/deviceauth/usercode")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": clientID])

        let (data, resp) = try await dataTask(req)
        guard let http = resp as? HTTPURLResponse else {
            throw CodexAuthError.malformedResponse("not an HTTP response")
        }
        let bodyPreview = String(data: data, encoding: .utf8)?.prefix(500) ?? ""
        CodexDebugLog.append("startDeviceCode: status=\(http.statusCode) body=\(bodyPreview)")
        guard http.statusCode == 200 else {
            throw CodexAuthError.server(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userCode = json["user_code"] as? String,
              let deviceAuthID = json["device_auth_id"] as? String
        else { throw CodexAuthError.malformedResponse("missing user_code / device_auth_id") }

        let interval: TimeInterval = {
            if let i = json["interval"] as? Double { return i }
            if let i = json["interval"] as? Int { return Double(i) }
            if let s = json["interval"] as? String, let v = Double(s) { return v }
            return 5
        }()
        CodexDebugLog.append("startDeviceCode: got userCode=\(userCode) interval=\(interval) keys=\(Array(json.keys))")
        return DeviceCodeStart(
            userCode: userCode,
            deviceAuthID: deviceAuthID,
            verificationURL: URL(string: "\(issuer)/codex/device")!,
            pollInterval: max(3, interval)
        )
    }

    func pollForTokens(
        deviceAuthID: String,
        userCode: String,
        interval: TimeInterval
    ) async throws -> CodexCredentials {
        let deadline = Date().addingTimeInterval(15 * 60)
        let pollURL = URL(string: "\(issuer)/api/accounts/deviceauth/token")!
        CodexDebugLog.append("pollForTokens: start — interval=\(interval)s deviceAuthID=\(deviceAuthID) userCode=\(userCode)")
        var lastStatusLogged = -1
        var iteration = 0
        while Date() < deadline {
            iteration += 1
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            try Task.checkCancellation()

            var req = URLRequest(url: pollURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "device_auth_id": deviceAuthID,
                "user_code": userCode
            ])

            let (data, resp): (Data, URLResponse)
            do {
                (data, resp) = try await dataTask(req)
            } catch {
                CodexDebugLog.append("poll #\(iteration): network error \(error)")
                continue
            }
            guard let http = resp as? HTTPURLResponse else {
                CodexDebugLog.append("poll #\(iteration): non-HTTP response")
                continue
            }
            let bodyPreview = String(data: data, encoding: .utf8)?.prefix(500) ?? ""
            if http.statusCode != lastStatusLogged {
                CodexDebugLog.append("poll #\(iteration) status=\(http.statusCode) body=\(bodyPreview)")
                lastStatusLogged = http.statusCode
            }
            switch http.statusCode {
            case 200:
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    CodexDebugLog.append("poll 200 but body not JSON: \(bodyPreview)")
                    throw CodexAuthError.malformedResponse("poll 200 body not JSON")
                }
                if let _ = json["access_token"] as? String {
                    CodexDebugLog.append("poll 200: direct access_token, skipping exchange")
                    return try parseTokenResponseJSON(json, fallbackRefreshToken: "")
                }
                if let authCode = json["authorization_code"] as? String,
                   let verifier = json["code_verifier"] as? String {
                    CodexDebugLog.append("poll 200: got authorization_code, exchanging…")
                    return try await exchangeAuthorizationCode(authCode, verifier: verifier)
                }
                CodexDebugLog.append("poll 200 unknown shape — keys=\(Array(json.keys))")
                throw CodexAuthError.malformedResponse("poll 200 unknown shape: \(Array(json.keys))")
            case 403, 404:
                continue // user hasn't completed sign-in yet
            case 400, 408, 425, 429:
                continue // "authorization_pending", "slow_down", or rate limit
            default:
                CodexDebugLog.append("poll #\(iteration) unexpected status \(http.statusCode) body=\(bodyPreview)")
                throw CodexAuthError.server(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
        }
        throw CodexAuthError.timeout
    }

    private func parseTokenResponseJSON(_ json: [String: Any], fallbackRefreshToken: String) throws -> CodexCredentials {
        guard let access = json["access_token"] as? String else {
            throw CodexAuthError.malformedResponse("missing access_token")
        }
        let refresh = (json["refresh_token"] as? String) ?? fallbackRefreshToken
        let claims = CodexJWT.decode(access)
        let fallbackExpiresIn: TimeInterval = {
            if let v = json["expires_in"] as? Double { return v }
            if let v = json["expires_in"] as? Int { return Double(v) }
            return 3600
        }()
        let expiry = claims.expiresAt ?? Date().addingTimeInterval(fallbackExpiresIn)
        return CodexCredentials(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: expiry,
            accountId: claims.accountId,
            planType: claims.planType
        )
    }

    private func exchangeAuthorizationCode(_ code: String, verifier: String) async throws -> CodexCredentials {
        try await postTokenRequest(form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": "\(issuer)/deviceauth/callback",
            "client_id": clientID,
            "code_verifier": verifier
        ])
    }

    func refresh(_ refreshToken: String) async throws -> CodexCredentials {
        try await postTokenRequest(form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ])
    }

    private func postTokenRequest(form: [String: String]) async throws -> CodexCredentials {
        let grantType = form["grant_type"] ?? "?"
        CodexDebugLog.append("postTokenRequest: building \(grantType) request to /oauth/token")
        var req = URLRequest(url: URL(string: "\(issuer)/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.urlencode(form).data(using: .utf8)
        CodexDebugLog.append("postTokenRequest: sending \(grantType), body \(req.httpBody?.count ?? 0) bytes")

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await dataTask(req)
        } catch {
            CodexDebugLog.append("postTokenRequest: dataTask threw — \(error)")
            throw error
        }
        guard let http = resp as? HTTPURLResponse else {
            CodexDebugLog.append("postTokenRequest: not an HTTPURLResponse")
            throw CodexAuthError.malformedResponse("not an HTTP response")
        }
        let bodyPreview = String(data: data, encoding: .utf8)?.prefix(500) ?? ""
        CodexDebugLog.append("postTokenRequest: \(grantType) status=\(http.statusCode) body=\(bodyPreview)")
        guard http.statusCode == 200 else {
            throw CodexAuthError.server(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String
        else { throw CodexAuthError.malformedResponse("missing access_token") }

        let refresh = (json["refresh_token"] as? String) ?? form["refresh_token"] ?? ""
        let claims = CodexJWT.decode(access)
        let fallbackExpiresIn: TimeInterval = {
            if let v = json["expires_in"] as? Double { return v }
            if let v = json["expires_in"] as? Int { return Double(v) }
            return 3600
        }()
        let expiry = claims.expiresAt ?? Date().addingTimeInterval(fallbackExpiresIn)
        CodexDebugLog.append("postTokenRequest: \(grantType) success — accountId=\(claims.accountId ?? "nil") plan=\(claims.planType ?? "nil")")
        return CodexCredentials(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: expiry,
            accountId: claims.accountId,
            planType: claims.planType
        )
    }

    private func dataTask(_ req: URLRequest) async throws -> (Data, URLResponse) {
        let url = req.url?.absoluteString ?? "?"
        CodexDebugLog.append("dataTask: starting \(req.httpMethod ?? "?") \(url)")
        do {
            let result = try await session.data(for: req)
            CodexDebugLog.append("dataTask: completed \(url)")
            return result
        } catch let err as URLError {
            CodexDebugLog.append("dataTask: URLError on \(url) — \(err.code.rawValue) \(err.localizedDescription)")
            throw CodexAuthError.network(err.localizedDescription)
        } catch {
            CodexDebugLog.append("dataTask: unexpected error on \(url) — \(error)")
            throw error
        }
    }

    private static func urlencode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?")
        return form.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
            return "\(ek)=\(ev)"
        }.joined(separator: "&")
    }
}

// MARK: Token broker — refresh-on-demand for inference paths

/// Resolves a fresh access token + JWT-derived account ID for the Codex
/// backend. Persists refreshed tokens back to Keychain. Serialized on the
/// shared CodexOAuthClient actor so concurrent translate/ask calls don't
/// stampede the token endpoint.
enum CodexCredentialBroker {
    /// Returns an access token guaranteed not to expire within ~2 minutes,
    /// refreshing transparently if needed. Throws if the user is not logged in.
    static func resolveAccessToken() async throws -> (token: String, accountId: String?) {
        guard let creds = KeychainStore.codexCredentials() else {
            throw TranslationError.invalidAPIKey(.openAICodex)
        }
        if !creds.isExpiring(within: 120) {
            return (creds.accessToken, creds.accountId)
        }
        do {
            let refreshed = try await CodexOAuthClient.shared.refresh(creds.refreshToken)
            await MainActor.run { KeychainStore.setCodexCredentials(refreshed) }
            return (refreshed.accessToken, refreshed.accountId)
        } catch let err as CodexOAuthClient.CodexAuthError {
            if case .server(let status, _) = err, status == 400 || status == 401 || status == 403 {
                // Refresh token revoked or rotated by another client — force re-login.
                await MainActor.run { KeychainStore.setCodexCredentials(nil) }
                throw TranslationError.invalidAPIKey(.openAICodex)
            }
            throw TranslationError.cloudError(.openAICodex, err.errorDescription ?? "auth error")
        }
    }

    static func forceRefresh() async throws -> (token: String, accountId: String?) {
        guard let creds = KeychainStore.codexCredentials() else {
            throw TranslationError.invalidAPIKey(.openAICodex)
        }
        let refreshed = try await CodexOAuthClient.shared.refresh(creds.refreshToken)
        await MainActor.run { KeychainStore.setCodexCredentials(refreshed) }
        return (refreshed.accessToken, refreshed.accountId)
    }
}

// MARK: - Claude Code (Anthropic subscription) OAuth
//
// Lets a user drive Nugumi with their Claude Pro/Max subscription instead of a
// pay-as-you-go Anthropic API key. Uses the Claude Code OAuth client + PKCE
// flow and the *native* /v1/messages API (the OpenAI-compat endpoint used by
// the `.anthropic` API-key provider does not accept OAuth Bearer tokens).
//
// NOTE: Anthropic restricts subscription OAuth to its own first-party clients;
// using it here means presenting as Claude Code (the claude-code beta header +
// claude-cli user-agent). The maintainer accepted this trade-off deliberately.

