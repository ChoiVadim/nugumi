import AppKit
import AVFoundation
import Foundation
import ScreenCaptureKit

/// Maps Nugumi's target-language setting to the ISO code the Realtime
/// translation API expects in `session.audio.output.language`.
enum LiveTranslationLanguage {
    static func apiCode(for language: TranslationLanguage) -> String {
        switch language.id {
        case "zh-Hans": return "zh"
        default: return language.id
        }
    }
}

enum CaptionSpeaker: Equatable {
    case them   // system audio
    case me     // microphone

    var label: String {
        switch self {
        case .them: return "Them"
        case .me: return "Me"
        }
    }
}

struct CaptionLine: Equatable {
    let speaker: CaptionSpeaker
    var text: String
    var isFinalized: Bool
}

/// Ordered caption lines. Output deltas append to the current open line; a
/// speaker change or an explicit finalize closes it and opens a new one.
struct LiveTranscript {
    private(set) var lines: [CaptionLine] = []

    mutating func appendDelta(speaker: CaptionSpeaker, text: String) {
        if let last = lines.last, !last.isFinalized, last.speaker == speaker {
            lines[lines.count - 1].text += text
        } else {
            finalizeCurrent() // close the open line (no-op if empty/already finalized)
            lines.append(CaptionLine(speaker: speaker, text: text, isFinalized: false))
        }
    }

    mutating func finalizeCurrent() {
        guard let last = lines.last, !last.isFinalized else { return }
        lines[lines.count - 1].isFinalized = true
    }
}

/// Accumulates raw PCM bytes and flushes whole chunks once they reach a byte
/// threshold (~100 ms), so we send fewer, larger `input_audio_buffer.append`
/// frames instead of one per capture callback.
///
/// Thread-safe. The flush callback runs outside the lock, so `onChunk` may be
/// called from the caller's thread; it must not assume the batcher's internal
/// lock is held.
final class AudioBatcher {
    private let thresholdBytes: Int
    private let onChunk: (Data) -> Void
    private var buffer = Data()
    private let lock = NSLock()

    init(thresholdBytes: Int, onChunk: @escaping (Data) -> Void) {
        self.thresholdBytes = thresholdBytes
        self.onChunk = onChunk
    }

    func add(_ data: Data) {
        lock.lock()
        buffer.append(data)
        guard buffer.count >= thresholdBytes else { lock.unlock(); return }
        let chunk = buffer
        buffer = Data()
        lock.unlock()
        onChunk(chunk)
    }

    func flush() {
        lock.lock()
        guard !buffer.isEmpty else { lock.unlock(); return }
        let chunk = buffer
        buffer = Data()
        lock.unlock()
        onChunk(chunk)
    }
}

