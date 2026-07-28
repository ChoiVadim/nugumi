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

struct OpenAIChatClient: LLMBackend {
    let provider: CloudProvider
    let apiKey: String
    let model: String

    private static let maxImageBytes = 5 * 1024 * 1024

    func ask(
        history: [AskNugumiTurn],
        question: String,
        image: ImageInput?,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> AskNugumiResponse {
        guard !apiKey.isEmpty else {
            throw TranslationError.invalidAPIKey(provider)
        }

        if let image {
            guard LLMModel.option(id: model).supportsImages else {
                throw TranslationError.cloudError(provider, "Ask Gizmo with a screenshot needs a vision model.")
            }
            guard image.data.count <= Self.maxImageBytes else {
                throw TranslationError.cloudError(provider, "Image too large (limit 5 MB)")
            }
        }

        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuestion.isEmpty else {
            return AskNugumiResponse(message: "")
        }

        let currentPrompt = AskNugumiPromptBuilder.prompt(question: cleanQuestion, hasImage: image != nil)
        let currentUserContent: OpenAIContent
        if let image {
            currentUserContent = .parts([
                .text(currentPrompt),
                .imageURL(image.openAIDataURI)
            ])
        } else {
            currentUserContent = .string(currentPrompt)
        }

        var messages: [OpenAIMessage] = [
            OpenAIMessage(role: "system", content: .string(AskNugumiPromptBuilder.systemPrompt(genZ: GenZStyle.isEnabled)))
        ]
        for turn in history {
            messages.append(OpenAIMessage(role: "user", content: .string(turn.question)))
            messages.append(OpenAIMessage(role: "assistant", content: .string(turn.answer)))
        }
        messages.append(OpenAIMessage(role: "user", content: currentUserContent))

        let answer = try await stream(
            messages: messages,
            thinkingLevel: thinkingLevel,
            onPartial: onPartial
        )

        let parsed = AskNugumiResponse.parse(answer)
        guard !parsed.message.isEmpty else {
            throw TranslationError.emptyResponse
        }
        return parsed
    }

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
        guard !apiKey.isEmpty else {
            throw TranslationError.invalidAPIKey(provider)
        }

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
        let userContent: OpenAIContent = images.isEmpty
            ? .string(sourceText)
            : .parts([.text(sourceText)] + images.map { .imageURL($0.openAIDataURI) })

        let translated = try await stream(
            messages: [
                OpenAIMessage(role: "system", content: .string(systemPrompt)),
                OpenAIMessage(role: "user", content: userContent)
            ],
            thinkingLevel: thinkingLevel
        ) { raw in
            let partial = TextNormalizer.cleanedTranslation(raw)
            if !partial.isEmpty { onPartial(partial) }
        }

        let finalTranslation = TextNormalizer.cleanedTranslation(translated)
        guard !finalTranslation.isEmpty else {
            throw TranslationError.emptyResponse
        }
        return finalTranslation
    }
    func complete(
        systemPrompt: String,
        userPrompt: String,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw TranslationError.invalidAPIKey(provider) }
        return try await stream(
            messages: [
                OpenAIMessage(role: "system", content: .string(systemPrompt)),
                OpenAIMessage(role: "user", content: .string(userPrompt))
            ],
            thinkingLevel: thinkingLevel,
            onPartial: onPartial
        )
    }

    /// One streaming chat completion. `ask` and `translate` held byte-identical
    /// copies of this; `onPartial` gets the accumulated raw text so each caller
    /// decides how to clean it.
    private func stream(
        messages: [OpenAIMessage],
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        let body = OpenAIRequest(
            model: model,
            stream: true,
            messages: messages,
            thinkingOptions: CloudThinkingOptions(
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel
            )
        )

        var request = URLRequest(url: provider.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(body)

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
        case 200..<300:
            break
        case 401, 403:
            throw TranslationError.invalidAPIKey(provider)
        case 429:
            throw TranslationError.rateLimited(provider)
        case 402:
            throw TranslationError.outOfCredits(provider)
        default:
            let body = await CloudHTTPError.readBody(bytes)
            throw TranslationError.cloudError(
                provider,
                CloudHTTPError.detail(status: httpResponse.statusCode, body: body)
            )
        }

        var answer = ""
        let decoder = JSONDecoder()
        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(":") { continue }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8) else { continue }
            if let streamError = try? decoder.decode(OpenAIStreamError.self, from: data) {
                throw TranslationError.cloudError(provider, streamError.displayMessage)
            }
            guard let chunk = try? decoder.decode(OpenAIStreamChunk.self, from: data) else {
                throw TranslationError.cloudError(provider, "Unexpected stream payload")
            }
            if let delta = chunk.choices.first?.delta.content, !delta.isEmpty {
                answer += delta
                onPartial(answer)
            }
            if chunk.choices.first?.finishReason != nil { break }
        }

        return answer
    }
}

