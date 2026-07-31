import Foundation


/// One-shot transcript summary via OpenAI chat completions. Kept minimal (no
/// temperature / max_tokens) so it works across the gpt-5 model family.
enum LiveSummarizer {
    static func summarize(_ transcript: String, apiKey: String, language: String,
                          model: String = "gpt-5.4-mini") async throws -> String {
        let system = "Summarize transcripts of live audio (calls, videos, lectures, meetings). "
            + "Open with ONE short sentence giving the gist — what it's about. Then a blank line, then the "
            + "key points as a markdown bullet list using '- ', each bullet one concrete fact in ≤12 words. "
            + "Always be SHORTER than the source: merge overlapping points, drop filler, hedging, repetition and "
            + "small talk. If the transcript is short, the gist sentence alone is enough — add bullets only when "
            + "there are genuinely distinct points, and never pad to reach a count. "
            + "No 'TL;DR' or 'Key points' headings. Write the ENTIRE summary in \(language), "
            + "regardless of the transcript's language."
        return try await chat([
            ["role": "system", "content": system],
            ["role": "user", "content": transcript]
        ], apiKey: apiKey, model: model)
    }

    /// Answers a follow-up question grounded in the transcript + its summary.
    /// `history` is the prior [user, assistant] turns so follow-ups chain.
    static func answer(question: String, transcript: String, summary: String,
                       history: [[String: Any]], apiKey: String, language: String,
                       model: String = "gpt-5.4-mini") async throws -> String {
        let system = "You answer follow-up questions about a transcript of live audio "
            + "(a call, video, lecture or meeting). Ground every answer in the transcript and its summary — "
            + "do not invent facts. If the answer isn't in the transcript, say so briefly. "
            + "Be concise and direct. Answer in \(language), regardless of the transcript's language."
        var messages: [[String: Any]] = [
            ["role": "system", "content": system],
            ["role": "user", "content": "Transcript:\n\(transcript)\n\nSummary:\n\(summary)"],
            ["role": "assistant", "content": "Understood — ask me anything about it."]
        ]
        messages.append(contentsOf: history)
        messages.append(["role": "user", "content": question])
        return try await chat(messages, apiKey: apiKey, model: model)
    }

    /// Shared chat-completions POST. Kept minimal (no temperature / max_tokens)
    /// so it works across the gpt-5 model family.
    // ponytail: sends the full transcript; truncate the oldest turns if a long
    // session ever overruns the model's context window.
    private static func chat(_ messages: [[String: Any]], apiKey: String,
                             model: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["model": model, "messages": messages]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "LiveSummarizer", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No response"])
        }
        guard http.statusCode == 200 else {
            var detail = "HTTP \(http.statusCode)"
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
                detail = msg
            }
            throw NSError(domain: "LiveSummarizer", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: detail])
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "LiveSummarizer", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Unexpected response"])
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
