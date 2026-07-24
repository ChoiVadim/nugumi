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

/// Talks to chatgpt.com/backend-api/codex/responses on behalf of a
/// ChatGPT Plus/Pro subscriber. Sits behind Cloudflare which 403s any
/// request that doesn't advertise an allow-listed `originator` — we pin
/// `codex_cli_rs` (the value the Rust Codex CLI uses), the matching
/// User-Agent shape, and a `ChatGPT-Account-ID` extracted from the JWT.
/// All three are required; dropping any one trips the WAF.
struct OpenAICodexClient: LLMBackend {
    let apiModelID: String
    private static let maxImageBytes = 5 * 1024 * 1024

    /// Pulls a user-facing error message out of an OpenAI error JSON body.
    /// Accepts both `{"error": {"message": "…"}}` and `{"error": "…"}` shapes.
    private func extractOpenAIErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let err = obj["error"] as? [String: Any] {
            if let m = err["message"] as? String, !m.isEmpty { return m }
        } else if let s = obj["error"] as? String, !s.isEmpty {
            return s
        }
        return nil
    }

    /// Headers that mimic the Rust Codex CLI so Cloudflare doesn't block us.
    /// Extracted as a static helper so model discovery can reuse them.
    static func cloudflareHeaders(accessToken: String) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": "codex_cli_rs/0.0.0 (Nugumi)",
            "originator": "codex_cli_rs"
        ]
        let claims = CodexJWT.decode(accessToken)
        if let acct = claims.accountId, !acct.isEmpty {
            headers["ChatGPT-Account-ID"] = acct
        }
        return headers
    }

    func translate(
        _ text: String,
        images: [ImageInput],
        to targetLanguage: TranslationLanguage,
        mode: TranslationMode,
        appCategory: AppCategory,
        composition: CompositionSettings?,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        let sourceText: String
        switch mode {
        case .selection, .smartReply:
            sourceText = TextNormalizer.cleanedSelection(text)
        case .draftMessage:
            sourceText = TextNormalizer.cleanedDraftMessage(text)
        case .revise, .reviseMessage, .summarizeChat, .summarizePage:
            // Already composed deliberately (labeled sections) — don't let the
            // selection cleaner collapse the structure the prompt relies on.
            sourceText = text
        }
        guard !sourceText.isEmpty || !images.isEmpty else {
            throw TranslationError.emptyResponse
        }
        for image in images where image.data.count > Self.maxImageBytes {
            throw TranslationError.cloudError(.openAICodex, "Image too large (limit 5 MB)")
        }

        let systemPrompt = mode.systemPrompt(
            targetLanguage: targetLanguage,
            appCategory: appCategory,
            composition: composition
        )
        // TEMP DIAGNOSTIC (voice-sample issue) — remove once resolved.
        CodexDebugLog.append("[voice-debug] codex mode=\(mode) promptHasVoice=\(systemPrompt.contains("Voice sample —")) promptChars=\(systemPrompt.count)")
        let userContent: [CodexInputContent] = {
            var parts: [CodexInputContent] = [.text(sourceText, role: "user")]
            parts.append(contentsOf: images.map { .image($0.openAIDataURI) })
            return parts
        }()
        let body = CodexResponsesRequest(
            model: apiModelID,
            instructions: systemPrompt,
            input: [CodexInputItem(role: "user", content: userContent)],
            stream: true,
            store: false,
            reasoning: CodexReasoningConfig(effort: thinkingLevel.cloudReasoningEffort)
        )

        var streamed = ""
        try await runStreaming(body: body, timeoutInterval: 25) { delta in
            streamed += delta
            let partial = TextNormalizer.cleanedTranslation(streamed)
            if !partial.isEmpty { onPartial(partial) }
        }
        let final = TextNormalizer.cleanedTranslation(streamed)
        guard !final.isEmpty else { throw TranslationError.emptyResponse }
        return final
    }

    func ask(
        history: [AskNugumiTurn],
        question: String,
        image: ImageInput?,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> AskNugumiResponse {
        if let image, image.data.count > Self.maxImageBytes {
            throw TranslationError.cloudError(.openAICodex, "Image too large (limit 5 MB)")
        }
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuestion.isEmpty else {
            return AskNugumiResponse(message: "")
        }
        let currentPrompt = AskNugumiPromptBuilder.prompt(question: cleanQuestion, hasImage: image != nil)

        var items: [CodexInputItem] = []
        for turn in history {
            items.append(CodexInputItem(role: "user", content: [.text(turn.question, role: "user")]))
            items.append(CodexInputItem(role: "assistant", content: [.text(turn.answer, role: "assistant")]))
        }
        var currentContent: [CodexInputContent] = [.text(currentPrompt, role: "user")]
        if let image { currentContent.append(.image(image.openAIDataURI)) }
        items.append(CodexInputItem(role: "user", content: currentContent))

        let body = CodexResponsesRequest(
            model: apiModelID,
            instructions: AskNugumiPromptBuilder.systemPrompt(genZ: GenZStyle.isEnabled),
            input: items,
            stream: true,
            store: false,
            reasoning: CodexReasoningConfig(effort: thinkingLevel.cloudReasoningEffort)
        )

        var answer = ""
        try await runStreaming(body: body, timeoutInterval: 60) { delta in
            answer += delta
            onPartial(answer)
        }
        let parsed = AskNugumiResponse.parse(answer)
        guard !parsed.message.isEmpty else { throw TranslationError.emptyResponse }
        return parsed
    }

    // MARK: Streaming transport (Responses API SSE)

    private func runStreaming(
        body: CodexResponsesRequest,
        timeoutInterval: TimeInterval,
        onDelta: @escaping (String) -> Void
    ) async throws {
        let encoded = try JSONEncoder().encode(body)
        do {
            try await performStreamingRequest(encodedBody: encoded, timeoutInterval: timeoutInterval, allowRefresh: true, onDelta: onDelta)
        } catch TranslationError.invalidAPIKey(.openAICodex) {
            // One transparent retry after a forced refresh — covers tokens
            // revoked between our last JWT-exp check and the actual request.
            try await performStreamingRequest(encodedBody: encoded, timeoutInterval: timeoutInterval, allowRefresh: false, onDelta: onDelta)
        }
    }

    private func performStreamingRequest(
        encodedBody: Data,
        timeoutInterval: TimeInterval,
        allowRefresh: Bool,
        onDelta: @escaping (String) -> Void
    ) async throws {
        let (token, accountId) = try await CodexCredentialBroker.resolveAccessToken()
        CodexDebugLog.append("inference: POST /responses (model=\(apiModelID), account=\(accountId ?? "nil"), bodyBytes=\(encodedBody.count))")

        var request = URLRequest(url: CloudProvider.openAICodex.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "session_id")
        for (k, v) in Self.cloudflareHeaders(accessToken: token) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        // chatgpt.com/backend-api/codex/responses returns response headers in
        // <2s when healthy; when it black-holes, it black-holes forever.
        // Translate uses 25s (fast iteration); Ask uses 60s (longer responses,
        // more typing invested in the question).
        request.timeoutInterval = timeoutInterval
        request.httpBody = encodedBody

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let urlError as URLError where urlError.code == .cannotConnectToHost
            || urlError.code == .cannotFindHost
            || urlError.code == .networkConnectionLost
            || urlError.code == .notConnectedToInternet
            || urlError.code == .timedOut {
            CodexDebugLog.append("inference: URLError \(urlError.code.rawValue) — \(urlError.localizedDescription)")
            // The subscription endpoint sometimes drops individual requests
            // upstream — be explicit about that so users don't think Nugumi
            // is broken.
            let message: String
            if urlError.code == .notConnectedToInternet {
                message = "No internet connection."
            } else {
                message = "Sometimes drops requests - just try one more time."
            }
            throw TranslationError.cloudError(.openAICodex, message)
        }

        guard let http = response as? HTTPURLResponse else {
            CodexDebugLog.append("inference: non-HTTP response")
            throw TranslationError.cloudError(.openAICodex, "invalid response")
        }
        CodexDebugLog.append("inference: status=\(http.statusCode)")
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            // Drain the body so we can show OpenAI's actual error message —
            // 401/403 from the Codex endpoint for free accounts surfaces as
            // a JSON body with a useful explanation we should pass through
            // rather than swallowing as "rejected the API key."
            var bodyData = Data()
            for try await chunk in bytes { bodyData.append(chunk) }
            let bodyPreview = String(data: bodyData, encoding: .utf8)?.prefix(800) ?? ""
            CodexDebugLog.append("inference: \(http.statusCode) body=\(bodyPreview)")
            if http.statusCode == 401, allowRefresh {
                _ = try? await CodexCredentialBroker.forceRefresh()
                throw TranslationError.invalidAPIKey(.openAICodex)
            }
            // Try to extract a human-readable message from OpenAI's error JSON.
            let detail = extractOpenAIErrorMessage(from: bodyData) ?? CloudHTTPError.friendlyMessage(status: http.statusCode)
            throw TranslationError.cloudError(.openAICodex, detail)
        case 429:
            throw TranslationError.rateLimited(.openAICodex)
        default:
            var bodyData = Data()
            for try await chunk in bytes { bodyData.append(chunk) }
            let bodyPreview = String(data: bodyData, encoding: .utf8)?.prefix(800) ?? ""
            CodexDebugLog.append("inference: \(http.statusCode) body=\(bodyPreview)")
            let detail = extractOpenAIErrorMessage(from: bodyData) ?? CloudHTTPError.friendlyMessage(status: http.statusCode)
            throw TranslationError.cloudError(.openAICodex, detail)
        }

        let decoder = JSONDecoder()
        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(":") || line.hasPrefix("event:") { continue }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8) else { continue }
            if let chunk = try? decoder.decode(CodexResponsesStreamEvent.self, from: data) {
                if chunk.type == "response.output_text.delta", let delta = chunk.delta, !delta.isEmpty {
                    onDelta(delta)
                } else if chunk.type == "response.completed" {
                    break
                } else if chunk.type == "response.error" || chunk.type == "error" {
                    let msg = chunk.message ?? chunk.error?.message ?? "stream error"
                    throw TranslationError.cloudError(.openAICodex, msg)
                }
            }
        }
    }
}

// MARK: Codex Responses API wire types

private struct CodexResponsesRequest: Encodable {
    let model: String
    let instructions: String?
    let input: [CodexInputItem]
    let stream: Bool
    let store: Bool
    let reasoning: CodexReasoningConfig?
}

private struct CodexReasoningConfig: Encodable {
    let effort: String
}

private struct CodexInputItem: Encodable {
    let role: String
    let content: [CodexInputContent]
}

private enum CodexInputContent: Encodable {
    case text(String, role: String)
    case image(String) // data: URI

    private enum CodingKeys: String, CodingKey {
        case type, text, image_url
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s, let role):
            try c.encode(role == "assistant" ? "output_text" : "input_text", forKey: .type)
            try c.encode(s, forKey: .text)
        case .image(let url):
            try c.encode("input_image", forKey: .type)
            try c.encode(url, forKey: .image_url)
        }
    }
}

private struct CodexResponsesStreamEvent: Decodable {
    let type: String
    let delta: String?
    let message: String?
    let error: CodexResponsesStreamError?
}

private struct CodexResponsesStreamError: Decodable {
    let message: String?
}

// MARK: Codex login UI (device-code alert)