private enum OpenAIContent: Encodable {
    case string(String)
    case parts([OpenAIPart])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let text):
            try container.encode(text)
        case .parts(let parts):
            try container.encode(parts)
        }
    }
}

private enum OpenAIPart: Encodable {
    case text(String)
    case imageURL(String)

    private enum CodingKeys: String, CodingKey {
        case type, text, image_url
    }

    private struct ImageURLBox: Encodable {
        let url: String
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageURL(let url):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageURLBox(url: url), forKey: .image_url)
        }
    }
}

private struct OpenAIMessage: Encodable {
    let role: String
    let content: OpenAIContent
}

struct CloudThinkingOptions: Encodable, Equatable {
    let reasoningEffort: String?
    let thinking: AnthropicThinkingConfig?
    let outputConfig: AnthropicOutputConfig?

    init(provider: CloudProvider, model: String, thinkingLevel: ThinkingLevel) {
        // All four providers POST to OpenAI-compatible /chat/completions
        // endpoints. Anthropic's compat endpoint rejects native thinking params
        // — `thinking: {type:"adaptive"}` returns HTTP 400 "Adaptive thinking is
        // not available via the OpenAI compatibility endpoint" — but accepts the
        // OpenAI-style `reasoning_effort` knob (verified against the live API),
        // so every compat provider routes through it. Do NOT send native
        // `thinking`/`output_config` here.
        switch provider {
        case .openAI, .gemini, .openAICodex, .anthropic, .openRouter, .anthropicClaudeCode:
            // .anthropicClaudeCode never constructs this type (it builds a
            // native Messages body via ClaudeCodeClient); the case exists only
            // for exhaustiveness.
            reasoningEffort = thinkingLevel.cloudReasoningEffort
            thinking = nil
            outputConfig = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case reasoningEffort = "reasoning_effort"
        case thinking
        case outputConfig = "output_config"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try container.encodeIfPresent(thinking, forKey: .thinking)
        try container.encodeIfPresent(outputConfig, forKey: .outputConfig)
    }
}

struct AnthropicThinkingConfig: Encodable, Equatable {
    let type: String
    let budgetTokens: Int?

    init(type: String, budgetTokens: Int? = nil) {
        self.type = type
        self.budgetTokens = budgetTokens
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case budgetTokens = "budget_tokens"
    }
}

struct AnthropicOutputConfig: Encodable, Equatable {
    let effort: String
}

extension ThinkingLevel {
    var cloudReasoningEffort: String { rawValue }
}

private struct OpenAIRequest: Encodable {
    let model: String
    let stream: Bool
    let messages: [OpenAIMessage]
    let thinkingOptions: CloudThinkingOptions?

    private enum CodingKeys: String, CodingKey {
        case model
        case stream
        case messages
        case reasoningEffort = "reasoning_effort"
        case thinking
        case outputConfig = "output_config"
    }

    init(
        model: String,
        stream: Bool,
        messages: [OpenAIMessage],
        thinkingOptions: CloudThinkingOptions? = nil
    ) {
        self.model = model
        self.stream = stream
        self.messages = messages
        self.thinkingOptions = thinkingOptions
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(stream, forKey: .stream)
        try container.encode(messages, forKey: .messages)
        try container.encodeIfPresent(thinkingOptions?.reasoningEffort, forKey: .reasoningEffort)
        try container.encodeIfPresent(thinkingOptions?.thinking, forKey: .thinking)
        try container.encodeIfPresent(thinkingOptions?.outputConfig, forKey: .outputConfig)
    }
}

private struct OpenAIStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }
        let delta: Delta
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }
    let choices: [Choice]
}

private struct OpenAIStreamError: Decodable {
    struct ErrorBody: Decodable {
        let message: String?
        let type: String?
        let code: String?
    }

    let error: ErrorBody

    var displayMessage: String {
        error.message ?? error.type ?? error.code ?? "stream error"
    }
}

