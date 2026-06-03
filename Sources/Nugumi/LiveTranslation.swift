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

/// One spoken utterance paired with its translation.
///
/// The Realtime translate model streams the translation token-by-token
/// (`output_transcript.delta`) *during* speech, and emits the original as a
/// single complete `input_transcript.delta` at the *end* of each utterance. So
/// we buffer translation tokens and close a segment when the matching original
/// arrives — keeping original and translation paired and in sync (instead of
/// drifting when the two streams segment differently).
struct LiveDialogue: Equatable {
    struct Segment: Equatable {
        var original: String
        var translation: String
    }

    private(set) var segments: [Segment] = []
    private(set) var pendingTranslation = ""

    /// A streamed translation token for the in-progress utterance.
    mutating func appendTranslation(_ token: String) {
        pendingTranslation += token
    }

    /// A complete original utterance arrived → close the current segment, pairing
    /// it with the translation buffered so far.
    mutating func completeUtterance(original: String) {
        let originalText = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let translationText = pendingTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingTranslation = ""
        guard !originalText.isEmpty || !translationText.isEmpty else { return }
        segments.append(Segment(original: originalText, translation: translationText))
    }

    /// Pause/stop fallback: if translation arrived but no original closed it,
    /// flush it as a translation-only segment so nothing is lost.
    mutating func flushPending() {
        let translationText = pendingTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingTranslation = ""
        guard !translationText.isEmpty else { return }
        segments.append(Segment(original: "", translation: translationText))
    }
}

/// Which audio Live Translation listens to. One at a time — never both, to
/// avoid the same speech being transcribed twice.
enum LiveAudioSource: String, CaseIterable {
    case systemAudio
    case microphone

    var title: String {
        switch self {
        case .systemAudio: return "System audio"
        case .microphone: return "Microphone"
        }
    }

    static let defaultsKey = "liveTranslationSource"

