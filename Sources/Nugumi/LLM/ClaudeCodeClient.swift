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

/// LLM client for the Claude subscription path: native Anthropic /v1/messages
/// (SSE) authed with the OAuth Bearer token + Claude Code beta headers. Reuses
/// the same prompt-building helpers as OpenAIChatClient; only the wire format
/// differs (native content blocks + `content_block_delta` stream events).
struct ClaudeCodeClient: LLMBackend {
    let model: String
    private let provider = CloudProvider.anthropicClaudeCode

    private static let maxImageBytes = 5 * 1024 * 1024
    /// Identity prefix Claude Code conventionally sends as its first system
    /// block. Convention, not a hard auth gate for tool-less calls — but cheap.
    private static let claudeCodeIdentity = "You are Claude Code, Anthropic's official CLI for Claude."

    func translate(
        _ text: String,
        images: [ImageInput] = [],
        to targetLanguage: TranslationLanguage,
        mode: TranslationMode = .selection,
        appCategory: AppCategory,
        composition: CompositionSettings? = nil,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        let sourceText: String
        switch mode {
        case .selection, .smartReply, .custom:
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
            throw TranslationError.cloudError(provider, "Image too large (limit 5 MB)")
        }

        let systemPrompt = mode.systemPrompt(
            targetLanguage: targetLanguage,
            appCategory: appCategory,
            composition: composition
        )
        let userContent = Self.contentBlocks(text: sourceText, images: images)
        return try await stream(
            systemPrompt: systemPrompt,
            messages: [["role": "user", "content": userContent]],
            thinkingLevel: thinkingLevel,
            onPartial: onPartial
        )
    }

    func ask(
        history: [AskNugumiTurn],
        question: String,
        image: ImageInput?,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> AskNugumiResponse {
        if let image {
            guard image.data.count <= Self.maxImageBytes else {
                throw TranslationError.cloudError(provider, "Image too large (limit 5 MB)")
            }
        }
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuestion.isEmpty else {
            return AskNugumiResponse(message: "")
        }

        var messages: [[String: Any]] = []
        for turn in history {
            messages.append(["role": "user", "content": turn.question])
            messages.append(["role": "assistant", "content": turn.answer])
        }
        let prompt = AskNugumiPromptBuilder.prompt(question: cleanQuestion, hasImage: image != nil)
        messages.append([
            "role": "user",
            "content": Self.contentBlocks(text: prompt, images: image.map { [$0] } ?? [])
        ])

        let answer = try await stream(
            systemPrompt: AskNugumiPromptBuilder.systemPrompt(genZ: GenZStyle.isEnabled),
            messages: messages,
            thinkingLevel: thinkingLevel,
            onPartial: onPartial
        )
        let parsed = AskNugumiResponse.parse(answer)
        guard !parsed.message.isEmpty else { throw TranslationError.emptyResponse }
        return parsed
    }

    /// Native content array: a text block plus one image block per attachment.
    private static func contentBlocks(text: String, images: [ImageInput]) -> [[String: Any]] {
        var blocks: [[String: Any]] = [["type": "text", "text": text]]
        for image in images {
            blocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": image.mediaType,
                    "data": image.base64String
                ]
            ])
        }
        return blocks
    }

    /// Extended thinking budget per level; nil = no thinking block. Native
    /// `thinking` replaces the compat `reasoning_effort` knob. max_tokens must
    /// stay above the budget (it does — see `maxTokens`).
    private static func thinkingBlock(for level: ThinkingLevel) -> [String: Any]? {
        switch level {
        case .low:    return nil
        case .medium: return ["type": "enabled", "budget_tokens": 4096]
        case .high:   return ["type": "enabled", "budget_tokens": 8192]
        }
    }
    private static let maxTokens = 16384

    private func stream(
        systemPrompt: String,
        messages: [[String: Any]],
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        // One transparent refresh-and-retry on a 401 (token revoked mid-flight),
        // matching the Codex client's resilience.
        do {
            return try await send(systemPrompt: systemPrompt, messages: messages,
                                  thinkingLevel: thinkingLevel, onPartial: onPartial)
        } catch TranslationError.invalidAPIKey {
            _ = try? await ClaudeCodeCredentialBroker.forceRefresh()
            return try await send(systemPrompt: systemPrompt, messages: messages,
                                  thinkingLevel: thinkingLevel, onPartial: onPartial)
        }
    }

    private func send(
        systemPrompt: String,
        messages: [[String: Any]],
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        let token = try await ClaudeCodeCredentialBroker.resolveAccessToken()

        var body: [String: Any] = [
            "model": model,
            "max_tokens": Self.maxTokens,
            "stream": true,
            "system": [
                ["type": "text", "text": Self.claudeCodeIdentity],
                ["type": "text", "text": systemPrompt]
            ],
            "messages": messages
        ]
        if let thinking = Self.thinkingBlock(for: thinkingLevel) {
            body["thinking"] = thinking
        }

        var request = URLRequest(url: provider.baseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(
            "claude-code-20250219,oauth-2025-04-20,interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14",
            forHTTPHeaderField: "anthropic-beta"
        )
        request.setValue("cli", forHTTPHeaderField: "x-app")
        request.setValue("claude-cli/2.0.0 (external, cli)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let urlError as URLError where urlError.code == .cannotConnectToHost
            || urlError.code == .cannotFindHost
            || urlError.code == .networkConnectionLost
            || urlError.code == .notConnectedToInternet
            || urlError.code == .timedOut {
            throw TranslationError.cloudError(provider, urlError.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.cloudError(provider, "invalid response")
        }
        switch httpResponse.statusCode {
        case 200..<300: break
        case 401, 403: throw TranslationError.invalidAPIKey(provider)
        case 429:      throw TranslationError.rateLimited(provider)
        case 402:      throw TranslationError.outOfCredits(provider)
        default:
            let body = await CloudHTTPError.readBody(bytes)
            throw TranslationError.cloudError(
                provider,
                CloudHTTPError.detail(status: httpResponse.statusCode, body: body)
            )
        }

        // Native SSE: lines like `event: content_block_delta` / `data: {…}`.
        // Only `text_delta` deltas carry visible output; thinking deltas and
        // lifecycle events are ignored.
        var answer = ""
        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            switch json["type"] as? String {
            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String, !text.isEmpty {
                    answer += text
                    onPartial(answer)
                }
            case "message_stop":
                return answer
            case "error":
                let message = (json["error"] as? [String: Any])?["message"] as? String
                throw TranslationError.cloudError(provider, message ?? "stream error")
            default:
                continue
            }
        }
        return answer
    }
}

// MARK: Discovered Codex models (live API + cached fallback)

