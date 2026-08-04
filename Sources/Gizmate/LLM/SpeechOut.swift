import AVFoundation
import Foundation

/// Reads a gizmo's answer out loud — the `.speak` result mode.
///
/// OpenAI's `/v1/audio/speech` when a key is on file, macOS's own synthesizer
/// when it isn't. The fallback is not a nicety: plenty of installs run entirely
/// on local Ollama and have never added an OpenAI key, and a result mode that
/// stays silent for them is a button that looks broken.
@MainActor
enum SpeechOut {
    /// OpenAI's ceiling for one request. Past it the call 400s, so a long
    /// answer is spoken up to here rather than not at all.
    private static let inputLimit = 4096

    /// Held, not local: `AVAudioPlayer` stops the moment it deallocates, so a
    /// player that only lives inside `play` never makes a sound.
    private static var player: AVAudioPlayer?
    private static let synthesizer = AVSpeechSynthesizer()

    /// One of the voices in OpenAI's TTS guide (alloy, ash, ballad, coral,
    /// echo, fable, nova, onyx, sage, shimmer, verse, marin, cedar). A defaults
    /// key rather than a settings row until someone asks to change it.
    private static var voice: String {
        UserDefaults.standard.string(forKey: "gizmoSpeechVoice") ?? "alloy"
    }

    static func speak(_ text: String) {
        let spoken = String(text.prefix(inputLimit))
        guard !spoken.isEmpty else { return }
        // Two answers talking over each other is worse than either alone.
        stop()
        guard let key = KeychainStore.apiKey(for: .openAI) else {
            speakLocally(spoken)
            return
        }
        Task { @MainActor in
            guard let data = try? await synthesize(spoken, key: key), play(data) else {
                speakLocally(spoken)
                return
            }
        }
    }

    static func stop() {
        player?.stop()
        player = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    private static func synthesize(_ text: String, key: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-4o-mini-tts",
            "voice": voice,
            "input": text,
            "response_format": "mp3"
        ])
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func play(_ data: Data) -> Bool {
        guard let made = try? AVAudioPlayer(data: data) else { return false }
        player = made
        return made.play()
    }

    private static func speakLocally(_ text: String) {
        synthesizer.speak(AVSpeechUtterance(string: text))
    }
}