    static var current: LiveAudioSource {
        get { LiveAudioSource(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .systemAudio }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
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

/// Logs each distinct server event type once to ~/Library/Logs/Nugumi/codex.log,
/// so we can verify which transcript events the server actually emits (e.g.
/// whether `session.input_transcript.delta` ever arrives).
enum LiveTranslationDebug {
    private static let lock = NSLock()
    private static var seen = Set<String>()
    private static var inputDumpCount = 0

    static func noteRawEvent(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        lock.lock()
        let isNew = seen.insert(type).inserted
        var dumpInput = false
        if type == "session.input_transcript.delta" {
            inputDumpCount += 1
            dumpInput = inputDumpCount <= 8
        }
        lock.unlock()
        if dumpInput {
            // Full payload so we can find which field carries the original text.
            CodexDebugLog.append("[LiveTranslation] input_transcript raw: \(json.prefix(300))")
        } else if isNew {
            CodexDebugLog.append("[LiveTranslation] event type: \(type)")
        }
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
    var onSourceDelta: ((String) -> Void)?
    var onServerError: ((String) -> Void)?
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
            // Enable source-language transcription so we also receive the original
            // text (session.input_transcript.delta). Sent as a separate update so a
            // rejection here can't drop the (working) output-language config.
            self.sendJSON([
                "type": "session.update",
                "session": ["audio": ["input": ["transcription": ["model": "whisper-1"]]]]
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
        case .translatedDelta(let text): onTranslatedDelta?(text)
        case .sourceDelta(let text): onSourceDelta?(text)
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

/// Captures the default input device via AVAudioEngine and emits 24 kHz mono
/// PCM16 byte chunks.
final class MicrophoneCapture {
    var onPCM: ((Data) -> Void)?
    var onError: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let downsampler = PCM16Downsampler()
    private var didInstallTap = false

    /// Requests mic authorization, returning whether capture may proceed.
    static func requestAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            onError?("No microphone available.")
            return
        }
        input.installTap(onBus: 0, bufferSize: 2400, format: format) { [weak self] buffer, _ in
            guard let self, let data = try? self.downsampler.pcm16Data(from: buffer) else { return }
            self.onPCM?(data)
        }
        didInstallTap = true
        do {
            try engine.start()
        } catch {
            onError?("Microphone capture failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        if didInstallTap {
            engine.inputNode.removeTap(onBus: 0)
            didInstallTap = false
        }
        engine.stop()
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
    private var isStopped = false

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
            if isStopped {
                stream.stopCapture { _ in }
                return
            }
            self.stream = stream
        } catch {
            await report("Screen recording permission is required for system-audio translation.")
        }
    }

    func stop() {
        isStopped = true
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
/// Collapsed indicator pill — a native recreation of the VoiceInput component:
/// a continuously rotating rounded-square "rec" glyph, a 12-bar animated
/// equalizer, and an elapsed timer. Drag to move the window; click (without
/// dragging) to expand back to the captions.
final class RecordIndicatorView: NSView {
    var onClick: (() -> Void)?
    var onToggleRecord: (() -> Void)?

    private let recGlyph = CAShapeLayer()
    private var bars: [CALayer] = []
    private let timeLayer = CATextLayer()
    private var isPausedState = false

    private static let barCount = 12
    private static let squareSize: CGFloat = 14
    private static let barWidth: CGFloat = 2
    private static let barGap: CGFloat = 2
    private static let timerWidth: CGFloat = 40
    private static let leadingInset: CGFloat = 14

    private var initialMouseLocation: NSPoint?
    private var initialWindowOrigin: NSPoint?
    private var didDrag = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        recGlyph.bounds = CGRect(x: 0, y: 0, width: Self.squareSize, height: Self.squareSize)
        layer?.addSublayer(recGlyph)
        updateGlyph()

        let barColor = NSColor(calibratedWhite: 1.0, alpha: 0.78).cgColor
        for _ in 0..<Self.barCount {
            let bar = CALayer()
            bar.backgroundColor = barColor
            bar.cornerRadius = Self.barWidth / 2
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: 3)
            layer?.addSublayer(bar)
            bars.append(bar)
        }

        timeLayer.string = "00:00"
        timeLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        timeLayer.fontSize = 11
        timeLayer.foregroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.55).cgColor
        timeLayer.alignmentMode = .left
        timeLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(timeLayer)
    }

    required init?(coder: NSCoder) { nil }

    func setTime(_ text: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        timeLayer.string = text
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let cy = bounds.midY
        recGlyph.position = CGPoint(x: Self.leadingInset + Self.squareSize / 2, y: cy)
        if !isPausedState && recGlyph.animation(forKey: "spin") == nil { addSpin() }

        let startX = Self.leadingInset + Self.squareSize + 10
        for (i, bar) in bars.enumerated() {
            bar.position = CGPoint(x: startX + CGFloat(i) * (Self.barWidth + Self.barGap) + Self.barWidth / 2, y: cy)
            if !isPausedState && bar.animation(forKey: "eq") == nil { addEqualizer(to: bar, index: i) }
        }

        let barsEnd = startX + CGFloat(Self.barCount) * Self.barWidth
            + CGFloat(Self.barCount - 1) * Self.barGap
        timeLayer.frame = CGRect(x: barsEnd + 10, y: cy - 7, width: Self.timerWidth, height: 14)
        CATransaction.commit()
    }

    private func addSpin() {
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = Double.pi * 2
        spin.duration = 2
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        recGlyph.add(spin, forKey: "spin")
    }

    /// Reflects paused state: the rec square becomes a play ▶ glyph and the
    /// spin/equalizer animations freeze.
    func setPaused(_ paused: Bool) {
        guard paused != isPausedState else { return }
        isPausedState = paused
        updateGlyph()
        if paused {
            recGlyph.removeAnimation(forKey: "spin")
            recGlyph.transform = CATransform3DIdentity
            bars.forEach { bar in
                bar.removeAnimation(forKey: "eq")
                bar.transform = CATransform3DIdentity
            }
        } else {
            addSpin()
            for (i, bar) in bars.enumerated() { addEqualizer(to: bar, index: i) }
        }
    }

    private func updateGlyph() {
        let size = Self.squareSize
        let path = CGMutablePath()
        if isPausedState {
            // Play ▶ triangle — "tap to continue".
            path.move(to: CGPoint(x: 2, y: 1))
            path.addLine(to: CGPoint(x: 2, y: size - 1))
            path.addLine(to: CGPoint(x: size - 1, y: size / 2))
            path.closeSubpath()
            recGlyph.fillColor = NSColor(calibratedWhite: 1.0, alpha: 0.92).cgColor
        } else {
            path.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
                                cornerWidth: 3, cornerHeight: 3, transform: nil))
            recGlyph.fillColor = NSColor.systemRed.cgColor
        }
        recGlyph.path = path
    }

    private func addEqualizer(to bar: CALayer, index: Int) {
        let anim = CAKeyframeAnimation(keyPath: "transform.scale.y")
        let peak = 2.5 + Double.random(in: 1.0...4.0)
        anim.values = [1.0, peak, 1.8, peak * 0.7, 1.0]
        anim.keyTimes = [0, 0.25, 0.5, 0.75, 1.0]
        anim.duration = 0.9 + Double.random(in: 0...0.4)
        anim.beginTime = CACurrentMediaTime() + Double(index) * 0.05
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bar.add(anim, forKey: "eq")
    }

    override func mouseDown(with event: NSEvent) {
        initialMouseLocation = NSEvent.mouseLocation
        initialWindowOrigin = window?.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startMouse = initialMouseLocation,
              let startOrigin = initialWindowOrigin,
              let window else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - startMouse.x
        let dy = current.y - startMouse.y
        if abs(dx) > 2 || abs(dy) > 2 { didDrag = true }
        window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag {
            // Clicking the rec glyph toggles pause/resume; anywhere else expands.
            let point = convert(event.locationInWindow, from: nil)
            let glyphZone = Self.leadingInset + Self.squareSize + 8
            if point.x <= glyphZone {
                onToggleRecord?()
            } else {
                onClick?()
            }
        }
        initialMouseLocation = nil
        initialWindowOrigin = nil
    }
}

/// One-shot transcript summary via OpenAI chat completions. Kept minimal (no
/// temperature / max_tokens) so it works across the gpt-5 model family.
enum LiveSummarizer {
    static func summarize(_ transcript: String, apiKey: String,
                          model: String = "gpt-5.4-mini") async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let system = "You summarize transcripts of live audio (calls, videos, lectures, meetings). "
            + "Produce a concise summary: a one-line TL;DR, then the key points as short bullets, "
            + "then any action items if present. Stay faithful to the content and reply in the same "
            + "language as the transcript."
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": transcript]
            ]
        ]
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

/// Borderless panel that can still become key (needed so the summary panel's
/// Cmd+C key equivalent fires).
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Borderless icon button with a soft rounded hover highlight — used for the
/// captions header controls (pause/minimize/close).
final class HoverIconButton: NSButton {
    var hoverColor = NSColor(calibratedWhite: 1.0, alpha: 0.14)
    var restingColor: NSColor = .clear
    var roundedFull = false
    var corner: CGFloat = 5
    private var tracking: NSTrackingArea?
    private var inside = false