/// Typed view over the Realtime translation socket's server events. Unknown or
/// malformed payloads decode to `.ignored` so a protocol drift can never crash
/// the receive loop.
enum RealtimeServerEvent: Equatable {
    case translatedDelta(String)
    case sourceDelta(String)
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
        switch type {
        case "session.output_transcript.delta":
            self = (root["delta"] as? String).map(RealtimeServerEvent.translatedDelta) ?? .ignored
        case "session.input_transcript.delta":
            self = (root["delta"] as? String).map(RealtimeServerEvent.sourceDelta) ?? .ignored
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

/// Converts arbitrary-format capture buffers to the Realtime API's required
/// 24 kHz mono PCM16 little-endian byte stream. One converter is lazily built
/// per distinct input format.
///
/// Not internally synchronized: use one instance per capture source, fed from
/// that source's single serial callback queue.
final class PCM16Downsampler {
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true
    )!

    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    func pcm16Data(from input: AVAudioPCMBuffer) throws -> Data {
        let inputFormat = input.format
        if converter == nil || converterInputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat)
            converterInputFormat = inputFormat
        }
        guard let converter else {
            throw NSError(domain: "PCM16Downsampler", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No audio converter available for input format \(inputFormat)"
            ])
        }

        let ratio = Self.targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else {
            return Data()
        }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, statusPtr in
            if consumed {
                statusPtr.pointee = .noDataNow
                return nil
            }
            consumed = true
            statusPtr.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }

        guard let channel = output.int16ChannelData else { return Data() }
        return Data(bytes: channel[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}

/// One WebSocket to `gpt-realtime-translate` for a single audio direction.
/// Sends 24 kHz PCM16 audio up; surfaces translated transcript deltas.
final class RealtimeTranslationSession: NSObject, URLSessionWebSocketDelegate {
    enum Status: Equatable { case connecting, listening, reconnecting, failed(String), closed }

    var onTranslatedDelta: ((String) -> Void)?
    var onStatusChange: ((Status) -> Void)?

    private let apiKey: String
    private let languageCode: String
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
                    let event = RealtimeServerEvent(jsonString: text)
                    DispatchQueue.main.async { [weak self] in self?.handle(event: event) }
                }
                self.receiveNext()
            }
        }
    }

    private func handle(event: RealtimeServerEvent) {
        switch event {
        case .translatedDelta(let text): onTranslatedDelta?(text)
        case .error(let message): onStatusChange?(.failed(message))
        case .closed: onStatusChange?(.closed)
        case .sourceDelta, .ignored: break
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

/// Captures system/app audio via ScreenCaptureKit, downsamples to 24 kHz mono
/// PCM16, and emits byte chunks. Audio-only: a minimal display filter is required
/// even though we discard video.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onPCM: ((Data) -> Void)?
    var onError: ((String) -> Void)?

    private var stream: SCStream?
    private let downsampler = PCM16Downsampler()
    private let sampleQueue = DispatchQueue(label: "com.nugumi.live.systemaudio")

    func start() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                               onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                await report("No display available for audio capture.")
                return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 24000
            config.channelCount = 1
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.showsCursor = false

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
            self.stream = stream
        } catch {
            await report("Screen recording permission is required for system-audio translation.")
        }
    }

    func stop() {
        let capturingStream = stream
        stream = nil
        capturingStream?.stopCapture { _ in }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio,
              let pcmBuffer = sampleBuffer.toPCMBuffer(),
              let data = try? downsampler.pcm16Data(from: pcmBuffer) else { return }
        onPCM?(data)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { await report("System-audio capture stopped: \(error.localizedDescription)") }
    }

    @MainActor private func report(_ message: String) { onError?(message) }
}

private extension CMSampleBuffer {
    /// Convert a CMSampleBuffer of audio into an AVAudioPCMBuffer.
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        let format = AVAudioFormat(streamDescription: asbd)
        guard let format else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}

/// Floating, draggable, always-on-top captions window. Pure view layer — the
/// controller pushes transcript + status updates in.
@MainActor
final class LiveCaptionPanelController: NSObject {
    private let panel: NSPanel
    private let statusLabel = NSTextField(labelWithString: "")
    private let costLabel = NSTextField(labelWithString: "")
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    var onStop: (() -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false
        )
        super.init()

        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96)
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true

        let root = NSView(frame: panel.contentLayoutRect)
        root.autoresizingMask = [.width, .height]

        statusLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        costLabel.font = .systemFont(ofSize: 11)
        costLabel.textColor = .tertiaryLabelColor
        costLabel.alignment = .right
        costLabel.translatesAutoresizingMaskIntoConstraints = false

        let stopButton = NSButton(title: "Stop", target: self, action: #selector(stopTapped))
        stopButton.bezelStyle = .rounded
        stopButton.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(statusLabel)
        root.addSubview(costLabel)
        root.addSubview(stopButton)
        root.addSubview(scrollView)
        panel.contentView = root

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            costLabel.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            costLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: stopButton.topAnchor, constant: -8),
            stopButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            stopButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
        ])
    }

    func show() {
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - 440, y: visible.minY + 40))
        }
        panel.orderFrontRegardless()
    }

    func close() { panel.orderOut(nil) }

    func update(status: String) { statusLabel.stringValue = status }
    func update(cost: String) { costLabel.stringValue = cost }

    func render(_ transcript: LiveTranscript) {
        let body = NSMutableAttributedString()
        for line in transcript.lines {
            let speaker = NSAttributedString(string: "\(line.speaker.label): ", attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .bold),
                .foregroundColor: line.speaker == .me ? NSColor.systemBlue : NSColor.systemGreen
            ])
            let text = NSAttributedString(string: line.text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: line.isFinalized ? NSColor.labelColor : NSColor.secondaryLabelColor
            ])
            body.append(speaker); body.append(text)
        }
        textView.textStorage?.setAttributedString(body)
        textView.scrollToEndOfDocument(nil)
    }

    @objc private func stopTapped() { onStop?() }
}

