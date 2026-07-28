import Foundation

/// Builds the client for a model ID. Split out of the app delegate so headless
/// entry points — the tool-generation eval, and anything else that needs a
/// backend without a running UI — pick the same client the app would, instead
/// of a second copy of this switch that drifts.
enum LLMBackendFactory {
    static let ollamaBaseURL = URL(string: "http://127.0.0.1:11434")!

    static func backend(for modelID: String) -> any LLMBackend {
        let model = LLMModel.option(id: modelID)
        switch model.backend {
        case .ollama:
            return OllamaClient(baseURL: ollamaBaseURL, model: model.apiModelID)
        case .cloud(let provider):
            switch provider {
            case .openAICodex:
                return OpenAICodexClient(apiModelID: model.apiModelID)
            case .anthropicClaudeCode:
                return ClaudeCodeClient(model: model.apiModelID)
            case .openAI, .anthropic, .gemini, .openRouter:
                let key = KeychainStore.apiKey(for: provider) ?? ""
                return OpenAIChatClient(provider: provider, apiKey: key, model: model.apiModelID)
            }
        }
    }
}