    private var radius: CGFloat { roundedFull ? bounds.height / 2 : corner }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func layout() {
        super.layout()
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.backgroundColor = (inside ? hoverColor : restingColor).cgColor
    }

    override func mouseEntered(with event: NSEvent) {
        inside = true
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.backgroundColor = hoverColor.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        inside = false
        layer?.backgroundColor = restingColor.cgColor
    }
}

@MainActor
final class LiveCaptionPanelController: NSObject {
    private let panel: NSPanel
    private let indicatorPanel: NSPanel
    private let summaryPanel: KeyablePanel
    private let summaryTextView = NSTextView()
    private var summaryText = ""

    private let statusLabel = NSTextField(labelWithString: "")
    private let costLabel = NSTextField(labelWithString: "")
    private let textView = NSTextView()
    private let scrollView = NSScrollView()

    // Glass palette — mirrors TranslationPanelPalette (which is private to App.swift)
    // so the captions window matches the translate window's white-on-glass look.
    private static let glassCornerRadius: CGFloat = 22
    private static let titleColor = NSColor(calibratedWhite: 1.0, alpha: 0.84)
    private static let costColor = NSColor(calibratedWhite: 1.0, alpha: 0.45)
    private static let bodyColor = NSColor(calibratedWhite: 0.94, alpha: 0.96)
    private static let partialColor = NSColor(calibratedWhite: 1.0, alpha: 0.5)
    private static let sourceColor = NSColor(calibratedWhite: 1.0, alpha: 0.42)
    private static let iconColor = NSColor(calibratedWhite: 1.0, alpha: 0.6)
    private static let iconColorActive = NSColor(calibratedWhite: 1.0, alpha: 0.95)
    private static let selectionChip = NSColor(calibratedWhite: 1.0, alpha: 0.14)

    private var pauseButton: HoverIconButton?
    private var sourceToggleButton: NSButton?
    private var systemAudioButton: NSButton?
    private var micButton: NSButton?
    private var recordIndicator: RecordIndicatorView?
    /// Shared top-right corner (screen coords) both windows anchor to, so the
    /// captions window and the collapsed pill always appear in the same spot and
    /// remember wherever the user drags either one.
    private var anchorTopRight: NSPoint?

