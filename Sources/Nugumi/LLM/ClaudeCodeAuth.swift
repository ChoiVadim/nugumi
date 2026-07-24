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

/// Sign-in result, mirroring CodexLoginAlert.Outcome's shape.
enum ClaudeCodeSignInOutcome {
    case success
    case cancelled
    case failed(String)
}

struct ClaudeCodeCredentials: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date

    func isExpiring(within seconds: TimeInterval) -> Bool {
        expiresAt.timeIntervalSinceNow < seconds
    }
}

extension KeychainStore {
    private static var claudeCodeCache: ClaudeCodeCredentials?
    private static var claudeCodeCacheLoaded = false
    private static let claudeCodeFileName = "anthropic.claudecode.tokens.json"

    private static var claudeCodeFileURL: URL {
        storageDirectory.appending(path: claudeCodeFileName, directoryHint: .notDirectory)
    }

    static func claudeCodeCredentials() -> ClaudeCodeCredentials? {
        if claudeCodeCacheLoaded { return claudeCodeCache }
        claudeCodeCacheLoaded = true
        guard let data = try? Data(contentsOf: claudeCodeFileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        claudeCodeCache = try? decoder.decode(ClaudeCodeCredentials.self, from: data)
        return claudeCodeCache
    }

    static func setClaudeCodeCredentials(_ creds: ClaudeCodeCredentials?) {
        guard let creds else {
            try? FileManager.default.removeItem(at: claudeCodeFileURL)
            claudeCodeCache = nil
            claudeCodeCacheLoaded = true
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(creds) {
            try? data.write(to: claudeCodeFileURL, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: claudeCodeFileURL.path
            )
        }
        claudeCodeCache = creds
        claudeCodeCacheLoaded = true
    }
}

/// PKCE-based OAuth against the Claude Code client. The authorize-URL +
/// manual-paste-code variant (no local callback server): the user approves in
/// the browser, Anthropic shows a `code#state` string, they paste it back.
actor ClaudeCodeOAuthClient {
    static let shared = ClaudeCodeOAuthClient()

    fileprivate static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    fileprivate static let authorizeEndpoint = "https://claude.ai/oauth/authorize"
    fileprivate static let tokenEndpoint = "https://console.anthropic.com/v1/oauth/token"
    fileprivate static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    fileprivate static let scope = "org:create_api_key user:profile user:inference"

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg)
    }()

    struct PKCE {
        let verifier: String
        let challenge: String
        let state: String
    }

    enum AuthError: LocalizedError {
        case network(String)
        case server(Int, String)
        case malformedResponse(String)

        var errorDescription: String? {
            switch self {
            case .network(let d): "Network error: \(d)"
            case .server(let code, let d): "Sign-in failed (HTTP \(code)): \(d.prefix(200))"
            case .malformedResponse(let d): "Unexpected response: \(d)"
            }
        }
    }

    /// Pure/sync — the UI builds the authorize URL on the main actor before any
    /// network work. Static members of an actor are not actor-isolated.
    static func makePKCE() -> PKCE {
        let verifier = randomURLSafe(byteCount: 64)
        let challenge = base64URLEncode(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomURLSafe(byteCount: 32)
        return PKCE(verifier: verifier, challenge: challenge, state: state)
    }

    static func authorizeURL(pkce: PKCE) -> URL {
        var comps = URLComponents(string: authorizeEndpoint)!
        comps.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: pkce.state)
        ]
        return comps.url!
    }

    /// Anthropic shows the user a `code#state` string. Tolerate a bare code too.
    func exchange(pastedCode: String, pkce: PKCE) async throws -> ClaudeCodeCredentials {
        let pieces = pastedCode.split(separator: "#", maxSplits: 1).map(String.init)
        let code = pieces[0]
        let state = pieces.count > 1 ? pieces[1] : pkce.state
        return try await postToken(form: [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "redirect_uri": Self.redirectURI,
            "client_id": Self.clientID,
            "code_verifier": pkce.verifier
        ])
    }

    func refresh(_ refreshToken: String) async throws -> ClaudeCodeCredentials {
        try await postToken(form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID
        ])
    }

    private func postToken(form: [String: String]) async throws -> ClaudeCodeCredentials {
        var req = URLRequest(url: URL(string: Self.tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: form)

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch let err as URLError {
            throw AuthError.network(err.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw AuthError.malformedResponse("not an HTTP response")
        }
        guard http.statusCode == 200 else {
            throw AuthError.server(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String
        else { throw AuthError.malformedResponse("missing access_token") }

        let refresh = (json["refresh_token"] as? String) ?? form["refresh_token"] ?? ""
        let expiresIn: TimeInterval = {
            if let v = json["expires_in"] as? Double { return v }
            if let v = json["expires_in"] as? Int { return Double(v) }
            return 3600
        }()
        return ClaudeCodeCredentials(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URLEncode(Data(bytes))
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Refresh-on-demand token broker for the Claude Code inference path. Mirrors
/// CodexCredentialBroker: serialized on the shared actor, refreshes ~2 min
/// before expiry, wipes creds + forces re-login on a revoked refresh token.
enum ClaudeCodeCredentialBroker {
    static func resolveAccessToken() async throws -> String {
        guard let creds = KeychainStore.claudeCodeCredentials() else {
            throw TranslationError.invalidAPIKey(.anthropicClaudeCode)
        }
        if !creds.isExpiring(within: 120) { return creds.accessToken }
        do {
            let refreshed = try await ClaudeCodeOAuthClient.shared.refresh(creds.refreshToken)
            await MainActor.run { KeychainStore.setClaudeCodeCredentials(refreshed) }
            return refreshed.accessToken
        } catch let err as ClaudeCodeOAuthClient.AuthError {
            if case .server(let status, _) = err, status == 400 || status == 401 || status == 403 {
                await MainActor.run { KeychainStore.setClaudeCodeCredentials(nil) }
                throw TranslationError.invalidAPIKey(.anthropicClaudeCode)
            }
            throw TranslationError.cloudError(.anthropicClaudeCode, err.errorDescription ?? "auth error")
        }
    }

    static func forceRefresh() async throws -> String {
        guard let creds = KeychainStore.claudeCodeCredentials() else {
            throw TranslationError.invalidAPIKey(.anthropicClaudeCode)
        }
        let refreshed = try await ClaudeCodeOAuthClient.shared.refresh(creds.refreshToken)
        await MainActor.run { KeychainStore.setClaudeCodeCredentials(refreshed) }
        return refreshed.accessToken
    }
}

