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

struct OllamaClient: LLMBackend {
    let baseURL: URL
    let model: String

    func ask(
        history: [AskGizmateTurn],
        question: String,
        image: ImageInput?,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> AskGizmateResponse {
        if image != nil, !LLMModel.option(id: model).supportsImages {
            throw TranslationError.ollama("Selected Ollama model doesn't support images.")
        }

        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuestion.isEmpty else {
            return AskGizmateResponse(message: "")
        }

        var messages: [ChatMessage] = [
            ChatMessage(role: "system", content: AskGizmatePromptBuilder.systemPrompt())
        ]
        for turn in history {
            messages.append(ChatMessage(role: "user", content: turn.question))
            messages.append(ChatMessage(role: "assistant", content: turn.answer))
        }
        let prompt = AskGizmatePromptBuilder.prompt(question: cleanQuestion, hasImage: image != nil)
        messages.append(ChatMessage(role: "user", content: prompt, images: image.map { [$0.base64String] }))

        let answer = try await stream(
            messages: messages,
            thinkingLevel: thinkingLevel,
            onPartial: onPartial
        )

        let parsed = AskGizmateResponse.parse(answer)
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
        composition: CompositionSettings? = nil,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        let sourceText: String
        switch mode {
        case .selection, .smartReply, .custom:
            sourceText = TextNormalizer.cleanedSelection(text)
        case .draftMessage, .genZ:
            sourceText = TextNormalizer.cleanedDraftMessage(text)
        case .revise, .reviseMessage, .summarizeChat, .summarizePage:
            // Already composed deliberately (labeled sections) — don't let the
            // selection cleaner collapse the structure the prompt relies on.
            sourceText = text
        }
        guard !sourceText.isEmpty else {
            throw TranslationError.emptyResponse
        }

        if !images.isEmpty, !LLMModel.option(id: model).supportsImages {
            throw TranslationError.ollama("Selected Ollama model doesn't support images.")
        }

        let imageStrings = images.isEmpty ? nil : images.map(\.base64String)
        let translated = try await stream(
            messages: [
                ChatMessage(
                    role: "system",
                    content: mode.systemPrompt(
                        targetLanguage: targetLanguage,
                        composition: composition
                    )
                ),
                ChatMessage(role: "user", content: sourceText, images: imageStrings)
            ],
            thinkingLevel: thinkingLevel
        ) { raw in
            let partial = TextNormalizer.cleanedTranslation(raw)
            if !partial.isEmpty {
                onPartial(partial)
            }
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
        images: [ImageInput] = [],
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        if !images.isEmpty, !LLMModel.option(id: model).supportsImages {
            throw TranslationError.ollama("Selected Ollama model doesn't support images.")
        }
        return try await stream(
            messages: [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(
                    role: "user",
                    content: userPrompt,
                    images: images.isEmpty ? nil : images.map(\.base64String)
                )
            ],
            thinkingLevel: thinkingLevel,
            onPartial: onPartial
        )
    }

    /// One streaming chat turn. `ask` and `translate` each held their own copy of
    /// this; `onPartial` gets the accumulated raw text so the caller decides how
    /// to clean it.
    private func stream(
        messages: [ChatMessage],
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(model: model, stream: true, think: thinkingLevel.rawValue, messages: messages)
        )

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let urlError as URLError where urlError.code == .cannotConnectToHost
            || urlError.code == .cannotFindHost
            || urlError.code == .networkConnectionLost
            || urlError.code == .notConnectedToInternet {
            throw TranslationError.serverUnavailable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.ollama("invalid response")
        }
        if httpResponse.statusCode == 404 {
            throw TranslationError.modelMissing(model)
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw TranslationError.signInRequired
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TranslationError.ollama("HTTP \(httpResponse.statusCode)")
        }

        var answer = ""
        let decoder = JSONDecoder()
        for try await line in bytes.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            if let streamError = try? decoder.decode(StreamError.self, from: data),
               let message = streamError.error {
                throw OllamaClient.classifyStreamError(message: message, model: model)
            }
            let decoded = try decoder.decode(ChatResponse.self, from: data)
            answer += decoded.message.content
            onPartial(answer)
            if decoded.done { break }
        }
        return answer
    }

    static func classifyStreamError(message: String, model: String) -> TranslationError {
        let lowered = message.lowercased()
        if lowered.contains("not found") && (lowered.contains("model") || lowered.contains("manifest")) {
            return .modelMissing(model)
        }
        if lowered.contains("unauthorized")
            || lowered.contains("sign in")
            || lowered.contains("not signed in")
            || lowered.contains("signin")
            || lowered.contains("authenticate")
            || lowered.contains("forbidden") {
            return .signInRequired
        }
        return .ollama(message)
    }
}

struct ChatRequest: Encodable {
    let model: String
    let stream: Bool
    // NOTE: send the effort level string ("low"/"medium"/"high"), never a bool.
    // gpt-oss is a level-based reasoning model: `think: false` is ignored and
    // falls back to default effort, which still reasons and is ~2x SLOWER than
    // "low" (measured on gpt-oss:20b and :120b-cloud). "low" is the fast path.
    let think: String
    let messages: [ChatMessage]
    /// Keep the model resident in (V)RAM between requests so intermittent use
    /// doesn't pay a cold model-load each time. Ollama-only concept.
    var keepAlive: String = "30m"

    private enum CodingKeys: String, CodingKey {
        case model, stream, think, messages
        case keepAlive = "keep_alive"
    }
}

struct ChatMessage: Codable {
    let role: String
    let content: String
    let images: [String]?

    init(role: String, content: String, images: [String]? = nil) {
        self.role = role
        self.content = content
        self.images = images
    }
}

struct ChatResponse: Decodable {
    let message: ChatMessage
    let done: Bool
}

struct StreamError: Decodable {
    let error: String?
}