    var onStop: (() -> Void)?
    var onToggleCollapse: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onToggleSource: (() -> Void)?
    var onSummarize: (() -> Void)?
    var onSourceChange: ((LiveAudioSource) -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false
        )
        indicatorPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 148, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        summaryPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 480),
            styleMask: [.borderless, .resizable],
            backing: .buffered, defer: false
        )
        super.init()
        configureFloating(panel)
        configureFloating(indicatorPanel)
        configureFloating(summaryPanel)
        buildCaptions()
        buildIndicator()
        buildSummary()

        // Track user drags of either window so they share one anchor.
        for window in [panel, indicatorPanel] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(panelDidMove(_:)),
                name: NSWindow.didMoveNotification, object: window)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func cornerTopRight(of p: NSPanel) -> NSPoint {
        NSPoint(x: p.frame.maxX, y: p.frame.maxY)
    }

    private func place(_ p: NSPanel, topRight: NSPoint) {
        p.setFrameOrigin(NSPoint(x: topRight.x - p.frame.width, y: topRight.y - p.frame.height))
    }

    @objc private func panelDidMove(_ note: Notification) {
        guard let moved = note.object as? NSWindow else { return }
        if moved === indicatorPanel, indicatorPanel.isVisible {
            anchorTopRight = cornerTopRight(of: indicatorPanel)
        } else if moved === panel, panel.isVisible {
            anchorTopRight = cornerTopRight(of: panel)
        }
    }

    private func configureFloating(_ p: NSPanel) {
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
    }

    /// Installs the shared glass card (blur + hairline border) into a panel and
    /// returns the content view to lay out into.
    private func installGlass(in panel: NSPanel, cornerRadius: CGFloat) -> NSView {
        let root = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        root.autoresizingMask = [.width, .height]

        let glass = GlassHostView(frame: root.bounds, cornerRadius: cornerRadius, tintColor: nil, style: .regular)
        glass.autoresizingMask = [.width, .height]
        root.addSubview(glass)

        let chrome = GlassChromeOverlayView(frame: root.bounds)
        chrome.cornerRadius = cornerRadius
        chrome.autoresizingMask = [.width, .height]
        root.addSubview(chrome)

        panel.contentView = root
        return glass.contentView
    }

    private static let hoverNeutral = NSColor(calibratedWhite: 1.0, alpha: 0.14)
    private static let hoverDanger = NSColor.systemRed.withAlphaComponent(0.85)

    private static func symbolImage(_ name: String, _ description: String, pointSize: CGFloat = 11) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular, scale: .medium)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    private func iconButton(_ symbol: String, tint: NSColor, hover: NSColor,
                            action: Selector, help: String, pointSize: CGFloat = 11) -> HoverIconButton {
        let button = HoverIconButton(title: "", target: self, action: action)
        button.image = Self.symbolImage(symbol, help, pointSize: pointSize)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone          // render at the symbol's natural size — no squishing
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = tint
        button.hoverColor = hover
        button.toolTip = help
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// Applies a selected "chip" look (accent tint + soft accent background) to a
    /// toggle/source icon, or clears it.
    private func applySelection(_ button: NSButton?, selected: Bool) {
        guard let button = button as? HoverIconButton else { return }
        button.contentTintColor = selected ? Self.iconColorActive : Self.iconColor
        button.restingColor = selected ? Self.selectionChip : .clear
        button.wantsLayer = true
        button.layer?.cornerRadius = button.corner
        button.layer?.backgroundColor = button.restingColor.cgColor
    }

    private func roundWhiteButton(_ symbol: String, action: Selector, help: String) -> HoverIconButton {
        let button = iconButton(symbol, tint: NSColor.black.withAlphaComponent(0.82),
                                hover: NSColor(calibratedWhite: 0.86, alpha: 1.0),
                                action: action, help: help, pointSize: 13)
        button.restingColor = .white
        button.roundedFull = true
        return button
    }

    private func buildCaptions() {
        let content = installGlass(in: panel, cornerRadius: Self.glassCornerRadius)

        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.textColor = Self.titleColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        costLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        costLabel.textColor = Self.costColor
        costLabel.alignment = .right
        costLabel.translatesAutoresizingMaskIntoConstraints = false

        // Top-right window controls.
        let collapseButton = iconButton("minus", tint: Self.iconColor, hover: Self.hoverNeutral,
                                        action: #selector(collapseTapped), help: "Minimize")
        let closeButton = iconButton("xmark", tint: Self.iconColor, hover: Self.hoverDanger,
                                     action: #selector(stopTapped), help: "Stop and close")

        // Bottom toolbar.
        let pt: CGFloat = 14
        let summarizeButton = iconButton("sparkles", tint: Self.iconColor, hover: Self.hoverNeutral,
                                         action: #selector(summarizeTapped), help: "Summarize", pointSize: pt)
        let sourceToggleButton = iconButton("character.bubble", tint: Self.iconColor, hover: Self.hoverNeutral,
                                            action: #selector(sourceToggled), help: "Show original", pointSize: pt)
        self.sourceToggleButton = sourceToggleButton
        let systemAudioButton = iconButton("speaker.wave.2", tint: Self.iconColor, hover: Self.hoverNeutral,
                                           action: #selector(selectSystemAudio), help: "System audio", pointSize: pt)
        self.systemAudioButton = systemAudioButton
        let micButton = iconButton("mic", tint: Self.iconColor, hover: Self.hoverNeutral,
                                   action: #selector(selectMicrophone), help: "Microphone", pointSize: pt)
        self.micButton = micButton
        let pauseButton = roundWhiteButton("pause.fill", action: #selector(pauseTapped), help: "Pause")
        self.pauseButton = pauseButton

        let vsep1 = HairlineSeparatorView(); vsep1.translatesAutoresizingMaskIntoConstraints = false

        let separator = HairlineSeparatorView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        let bottomSeparator = HairlineSeparatorView()
        bottomSeparator.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 15)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.scrollerKnobStyle = .light
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        [statusLabel, costLabel, collapseButton, closeButton, separator, scrollView, bottomSeparator,
         summarizeButton, sourceToggleButton, vsep1, systemAudioButton, micButton, pauseButton]
            .forEach { content.addSubview($0) }

        let tb: CGFloat = 24
        NSLayoutConstraint.activate([
            // Top row: status + cost + minimize + close.
            closeButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),

            collapseButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            collapseButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            collapseButton.widthAnchor.constraint(equalToConstant: 24),
            collapseButton.heightAnchor.constraint(equalToConstant: 24),

            statusLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            costLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            costLabel.trailingAnchor.constraint(equalTo: collapseButton.leadingAnchor, constant: -10),
            costLabel.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 8),

            separator.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 10),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            separator.heightAnchor.constraint(equalToConstant: 1),

            // Transcript between separators.
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor, constant: -6),

            // Bottom toolbar: summarize · original | system · mic ......... [play].
            bottomSeparator.bottomAnchor.constraint(equalTo: summarizeButton.topAnchor, constant: -8),
            bottomSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bottomSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            bottomSeparator.heightAnchor.constraint(equalToConstant: 1),

            summarizeButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            summarizeButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            summarizeButton.widthAnchor.constraint(equalToConstant: tb),
            summarizeButton.heightAnchor.constraint(equalToConstant: tb),

            sourceToggleButton.centerYAnchor.constraint(equalTo: summarizeButton.centerYAnchor),
            sourceToggleButton.leadingAnchor.constraint(equalTo: summarizeButton.trailingAnchor, constant: 4),
            sourceToggleButton.widthAnchor.constraint(equalToConstant: tb),
            sourceToggleButton.heightAnchor.constraint(equalToConstant: tb),

            vsep1.centerYAnchor.constraint(equalTo: summarizeButton.centerYAnchor),
            vsep1.leadingAnchor.constraint(equalTo: sourceToggleButton.trailingAnchor, constant: 8),
            vsep1.widthAnchor.constraint(equalToConstant: 1),
            vsep1.heightAnchor.constraint(equalToConstant: 16),

            systemAudioButton.centerYAnchor.constraint(equalTo: summarizeButton.centerYAnchor),
            systemAudioButton.leadingAnchor.constraint(equalTo: vsep1.trailingAnchor, constant: 8),
            systemAudioButton.widthAnchor.constraint(equalToConstant: tb),
            systemAudioButton.heightAnchor.constraint(equalToConstant: tb),

            micButton.centerYAnchor.constraint(equalTo: summarizeButton.centerYAnchor),
            micButton.leadingAnchor.constraint(equalTo: systemAudioButton.trailingAnchor, constant: 4),
            micButton.widthAnchor.constraint(equalToConstant: tb),
            micButton.heightAnchor.constraint(equalToConstant: tb),

            // Prominent round white play/pause on the right.
            // Round play/pause — inset from the rounded glass corner so it isn't clipped.
            pauseButton.centerYAnchor.constraint(equalTo: summarizeButton.centerYAnchor),
            pauseButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            pauseButton.widthAnchor.constraint(equalToConstant: 30),
            pauseButton.heightAnchor.constraint(equalToConstant: 30),
            pauseButton.leadingAnchor.constraint(greaterThanOrEqualTo: micButton.trailingAnchor, constant: 8),
        ])
    }

    private func buildIndicator() {
        let content = installGlass(in: indicatorPanel, cornerRadius: 20)
        // We handle dragging ourselves (drag to move, click to expand), so don't
        // let the window also move on background drags.
        indicatorPanel.isMovableByWindowBackground = false

        let indicator = RecordIndicatorView(frame: content.bounds)
        indicator.autoresizingMask = [.width, .height]
        indicator.onClick = { [weak self] in self?.onToggleCollapse?() }
        indicator.onToggleRecord = { [weak self] in self?.onTogglePause?() }
        content.addSubview(indicator)
        recordIndicator = indicator
    }

    func setSource(_ source: LiveAudioSource) {
        applySelection(systemAudioButton, selected: source == .systemAudio)
        applySelection(micButton, selected: source == .microphone)
    }

    func showCaptions() {
        indicatorPanel.orderOut(nil)
        if anchorTopRight == nil, let screen = NSScreen.main {
            let v = screen.visibleFrame
            anchorTopRight = NSPoint(x: v.maxX - 20, y: v.maxY - 40)
        }
        if let topRight = anchorTopRight { place(panel, topRight: topRight) }
        panel.orderFrontRegardless()
    }

    func showIndicator() {
        if anchorTopRight == nil { anchorTopRight = cornerTopRight(of: panel) }
        panel.orderOut(nil)
        if let topRight = anchorTopRight { place(indicatorPanel, topRight: topRight) }
        indicatorPanel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
        indicatorPanel.orderOut(nil)
    }

    func update(status: String) { statusLabel.stringValue = status }

    func update(cost: String) {
        costLabel.stringValue = cost
        // The collapsed pill shows just the elapsed time (drop the cost tail).
        recordIndicator?.setTime(cost.components(separatedBy: " · ").first?
            .trimmingCharacters(in: .whitespaces) ?? cost)
    }

    func setPaused(_ paused: Bool) {
        pauseButton?.image = Self.symbolImage(paused ? "play.fill" : "pause.fill",
                                              paused ? "Resume" : "Pause", pointSize: 13)
        pauseButton?.toolTip = paused ? "Resume" : "Pause"
        recordIndicator?.setPaused(paused)
    }

    /// Renders paired segments — each translation with its original shown muted
    /// above (when enabled) — plus the in-progress translation as a dim partial.
    func render(_ dialogue: LiveDialogue, showSource: Bool) {
        let body = NSMutableAttributedString()
        for segment in dialogue.segments {
            if showSource, !segment.original.isEmpty {
                body.append(NSAttributedString(string: segment.original + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: Self.sourceColor
                ]))
            }
            if !segment.translation.isEmpty {
                body.append(NSAttributedString(string: segment.translation + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 15),
                    .foregroundColor: Self.bodyColor
                ]))
            }
            body.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6)]))
        }
        let pending = dialogue.pendingTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pending.isEmpty {
            body.append(NSAttributedString(string: pending, attributes: [
                .font: NSFont.systemFont(ofSize: 15),
                .foregroundColor: Self.partialColor
            ]))
        }
        textView.textStorage?.setAttributedString(body)
        // Force layout of the freshly-appended text before scrolling, otherwise
        // scrollToEndOfDocument uses stale geometry and lags behind the partial line.
        if let container = textView.textContainer, let layoutManager = textView.layoutManager {
            layoutManager.ensureLayout(for: container)
        }
        textView.scrollToEndOfDocument(nil)
    }

    func setShowSource(_ on: Bool) {
        applySelection(sourceToggleButton, selected: on)
        sourceToggleButton?.toolTip = on ? "Hide original" : "Show original"
    }

    private func buildSummary() {
        let content = installGlass(in: summaryPanel, cornerRadius: Self.glassCornerRadius)

        let title = NSTextField(labelWithString: "Summary")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = Self.titleColor
        title.translatesAutoresizingMaskIntoConstraints = false

        let copyButton = iconButton("doc.on.doc", tint: Self.iconColor, hover: Self.hoverNeutral,
                                    action: #selector(copySummaryTapped), help: "Copy summary (⌘C)")
        copyButton.keyEquivalent = "c"
        copyButton.keyEquivalentModifierMask = .command
        let closeButton = iconButton("xmark", tint: Self.iconColor, hover: Self.hoverDanger,
                                     action: #selector(closeSummaryTapped), help: "Close")

        summaryTextView.isEditable = false
        summaryTextView.isSelectable = true
        summaryTextView.drawsBackground = false
        summaryTextView.font = .systemFont(ofSize: 14)
        summaryTextView.textColor = Self.bodyColor
        summaryTextView.textContainerInset = NSSize(width: 6, height: 8)
        summaryTextView.isVerticallyResizable = true
        summaryTextView.isHorizontallyResizable = false
        summaryTextView.autoresizingMask = [.width]
        summaryTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        summaryTextView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.documentView = summaryTextView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.scrollerKnobStyle = .light
        scroll.translatesAutoresizingMaskIntoConstraints = false

        [title, copyButton, closeButton, scroll].forEach { content.addSubview($0) }
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 11),
            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),
            copyButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            copyButton.widthAnchor.constraint(equalToConstant: 22),
            copyButton.heightAnchor.constraint(equalToConstant: 22),
            title.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    func showSummary(_ text: String) {
        summaryText = text
        summaryTextView.string = text
        summaryTextView.textColor = Self.bodyColor
        if summaryPanel.frame.origin == .zero, let screen = NSScreen.main {
            let v = screen.visibleFrame
            summaryPanel.setFrameOrigin(NSPoint(x: v.midX - summaryPanel.frame.width / 2,
                                                y: v.midY - summaryPanel.frame.height / 2))
        }
        summaryPanel.makeKeyAndOrderFront(nil)
    }

    func copySummary() {
        guard !summaryText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summaryText, forType: .string)
    }

    @objc private func stopTapped() { onStop?() }
    @objc private func collapseTapped() { onToggleCollapse?() }
    @objc private func pauseTapped() { onTogglePause?() }
    @objc private func sourceToggled() { onToggleSource?() }
    @objc private func summarizeTapped() { onSummarize?() }
    @objc private func copySummaryTapped() { copySummary() }
    @objc private func closeSummaryTapped() { summaryPanel.orderOut(nil) }
    @objc private func selectSystemAudio() { onSourceChange?(.systemAudio) }
    @objc private func selectMicrophone() { onSourceChange?(.microphone) }
}