/// Owns the live-translation lifecycle for Phase 1 (system audio only).
@MainActor
final class LiveTranslationController: NSObject {
    static let perMinuteCostUSD = 0.034

    private(set) var isRunning = false
    private let panel = LiveCaptionPanelController()
    private var transcript = LiveTranscript()
    private var systemCapture: SystemAudioCapture?
    private var systemSession: RealtimeTranslationSession?
    private var elapsedTimer: Timer?
    private var startDate: Date?
    /// Number of concurrently billed sessions (1 in Phase 1, 2 in Phase 2).
    private var activeSessionCount = 1

    var onMissingAPIKey: (() -> Void)?

    func toggle(apiKey: String?, targetLanguage: TranslationLanguage) {
        if isRunning { stop() } else { start(apiKey: apiKey, targetLanguage: targetLanguage) }
    }

    func start(apiKey: String?, targetLanguage: TranslationLanguage) {
        guard let apiKey, !apiKey.isEmpty else { onMissingAPIKey?(); return }
        guard !isRunning else { return }
        isRunning = true
        transcript = LiveTranscript()
        startDate = Date()

        panel.onStop = { [weak self] in self?.stop() }
        panel.show()
        panel.render(transcript)
        panel.update(status: "Connecting… → \(targetLanguage.displayName)")

        let languageCode = LiveTranslationLanguage.apiCode(for: targetLanguage)
        let session = RealtimeTranslationSession(
            apiKey: apiKey,
            languageCode: languageCode,
            safetyIdentifier: LiveTranslationController.safetyIdentifier()
        )
        session.onTranslatedDelta = { [weak self] delta in
            guard let self else { return }
            self.transcript.appendDelta(speaker: .them, text: delta)
            self.panel.render(self.transcript)
        }
        session.onStatusChange = { [weak self] status in
            self?.panel.update(status: Self.statusText(status, language: targetLanguage))
        }
        session.connect()
        systemSession = session

        let capture = SystemAudioCapture()
        capture.onPCM = { [weak session] data in session?.append(pcm: data) }
        capture.onError = { [weak self] message in self?.panel.update(status: message) }
        systemCapture = capture
        Task { await capture.start() }

        startCostTimer()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        elapsedTimer?.invalidate(); elapsedTimer = nil
        systemCapture?.stop(); systemCapture = nil
        systemSession?.close(); systemSession = nil
        transcript.finalizeCurrent()
        panel.render(transcript)
        panel.update(status: "Stopped")
    }

    private func startCostTimer() {
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateCost() }
        }
        updateCost()
    }

    private func updateCost() {
        guard let startDate else { return }
        let minutes = Date().timeIntervalSince(startDate) / 60.0
        let cost = minutes * Self.perMinuteCostUSD * Double(activeSessionCount)
        let elapsed = Int(Date().timeIntervalSince(startDate))
        panel.update(cost: String(format: "%02d:%02d · ~$%.2f", elapsed / 60, elapsed % 60, cost))
    }

    private static func statusText(_ status: RealtimeTranslationSession.Status,
                                   language: TranslationLanguage) -> String {
        switch status {
        case .connecting: return "Connecting… → \(language.displayName)"
        case .listening: return "Listening → \(language.displayName)"
        case .reconnecting: return "Reconnecting…"
        case .failed(let message): return "Error: \(message)"
        case .closed: return "Stopped"
        }
    }

    /// Stable, non-identifying per-install id for OpenAI-Safety-Identifier.
    private static func safetyIdentifier() -> String {
        let key = "liveTranslationSafetyID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }
}
