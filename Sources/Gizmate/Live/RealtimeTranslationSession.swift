import Foundation


/// Logs each distinct server event type once to ~/Library/Logs/Gizmate/codex.log,
/// so we can verify which transcript events the server actually emits (e.g.
/// whether `session.input_transcript.delta` ever arrives).
enum LiveTranslationDebug {
    private static let lock = NSLock()
    private static var seen = Set<String>()
    private static var dumpCounts: [String: Int] = [:]

    static func noteRawEvent(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        lock.lock()
        let isNew = seen.insert(type).inserted
        // Dump full payloads of the first few input/output transcript events so we
        // can see delta granularity and whether elapsed_ms (audio timing) is set.
        var dump = false
        if type == "session.input_transcript.delta" || type == "session.output_transcript.delta" {
            let n = (dumpCounts[type] ?? 0) + 1
            dumpCounts[type] = n
            dump = n <= 8
        }
        lock.unlock()
        if dump {
            CodexDebugLog.append("[LiveTranslation] raw: \(json.prefix(320))")
        } else if isNew {
            CodexDebugLog.append("[LiveTranslation] event type: \(type)")
        }
    }
}

/// Typed view over the Realtime translation socket's server events. Unknown or
/// malformed payloads decode to `.ignored` so a protocol drift can never crash
/// the receive loop.
enum RealtimeServerEvent: Equatable {
    case translatedDelta(String, ms: Int?)
    case sourceDelta(String, ms: Int?)
    case closed
    case error(String)
    case ignored

    init(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String else {
            self = .ignored
            return
        }
        let ms = root["elapsed_ms"] as? Int
        switch type {
        case "session.output_transcript.delta":
            self = (root["delta"] as? String).map { .translatedDelta($0, ms: ms) } ?? .ignored
        case "session.input_transcript.delta":
            self = (root["delta"] as? String).map { .sourceDelta($0, ms: ms) } ?? .ignored
        case "session.closed":
            self = .closed
        case "error":
            let message = (root["error"] as? [String: Any])?["message"] as? String
            self = .error(message ?? "Realtime session error")
        default:
            self = .ignored
        }
    }
}

/// One WebSocket to `gpt-realtime-translate` for a single audio direction.
/// Sends 24 kHz PCM16 audio up; surfaces translated transcript deltas.
final class RealtimeTranslationSession: NSObject, URLSessionWebSocketDelegate {
    enum Status: Equatable { case connecting, listening, reconnecting, failed(String), closed }

    var onTranslatedDelta: ((String, Int?) -> Void)?
    var onSourceDelta: ((String, Int?) -> Void)?
    var onServerError: ((String) -> Void)?
    var onStatusChange: ((Status) -> Void)?

    private let apiKey: String
    private var languageCode: String
    private let safetyIdentifier: String
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private lazy var batcher = AudioBatcher(thresholdBytes: 4800) { [weak self] chunk in
        self?.sendAudioChunk(chunk)
    }
    private var isClosing = false
    private var reconnectAttempts = 0
    private let taskLock = NSLock()
    private var reconnectScheduled = false

    init(apiKey: String, languageCode: String, safetyIdentifier: String) {
        self.apiKey = apiKey
        self.languageCode = languageCode
        self.safetyIdentifier = safetyIdentifier
    }

    func connect() {
        session?.invalidateAndCancel()   // break the old session->delegate(self) retain cycle
        isClosing = false
        reconnectScheduled = false
        onStatusChange?(reconnectAttempts == 0 ? .connecting : .reconnecting)

        var request = URLRequest(
            url: URL(string: "wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate")!
        )
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

    /// Change the translation output language on the fly (and keep it for reconnects).
    func setLanguage(_ code: String) {
        languageCode = code
        sendJSON(["type": "session.update",
                  "session": ["audio": ["output": ["language": code]]]])
    }

    func close() {
        isClosing = true
        batcher.flush()
        sendJSON(["type": "session.close"])
        let closingTask = currentTask()
        let closingSession = session
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            closingTask?.cancel(with: .normalClosure, reason: nil)
            closingSession?.invalidateAndCancel()
        }
        onStatusChange?(.closed)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reconnectAttempts = 0
            self.reconnectScheduled = false
            self.sendJSON([
                "type": "session.update",
                "session": ["audio": ["output": ["language": self.languageCode]]]
            ])
            // Enable source-language transcription so we also receive the original
            // text (session.input_transcript.delta). Sent as a separate update so a
            // rejection here can't drop the (working) output-language config.
            // NOTE: this endpoint rejects a `transcription.language` hint ("Unknown
            // parameter") — the translate model auto-detects the source. Don't add it.
            self.sendJSON([
                "type": "session.update",
                "session": ["audio": ["input": ["transcription": ["model": "gpt-realtime-whisper"]]]]
            ])
            self.onStatusChange?(.listening)
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
                if case let .string(text) = message {
                    LiveTranslationDebug.noteRawEvent(text)
                    let event = RealtimeServerEvent(jsonString: text)
                    DispatchQueue.main.async { [weak self] in self?.handle(event: event) }
                }
                self.receiveNext()
            }
        }
    }

    private func handle(event: RealtimeServerEvent) {
        switch event {
        case let .translatedDelta(text, ms): onTranslatedDelta?(text, ms)
        case let .sourceDelta(text, ms): onSourceDelta?(text, ms)
        case .error(let message): onServerError?(message)   // non-fatal; keep the session
        case .closed: onStatusChange?(.closed)
        case .ignored: break
        }
    }

    private func sendAudioChunk(_ pcm: Data) {
        sendJSON(["type": "session.input_audio_buffer.append",
                  "audio": pcm.base64EncodedString()])
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
            onStatusChange?(.failed("Connection lost"))
            return
        }
        let delay = min(pow(2.0, Double(reconnectAttempts)), 16.0)
        onStatusChange?(.reconnecting)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isClosing else { return }
            self.connect()
        }
    }
}