/// Owns the live-translation lifecycle: single switchable audio source,
/// sentence-segmented transcript, collapsible panel.
@MainActor
final class LiveTranslationController: NSObject {
    static let perMinuteCostUSD = 0.034

    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var isCollapsed = false
    private let panel = LiveCaptionPanelController()
    private var dialogue = LiveDialogue()
    private var showSource: Bool {
        get { UserDefaults.standard.object(forKey: "liveTranslationShowSource") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "liveTranslationShowSource") }
    }
    private var systemCapture: SystemAudioCapture?
    private var micCapture: MicrophoneCapture?
    private var session: RealtimeTranslationSession?
    private var elapsedTimer: Timer?
    private var pauseTimer: Timer?
    private var startGeneration = 0
    private var activeSource: LiveAudioSource = .systemAudio
    private var targetLanguage: TranslationLanguage = .defaultLanguage
    private var apiKey: String = ""

    // Active-time accounting. Pause freezes it, so cost/billing only count the
    // time audio is actually streaming, not wall-clock since first start.
    private var accumulatedSeconds: TimeInterval = 0
    private var segmentStart: Date?

    var onMissingAPIKey: (() -> Void)?

    func toggle(apiKey: String?, targetLanguage: TranslationLanguage) {
        if isPaused {
            resume()
        } else if isRunning {
            toggleCollapsed()
        } else {
            start(apiKey: apiKey, targetLanguage: targetLanguage)
        }
    }

    func start(apiKey: String?, targetLanguage: TranslationLanguage) {
        guard let apiKey, !apiKey.isEmpty else { onMissingAPIKey?(); return }
        guard !isRunning, !isPaused else { return }
        self.apiKey = apiKey
        self.targetLanguage = targetLanguage
        dialogue = LiveDialogue()
        accumulatedSeconds = 0
        isCollapsed = false

        panel.onStop = { [weak self] in self?.stop() }
        panel.onToggleCollapse = { [weak self] in self?.toggleCollapsed() }
        panel.onTogglePause = { [weak self] in self?.togglePauseResume() }
        panel.onToggleSource = { [weak self] in self?.toggleSource() }
        panel.onSummarize = { [weak self] in self?.summarize() }
        panel.onSourceChange = { [weak self] newSource in self?.changeSource(to: newSource) }
        panel.setSource(LiveAudioSource.current)
        panel.setShowSource(showSource)
        renderTranscripts()
        panel.update(cost: "00:00 · ~$0.00")
        panel.showCaptions()

        launchSession()
    }

    private func renderTranscripts() {
        panel.render(dialogue, showSource: showSource)
    }

    private func toggleSource() {
        showSource.toggle()
        panel.setShowSource(showSource)
        renderTranscripts()
    }

    private func currentStatusText() -> String {
        if isPaused { return "Paused — press play to continue" }
        if isRunning { return "Listening → \(targetLanguage.displayName)" }
        return "Stopped"
    }

    private func summarize() {
        let text = dialogue.segments.map(\.translation).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { panel.update(status: "Nothing to summarize yet."); return }
        guard !apiKey.isEmpty else { onMissingAPIKey?(); return }
        panel.update(status: "Summarizing…")
        let key = apiKey
        Task { [weak self] in
            do {
                let summary = try await LiveSummarizer.summarize(text, apiKey: key)
                guard let self else { return }
                self.panel.showSummary(summary)
                self.panel.update(status: self.currentStatusText())
            } catch {
                self?.panel.update(status: "Summary failed: \(error.localizedDescription)")
            }
        }
    }

    /// Spins up a session + capture + timers for the current source, keeping the
    /// existing transcript. Shared by start() (fresh transcript) and resume().
    private func launchSession() {
        isRunning = true
        isPaused = false
        startGeneration += 1
        segmentStart = Date()
        let source = LiveAudioSource.current
        activeSource = source
        panel.setPaused(false)
        panel.update(status: "Connecting… → \(targetLanguage.displayName)")

        let session = RealtimeTranslationSession(
            apiKey: apiKey,
            languageCode: LiveTranslationLanguage.apiCode(for: targetLanguage),
            safetyIdentifier: LiveTranslationController.safetyIdentifier()
        )
        session.onTranslatedDelta = { [weak self] delta in
            guard let self else { return }
            self.dialogue.appendTranslation(delta)
            self.renderTranscripts()
            self.reschedulePauseFinalize()
        }
        session.onSourceDelta = { [weak self] original in
            guard let self else { return }
            // A complete original utterance closes the current segment, pairing it
            // with the translation buffered so far.
            self.dialogue.completeUtterance(original: original)
            self.renderTranscripts()
        }
        session.onServerError = { [weak self] message in
            // Non-fatal: surface briefly, keep translating.
            self?.panel.update(status: "⚠︎ \(message)")
        }
        session.onStatusChange = { [weak self] status in
            guard let self else { return }
            if case .failed(let message) = status {
                self.stop(finalStatus: "Error: \(message) — stopped.", keepVisible: true)
            } else {
                self.panel.update(status: Self.statusText(status, language: self.targetLanguage))
            }
        }
        session.connect()
        self.session = session

        startCapture(source, into: session, generation: startGeneration)
        startCostTimer()
    }

    func togglePauseResume() {
        if isPaused { resume() }
        else if isRunning { pause() }
    }

    /// Stops capture + billing but keeps the transcript and panel open so the
    /// user can resume into the same history.
    func pause() {
        guard isRunning else { return }
        isRunning = false
        isPaused = true
        accumulateActiveTime()
        teardownCaptureAndSession()
        dialogue.flushPending()
        renderTranscripts()
        panel.setPaused(true)
        panel.update(status: "Paused — press play to continue")
        updateCost()
    }

    func resume() {
        guard isPaused else { return }
        panel.update(status: "Resuming…")
        launchSession()
    }

    private func teardownCaptureAndSession() {
        pauseTimer?.invalidate(); pauseTimer = nil
        elapsedTimer?.invalidate(); elapsedTimer = nil
        session?.onStatusChange = nil
        systemCapture?.stop(); systemCapture = nil
        micCapture?.stop(); micCapture = nil
        session?.close(); session = nil
    }

    private func startCapture(_ source: LiveAudioSource, into session: RealtimeTranslationSession, generation: Int) {
        switch source {
        case .systemAudio:
            let capture = SystemAudioCapture()
            capture.onPCM = { [weak session] data in session?.append(pcm: data) }
            capture.onError = { [weak self] message in self?.panel.update(status: message) }
            systemCapture = capture
            Task { await capture.start() }
        case .microphone:
            Task { [weak self] in
                guard await MicrophoneCapture.requestAuthorization() else {
                    self?.panel.update(status: "Microphone access denied — enable it in System Settings ▸ Privacy ▸ Microphone.")
                    return
                }
                guard let self, self.isRunning, self.startGeneration == generation else { return }
                let mic = MicrophoneCapture()
                mic.onPCM = { [weak session] data in session?.append(pcm: data) }
                mic.onError = { [weak self] message in self?.panel.update(status: message) }
                mic.start()
                self.micCapture = mic
            }
        }
    }

    private func changeSource(to newSource: LiveAudioSource) {
        LiveAudioSource.current = newSource
        guard newSource != activeSource else { return }
        activeSource = newSource
        panel.setSource(newSource)
        guard isRunning, let session else { return }
        startGeneration += 1
        systemCapture?.stop(); systemCapture = nil
        micCapture?.stop(); micCapture = nil
        panel.update(status: "Switching to \(newSource.title)…")
        startCapture(newSource, into: session, generation: startGeneration)
    }

    func toggleCollapsed() {
        guard isRunning || isPaused else { return }
        isCollapsed.toggle()
        if isCollapsed { panel.showIndicator() } else { panel.showCaptions() }
    }

    func stop(finalStatus: String = "Stopped", keepVisible: Bool = false) {
        guard isRunning || isPaused else { return }
        isRunning = false
        isPaused = false
        isCollapsed = false
        accumulateActiveTime()
        teardownCaptureAndSession()
        dialogue.flushPending()
        panel.setPaused(false)
        renderTranscripts()
        panel.update(status: finalStatus)
        if keepVisible { panel.showCaptions() } else { panel.close() }
    }

    private func reschedulePauseFinalize() {
        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 1.3, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.dialogue.flushPending()
                self.renderTranscripts()
            }
        }
    }

    private func startCostTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateCost() }
        }
        updateCost()
    }

    private func accumulateActiveTime() {
        if let segmentStart {
            accumulatedSeconds += Date().timeIntervalSince(segmentStart)
            self.segmentStart = nil
        }
    }

    private func totalActiveSeconds() -> TimeInterval {
        accumulatedSeconds + (segmentStart.map { Date().timeIntervalSince($0) } ?? 0)
    }

    private func updateCost() {
        let seconds = totalActiveSeconds()
        let cost = (seconds / 60.0) * Self.perMinuteCostUSD
        let elapsed = Int(seconds)
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
