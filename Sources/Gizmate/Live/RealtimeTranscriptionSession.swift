import Foundation

// MARK: - Dictation

/// WebSocket session against OpenAI's realtime transcription intent
/// (`/v1/realtime?intent=transcription`). Speech-to-text only — no
/// translation, language auto-detected. Emits one callback per completed
/// utterance (server VAD decides the phrase boundaries).
final class RealtimeTranscriptionSession: NSObject, URLSessionWebSocketDelegate {
    var onPhrase: ((String) -> Void)?
    var onFailed: ((String) -> Void)?

    private let apiKey: String
    private let safetyIdentifier: String
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private lazy var batcher = AudioBatcher(thresholdBytes: 4800) { [weak self] chunk in
        self?.sendJSON(["type": "input_audio_buffer.append",
                        "audio": chunk.base64EncodedString()])
    }
    private var isClosing = false
    private var reconnectAttempts = 0
    private let taskLock = NSLock()
    private var reconnectScheduled = false

    init(apiKey: String, safetyIdentifier: String) {
        self.apiKey = apiKey
        self.safetyIdentifier = safetyIdentifier
    }

    func connect() {
        session?.invalidateAndCancel()
        isClosing = false
        reconnectScheduled = false
        var request = URLRequest(
            url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
        )
        // GA protocol only — an `OpenAI-Beta: realtime=v1` header now gets the
        // socket killed with `beta_api_shape_disabled` before any event flows.
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(safetyIdentifier, forHTTPHeaderField: "OpenAI-Safety-Identifier")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let newTask = session.webSocketTask(with: request)
        self.session = session
        setTask(newTask)
        newTask.resume()
        receiveNext()
    }

    /// Feed raw 24 kHz mono PCM16 bytes; batched and sent as base64.
    func append(pcm: Data) {
        batcher.add(pcm)
    }

    func close() {
        isClosing = true
        batcher.flush()
        let closingTask = currentTask()
        let closingSession = session
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            closingTask?.cancel(with: .normalClosure, reason: nil)
            closingSession?.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reconnectAttempts = 0
            self.reconnectScheduled = false
            // GA session shape (verified live 2026-07-24): the beta
            // `transcription_session.update` flat form is rejected.
            self.sendJSON([
                "type": "session.update",
                "session": [
                    "type": "transcription",
                    "audio": ["input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": ["model": "gpt-4o-transcribe"],
                        "turn_detection": ["type": "server_vad", "silence_duration_ms": 600]
                    ]]
                ]
            ])
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isClosing, !self.reconnectScheduled else { return }
            self.scheduleReconnect()
        }
    }

    private func receiveNext() {
        currentTask()?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isClosing, !self.reconnectScheduled else { return }
                    self.scheduleReconnect()
                }
            case .success(let message):
                if case let .string(text) = message,
                   let data = text.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    DispatchQueue.main.async { [weak self] in self?.handle(object) }
                }
                self.receiveNext()
            }
        }
    }

    private func handle(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = event["transcript"] as? String { onPhrase?(transcript) }
        case "error":
            // Server error events are non-fatal (mirrors the translations
            // session) — the socket-level failure path handles dead sessions.
            break
        default:
            break
        }
    }

    private func currentTask() -> URLSessionWebSocketTask? {
        taskLock.lock(); defer { taskLock.unlock() }
        return task
    }

    private func setTask(_ newTask: URLSessionWebSocketTask?) {
        taskLock.lock(); defer { taskLock.unlock() }
        task = newTask
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return }
        currentTask()?.send(.string(string)) { _ in }
    }

    private func scheduleReconnect() {
        reconnectScheduled = true
        reconnectAttempts += 1
        guard reconnectAttempts <= 5 else {
            onFailed?("Connection lost")
            return
        }
        let delay = min(pow(2.0, Double(reconnectAttempts)), 16.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isClosing else { return }
            self.connect()
        }
    }
}
