import AppKit
import AVFoundation
import Carbon.HIToolbox
import Foundation
import ScreenCaptureKit

/// Maps Gizmate's target-language setting to the ISO code the Realtime
/// translation API expects in `session.audio.output.language`.
enum LiveTranslationLanguage {
    static func apiCode(for language: TranslationLanguage) -> String {
        switch language.id {
        case "zh-Hans": return "zh"
        default: return language.id
        }
    }

}

/// Source STT and its streaming translation, shown as TWO DECOUPLED streams.
///
/// The two realtime streams (`input_transcript.delta` = source, `output_transcript.delta`
/// = translation) lag each other by a variable amount that even flips sign (the
/// translation sometimes leads, sometimes trails the source). Forcing them into
/// paired rows therefore always drifts or merges on some audio. Instead each stream
/// is segmented into its own sentence-sized entries and they're rendered in the
/// order their first tokens arrived — interleaved by time, never paired. No lag to
/// estimate, nothing to mis-anchor: each sentence is its own row.
struct LiveDialogue: Equatable {
    /// A display row carries EITHER source OR translation (the other side empty) —
    /// the struct keeps both fields so the renderer/tests stay unchanged.
    struct Row: Equatable {
        var source: String
        var translation: String
    }

    private struct Entry: Equatable {
        var text: String = ""
        let isSource: Bool
    }

    /// A source pause this long starts a new source entry — long enough to be a
    /// sentence break, not a mid-sentence phrase pause.
    /// ponytail: speaker-dependent heuristic; raise if sentences split, lower if they merge.
    static let sourceGapMs = 1100

    private var entries: [Entry] = []        // both streams, in first-token-arrival order
    private var lastSourceMs: Int?
    private var lastSourceEndedSentence = false
    private var translationSentenceOpen = false
    private var sourceIndex = -1             // index of the open source entry in `entries`
    private var translationIndex = -1        // index of the open translation entry

    mutating func appendOriginal(_ token: String, ms: Int?) {
        // New source entry on first token, an audio pause, or a sentence end.
        if sourceIndex < 0 || isGap(ms, since: lastSourceMs) || lastSourceEndedSentence {
            entries.append(Entry(isSource: true))
            sourceIndex = entries.count - 1
        }
        entries[sourceIndex].text += token
        lastSourceEndedSentence = Self.endsSentence(token)
        if let ms { lastSourceMs = ms }
    }

    mutating func appendTranslation(_ token: String, ms: Int?) {
        // New translation entry at the start of each sentence — keeps it whole and
        // splits long output into readable per-sentence rows (no giant blocks).
        if translationIndex < 0 || !translationSentenceOpen {
            entries.append(Entry(isSource: false))
            translationIndex = entries.count - 1
            translationSentenceOpen = true
        }
        entries[translationIndex].text += token
        if Self.endsSentence(token) { translationSentenceOpen = false }
    }

    private func isGap(_ ms: Int?, since last: Int?) -> Bool {
        guard let ms, let last else { return false }
        return ms - last > Self.sourceGapMs
    }

    private static func endsSentence(_ token: String) -> Bool {
        guard let last = token.reversed().first(where: { !$0.isWhitespace }) else { return false }
        return ".!?。！？…".contains(last)
    }

    /// One row per entry, in arrival order — source rows and translation rows
    /// interleaved by time, each carrying only its own side.
    var rows: [Row] {
        entries.compactMap { e in
            let t = Self.collapseLoops(e.text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !t.isEmpty else { return nil }
            return e.isSource ? Row(source: t, translation: "") : Row(source: "", translation: t)
        }
    }

    /// All translation text joined (for Summarize).
    var translationText: String {
        entries.filter { !$0.isSource }
            .map { Self.collapseLoops($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Cosmetic only: collapse a word-group (1–6 words) the realtime model looped
    /// 3+ times in a row down to one occurrence ("ты ты ты ты"; "нам стоит уйти, нам
    /// стоит уйти, …"). Loops are model garbage on hard audio — this just stops them
    /// filling the panel. 3+ reps, so genuine emphasis ("very very") survives.
    // ponytail: O(words²·6) per entry per render; entries are sentence-sized so it's cheap.
    static func collapseLoops(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard words.count >= 3 else { return text }
        var out: [String] = []
        var i = 0
        while i < words.count {
            var collapsed = false
            var n = min(6, (words.count - i) / 2)
            while n >= 1 {
                let gram = Array(words[i ..< i + n])
                var reps = 1
                var j = i + n
                while j + n <= words.count && Array(words[j ..< j + n]) == gram { reps += 1; j += n }
                if reps >= 3 {
                    out.append(contentsOf: gram)
                    i = j
                    collapsed = true
                    break
                }
                n -= 1
            }
            if !collapsed { out.append(words[i]); i += 1 }
        }
        return out.joined(separator: " ")
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
        get { LiveAudioSource(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .microphone }
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
        case .notDetermined:
            // requestAccess crashes if NSMicrophoneUsageDescription is missing
            // (e.g. `swift run`, which has no Info.plist) — only prompt when the
            // bundle declares it. The shipped .app always does.
            guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else { return false }
            return await AVCaptureDevice.requestAccess(for: .audio)
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
                try? await stream.stopCapture()
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

/// Pins thin, auto-hiding overlay scrollers. In a borderless floating panel
/// (mouse attached), a plain NSScrollView reverts a manually-set `.overlay`
/// back to the system's wide legacy scroller, whose track never disappears —
/// overriding the getter stops that revert so it matches the translate window.
final class OverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set {}
    }
}

/// Borderless live panel that can still become key — needed so the summary's
/// follow-up field can take text focus (and Cmd+C fires). `.nonactivatingPanel`
/// keeps the translated app frontmost while we hold key, so nothing is stolen.
final class KeyableLivePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Borderless icon button with a soft rounded hover highlight — used for the
/// captions header controls (pause/minimize/close).
/// Two modes:
/// - tint mode (default, no background): hover/selection are shown by changing
///   the icon tint only — nothing to clip against the glass corners.
/// - background mode (the round white play button): a persistent `restingBG`
///   that brightens to `hoverBG` on hover.
final class HoverIconButton: NSButton {
    var roundedFull = false
    var corner: CGFloat = 6
    var baseTint: NSColor = NSColor(calibratedWhite: 1.0, alpha: 0.6)
    var hoverTint: NSColor = NSColor(calibratedWhite: 1.0, alpha: 0.9)
    var restingBG: NSColor = .clear
    var hoverBG: NSColor?
    private var tracking: NSTrackingArea?
    private var isHovering = false
    private let circleMask = CAShapeLayer()

    private var usesBackground: Bool { hoverBG != nil || restingBG != .clear }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true   // re-inscribe the disc against the final frame
    }

    override func layout() {
        super.layout()
        guard usesBackground else { return }
        wantsLayer = true
        if roundedFull {
            // Clip the disc to a circle inscribed in the SHORT side, so a frame
            // that isn't perfectly square still renders a true circle — never the
            // pill that `cornerRadius = min/2` produces on a non-square rect.
            let d = min(bounds.width, bounds.height)
            let inset = CGRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
            circleMask.fillColor = NSColor.black.cgColor
            circleMask.frame = bounds
            circleMask.path = CGPath(ellipseIn: inset, transform: nil)
            layer?.mask = circleMask
            layer?.cornerRadius = 0
        } else {
            layer?.mask = nil
            layer?.cornerRadius = corner
        }
        layer?.backgroundColor = (isHovering ? (hoverBG ?? restingBG) : restingBG).cgColor
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        if usesBackground {
            layer?.backgroundColor = (hoverBG ?? restingBG).cgColor
        } else {
            contentTintColor = hoverTint
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        if usesBackground {
            layer?.backgroundColor = restingBG.cgColor
        } else {
            contentTintColor = baseTint
        }
    }
}

/// Shows the open-hand "grab to move" cursor on hover, hinting the card is a drag
/// handle (the window is movable by dragging its background).
final class DragHandleView: NSView {
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseEnteredAndExited, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.openHand.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.openHand.set() }
}

@MainActor
final class LiveCaptionPanelController: NSObject {
    private let panel: NSPanel
    private let indicatorPanel: NSPanel
    // The summary is a fixed-width column parked just off one edge of the player.
    // Opening it GROWS THE WINDOW to reveal it — the player's own layout never
    // changes, so it cannot drift while the window animates.
    private let summaryColumn = NSView()
    private let summarySep = HairlineSeparatorView()
    private let playerGuide = NSLayoutGuide()
    private var playerLeadingPin: NSLayoutConstraint!    // player flush-left  → summary opens on the right
    private var playerTrailingPin: NSLayoutConstraint!   // player flush-right → summary opens on the left
    private var summaryRightPins: [NSLayoutConstraint] = []
    private var summaryLeftPins: [NSLayoutConstraint] = []
    private var summaryOnRight = true
    private let summaryTextView = NSTextView()
    private let summaryTitleLabel = NSTextField(labelWithString: "Summary")
    private let summaryShimmer = ShimmerTextLabel()   // replaces the title while working
    private let followUpField = FollowUpTextField()
    private var summaryText = ""
    private var isSummaryShown = false
    private var isProgrammaticResize = false
    private var preSummaryFrame: NSRect?   // player frame before the summary opened — restored on close
    private static let summaryColumnWidth: CGFloat = 300
    private static let baseContentWidth: CGFloat = 380   // the player's fixed width (collapsed window width)

    private let statusLabel = NSTextField(labelWithString: "")
    private let costLabel = NSTextField(labelWithString: "")
    private let textView = NSTextView()
    private let scrollView = OverlayScrollView()

    // Glass palette — mirrors TranslationPanelPalette (which is private to App.swift)
    // so the captions window matches the translate window's white-on-glass look.
    private static let glassCornerRadius: CGFloat = 22
    private static let titleColor = NSColor(calibratedWhite: 1.0, alpha: 0.84)
    private static let costColor = NSColor(calibratedWhite: 1.0, alpha: 0.45)
    private static let bodyColor = NSColor(calibratedWhite: 0.94, alpha: 0.96)
    private static let sourceColor = NSColor(calibratedWhite: 1.0, alpha: 0.42)
    private static let iconColor = NSColor(calibratedWhite: 1.0, alpha: 0.6)
    private static let iconColorActive = NSColor(calibratedWhite: 1.0, alpha: 0.95)

    private var pauseButton: HoverIconButton?
    private var summaryCopyButton: HoverIconButton?
    private var copiedRevert: Timer?              // reverts the copy glyph after the "copied" flash
    private var sourceToggleButton: NSButton?     // 🅰 show-original toggle
    private var audioSourceButton: HoverIconButton?  // single 🔊/🎙 toggle — shows the active source
    private var currentSource: LiveAudioSource = .systemAudio
    private var recordIndicator: RecordIndicatorView?
    /// Shared bottom-center point (screen coords). The captions window and the
    /// collapsed pill are both placed by their bottom-center here, so the pill
    /// sits at the window's bottom edge — and the choice follows wherever the
    /// user drags either one.
    private var anchorBottom: NSPoint?

    var onStop: (() -> Void)?
    var onToggleCollapse: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onToggleSource: (() -> Void)?
    var onSummarize: (() -> Void)?
    var onFollowUp: ((String) -> Void)?
    var onRestart: (() -> Void)?
    var onSourceChange: ((LiveAudioSource) -> Void)?

    override init() {
        panel = KeyableLivePanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        indicatorPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 148, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        super.init()
        configureFloating(panel)
        configureFloating(indicatorPanel)
        buildCaptions()
        buildIndicator()

        // Track user drags of either window so they share one anchor.
        for window in [panel, indicatorPanel] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(panelDidMove(_:)),
                name: NSWindow.didMoveNotification, object: window)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Shared anchor: horizontal center, BOTTOM edge. Both the window and the
    /// pill are placed by their bottom-center on this point, so collapsing drops
    /// the pill at the window's bottom (centered horizontally), not its middle.
    private func bottomCenter(of p: NSPanel) -> NSPoint {
        NSPoint(x: p.frame.midX, y: p.frame.minY)
    }

    /// Visible frame of the screen containing the anchor (or main screen).
    private func anchorScreen() -> NSRect {
        if let c = anchorBottom, let screen = NSScreen.screens.first(where: { $0.frame.contains(c) }) {
            return screen.visibleFrame
        }
        return NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// Places a panel by its bottom-center on the shared anchor, then clamps it
    /// fully inside the visible screen. The anchor is NOT changed by clamping —
    /// only user drags move it — so the pill returns to where it was dragged.
    private func placeAtAnchor(_ p: NSPanel) {
        let size = p.frame.size
        if anchorBottom == nil {
            let v = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            // Default: bottom-right with equal side and bottom insets.
            let inset: CGFloat = 20
            anchorBottom = NSPoint(x: v.maxX - size.width / 2 - inset, y: v.minY + inset)
        }
        guard let c = anchorBottom else { return }
        let screen = anchorScreen()
        let margin: CGFloat = 8
        var x = c.x - size.width / 2
        var y = c.y
        x = min(max(x, screen.minX + margin), screen.maxX - size.width - margin)
        y = min(max(y, screen.minY + margin), screen.maxY - size.height - margin)
        p.setFrameOrigin(NSPoint(x: x, y: y))
    }

    @objc private func panelDidMove(_ note: Notification) {
        guard !isProgrammaticResize else { return }   // ignore the expand/collapse resize
        guard let moved = note.object as? NSWindow else { return }
        if moved === indicatorPanel, indicatorPanel.isVisible {
            anchorBottom = bottomCenter(of: indicatorPanel)
        } else if moved === panel, panel.isVisible {
            anchorBottom = bottomCenter(of: panel)
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

    // Hover is shown by brightening the icon tint (no background to clip).
    private static let hoverNeutral = NSColor(calibratedWhite: 1.0, alpha: 0.92)
    private static let hoverDanger = NSColor.systemRed

    private static func symbolImage(_ name: String, _ description: String, pointSize: CGFloat = 11) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular, scale: .medium)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(config) else { return nil }
        // SF Symbols carry asymmetric baseline padding and a short alignmentRect;
        // NSButton (flipped, scaleNone) then draws the glyph off-center inside the
        // round disc. Re-draw the symbol into a SQUARE canvas with its optical box
        // (alignmentRect) centered, so the cell's geometric centering lands the
        // glyph in the middle of the disc.
        let optical = symbol.alignmentRect
        let side = ceil(max(symbol.size.width, symbol.size.height))
        let canvas = NSImage(size: NSSize(width: side, height: side))
        canvas.lockFocus()
        symbol.draw(
            at: NSPoint(x: side / 2 - optical.midX, y: side / 2 - optical.midY),
            from: .zero, operation: .sourceOver, fraction: 1
        )
        canvas.unlockFocus()
        canvas.isTemplate = true
        return canvas
    }

    private func iconButton(_ symbol: String, tint: NSColor, hover: NSColor,
                            action: Selector, help: String, pointSize: CGFloat = 11) -> HoverIconButton {
        let button = HoverIconButton(title: "", target: self, action: action)
        button.image = Self.symbolImage(symbol, help, pointSize: pointSize)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone          // render at the symbol's natural size — no squishing
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.baseTint = tint
        button.hoverTint = hover
        button.contentTintColor = tint
        button.toolTip = help
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// Active state is shown by a brighter icon tint only — no background chip.
    private func applySelection(_ button: NSButton?, selected: Bool) {
        guard let button = button as? HoverIconButton else { return }
        button.baseTint = selected ? Self.iconColorActive : Self.iconColor
        button.contentTintColor = button.baseTint
    }

    private static let roundRestingBG = NSColor(calibratedWhite: 1.0, alpha: 0.08)
    private static let roundHoverBG = NSColor(calibratedWhite: 1.0, alpha: 0.16)

    /// Circular icon button (translucent disc behind the glyph), brightening on
    /// hover — the bottom-toolbar style. Pass `tint`/`restingBG`/`hoverBG` to
    /// accent a button (e.g. red Stop).
    private func roundButton(_ symbol: String, action: Selector, help: String,
                             tint: NSColor? = nil,
                             restingBG: NSColor? = nil, hoverBG: NSColor? = nil,
                             pointSize: CGFloat = 13) -> HoverIconButton {
        let resolvedTint = tint ?? Self.iconColor
        let button = HoverIconButton(title: "", target: self, action: action)
        button.image = Self.symbolImage(symbol, help, pointSize: pointSize)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.roundedFull = true
        button.baseTint = resolvedTint
        button.contentTintColor = resolvedTint
        button.restingBG = restingBG ?? Self.roundRestingBG
        button.hoverBG = hoverBG ?? Self.roundHoverBG
        button.toolTip = help
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// Text-only "Summarize" pill — the primary action reads as a word.
    /// Rounded-rect background mode (vs. the round icon buttons).
    private func makeSummarizeButton() -> HoverIconButton {
        let button = HoverIconButton(title: "Summarize", target: self, action: #selector(summarizeTapped))
        button.imagePosition = .noImage
        button.attributedTitle = NSAttributedString(string: "Summarize", attributes: [
            .foregroundColor: Self.titleColor,
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        ])
        button.contentTintColor = Self.iconColorActive
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.corner = 14
        button.restingBG = Self.roundRestingBG
        button.hoverBG = Self.roundHoverBG
        button.toolTip = "Summarize the conversation so far"
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// Rounded translucent "inset card" that groups controls — replaces the
    /// hairline dividers with the Voice-Memos-style container look.
    private func insetContainer(draggable: Bool = false) -> NSView {
        let view = draggable ? DragHandleView() : NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.05).cgColor
        view.layer?.cornerRadius = 14
        view.layer?.cornerCurve = .continuous
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor(calibratedWhite: 1.0, alpha: 0.08).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    private func buildCaptions() {
        let content = installGlass(in: panel, cornerRadius: Self.glassCornerRadius)

        // The player occupies a fixed-width layout guide pinned to one content
        // edge; the summary column sits just past the other edge of that guide,
        // off-window until the window grows to reveal it.
        content.addLayoutGuide(playerGuide)
        buildSummaryColumn(in: content)
        let lead = playerGuide.leadingAnchor
        let trail = playerGuide.trailingAnchor

        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.textColor = Self.titleColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        costLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        costLabel.textColor = Self.costColor
        costLabel.alignment = .right
        costLabel.translatesAutoresizingMaskIntoConstraints = false

        // Top-right window control — minimize only (Stop lives in the toolbar).
        let collapseButton = iconButton("minus", tint: Self.iconColor, hover: Self.hoverNeutral,
                                        action: #selector(collapseTapped), help: "Minimize")

        // Bottom toolbar — circular-bg icons: [⏮ ⏸ ⏹]  …  [🅰 🔊/🎙 ✨].
        // Left cluster: transport.
        let restartButton = roundButton("backward.end.fill", action: #selector(restartTapped),
                                        help: "Restart session")
        let pauseButton = roundButton("pause.fill", action: #selector(pauseTapped), help: "Pause",
                                      restingBG: NSColor(calibratedWhite: 1.0, alpha: 0.14))
        self.pauseButton = pauseButton
        let stopButton = roundButton("stop.fill", action: #selector(stopTapped), help: "Stop",
                                     tint: NSColor.systemRed.withAlphaComponent(0.92),
                                     restingBG: NSColor.systemRed.withAlphaComponent(0.16),
                                     hoverBG: NSColor.systemRed.withAlphaComponent(0.30))
        // Right cluster: view / mode.
        let sourceToggleButton = roundButton("character.bubble", action: #selector(sourceToggled),
                                             help: "Show original")
        self.sourceToggleButton = sourceToggleButton
        let audioSourceButton = roundButton("speaker.wave.2", action: #selector(cycleSourceTapped),
                                            help: "Audio source")
        self.audioSourceButton = audioSourceButton
        let summarizeButton = makeSummarizeButton()
        let summarizeWidth = summarizeButton.intrinsicContentSize.width + 20

        // Two inset containers replace the divider lines: a header card (status +
        // language + time·cost) up top, and the circular toolbar card below.
        let topContainer = insetContainer(draggable: true)   // header = drag handle
        let bottomContainer = insetContainer()

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
        scrollView.autohidesScrollers = true
        scrollView.scrollerKnobStyle = .light
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(topContainer)
        content.addSubview(scrollView)
        content.addSubview(bottomContainer)
        [statusLabel, costLabel, collapseButton].forEach { topContainer.addSubview($0) }
        [restartButton, pauseButton, stopButton, sourceToggleButton, audioSourceButton, summarizeButton]
            .forEach { bottomContainer.addSubview($0) }

        let bs: CGFloat = 28        // circular button diameter
        let gap: CGFloat = 6        // within-cluster spacing
        // Keep the cluster-gap below required so it never fights the fixed widths.
        let clusterGap = sourceToggleButton.leadingAnchor.constraint(
            greaterThanOrEqualTo: stopButton.trailingAnchor, constant: 12)
        clusterGap.priority = .defaultHigh

        // Player area: fixed width, full height. Which content edge it pins to is
        // toggled by `applySummarySide`; the summary opens off the opposite edge.
        playerLeadingPin = playerGuide.leadingAnchor.constraint(equalTo: content.leadingAnchor)
        playerTrailingPin = playerGuide.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        summaryRightPins = [
            summaryColumn.leadingAnchor.constraint(equalTo: trail),
            summarySep.centerXAnchor.constraint(equalTo: trail),
        ]
        summaryLeftPins = [
            summaryColumn.trailingAnchor.constraint(equalTo: lead),
            summarySep.centerXAnchor.constraint(equalTo: lead),
        ]

        NSLayoutConstraint.activate([
            playerGuide.topAnchor.constraint(equalTo: content.topAnchor),
            playerGuide.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            playerGuide.widthAnchor.constraint(equalToConstant: Self.baseContentWidth),

            summaryColumn.topAnchor.constraint(equalTo: content.topAnchor),
            summaryColumn.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            summaryColumn.widthAnchor.constraint(equalToConstant: Self.summaryColumnWidth),

            summarySep.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            summarySep.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            summarySep.widthAnchor.constraint(equalToConstant: 1),

            // Header container: status + cost + minimize.
            topContainer.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            topContainer.leadingAnchor.constraint(equalTo: lead, constant: 12),
            topContainer.trailingAnchor.constraint(equalTo: trail, constant: -12),
            topContainer.heightAnchor.constraint(equalToConstant: 40),

            statusLabel.leadingAnchor.constraint(equalTo: topContainer.leadingAnchor, constant: 14),
            statusLabel.centerYAnchor.constraint(equalTo: topContainer.centerYAnchor),

            collapseButton.trailingAnchor.constraint(equalTo: topContainer.trailingAnchor, constant: -8),
            collapseButton.centerYAnchor.constraint(equalTo: topContainer.centerYAnchor),
            collapseButton.widthAnchor.constraint(equalToConstant: 24),
            collapseButton.heightAnchor.constraint(equalToConstant: 24),

            costLabel.trailingAnchor.constraint(equalTo: collapseButton.leadingAnchor, constant: -8),
            costLabel.centerYAnchor.constraint(equalTo: topContainer.centerYAnchor),
            costLabel.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 8),

            // Transcript (borderless) between the two containers.
            scrollView.topAnchor.constraint(equalTo: topContainer.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: lead, constant: 14),
            scrollView.trailingAnchor.constraint(equalTo: trail, constant: -14),
            scrollView.bottomAnchor.constraint(equalTo: bottomContainer.topAnchor, constant: -8),

            // Toolbar container.
            bottomContainer.leadingAnchor.constraint(equalTo: lead, constant: 12),
            bottomContainer.trailingAnchor.constraint(equalTo: trail, constant: -12),
            bottomContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            bottomContainer.heightAnchor.constraint(equalToConstant: 48),

            // Left cluster: restart · pause · stop.
            restartButton.leadingAnchor.constraint(equalTo: bottomContainer.leadingAnchor, constant: 10),
            restartButton.centerYAnchor.constraint(equalTo: bottomContainer.centerYAnchor),
            restartButton.widthAnchor.constraint(equalToConstant: bs),
            restartButton.heightAnchor.constraint(equalToConstant: bs),

            pauseButton.leadingAnchor.constraint(equalTo: restartButton.trailingAnchor, constant: gap),
            pauseButton.centerYAnchor.constraint(equalTo: bottomContainer.centerYAnchor),
            pauseButton.widthAnchor.constraint(equalToConstant: bs),
            pauseButton.heightAnchor.constraint(equalToConstant: bs),

            stopButton.leadingAnchor.constraint(equalTo: pauseButton.trailingAnchor, constant: gap),
            stopButton.centerYAnchor.constraint(equalTo: bottomContainer.centerYAnchor),
            stopButton.widthAnchor.constraint(equalToConstant: bs),
            stopButton.heightAnchor.constraint(equalToConstant: bs),

            // Right cluster: original · source · summarize (summarize at the edge).
            summarizeButton.trailingAnchor.constraint(equalTo: bottomContainer.trailingAnchor, constant: -10),
            summarizeButton.centerYAnchor.constraint(equalTo: bottomContainer.centerYAnchor),
            summarizeButton.widthAnchor.constraint(equalToConstant: summarizeWidth),
            summarizeButton.heightAnchor.constraint(equalToConstant: bs),

            audioSourceButton.trailingAnchor.constraint(equalTo: summarizeButton.leadingAnchor, constant: -gap),
            audioSourceButton.centerYAnchor.constraint(equalTo: bottomContainer.centerYAnchor),
            audioSourceButton.widthAnchor.constraint(equalToConstant: bs),
            audioSourceButton.heightAnchor.constraint(equalToConstant: bs),

            sourceToggleButton.trailingAnchor.constraint(equalTo: audioSourceButton.leadingAnchor, constant: -gap),
            sourceToggleButton.centerYAnchor.constraint(equalTo: bottomContainer.centerYAnchor),
            sourceToggleButton.widthAnchor.constraint(equalToConstant: bs),
            sourceToggleButton.heightAnchor.constraint(equalToConstant: bs),

            clusterGap,
        ])

        applySummarySide(onRight: true)   // default; re-decided each time the summary opens
    }

    /// Pins the player to one content edge and parks the summary off the other,
    /// so the summary opens on `onRight ? right : left`.
    private func applySummarySide(onRight: Bool) {
        summaryOnRight = onRight
        NSLayoutConstraint.deactivate(onRight ? summaryLeftPins : summaryRightPins)
        playerLeadingPin.isActive = onRight
        playerTrailingPin.isActive = !onRight
        NSLayoutConstraint.activate(onRight ? summaryRightPins : summaryLeftPins)
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

    /// Single source toggle: shows only the active source's icon; tapping it
    /// switches to the other (handled by `cycleSourceTapped`).
    func setSource(_ source: LiveAudioSource) {
        currentSource = source
        let isSystem = source == .systemAudio
        audioSourceButton?.image = Self.symbolImage(isSystem ? "speaker.wave.2" : "mic",
                                                    source.title, pointSize: 13)
        audioSourceButton?.toolTip = isSystem ? "System audio - tap to use the microphone"
                                              : "Microphone - tap to use system audio"
    }

    func showCaptions() {
        indicatorPanel.orderOut(nil)
        placeAtAnchor(panel)            // bottom-center on the shared anchor, clamped to screen
        panel.orderFrontRegardless()
    }

    func showIndicator() {
        panel.orderOut(nil)
        placeAtAnchor(indicatorPanel)   // pill bottom-center on the same anchor, clamped
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

    /// Renders order-paired rows — each translation with its source shown muted
    /// above (when enabled) — and the still-untranslated source as a trailing
    /// live row, so the original is paced and never races ahead.
    func render(_ dialogue: LiveDialogue, showSource: Bool) {
        let body = NSMutableAttributedString()
        for row in dialogue.rows {
            // Decoupled rows carry only one side. Source is the dim gray line, the
            // translation the bright primary one.
            if showSource, !row.source.isEmpty {
                body.append(NSAttributedString(string: row.source + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: Self.sourceColor
                ]))
            }
            if !row.translation.isEmpty {
                body.append(NSAttributedString(string: row.translation + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 15),
                    .foregroundColor: Self.bodyColor
                ]))
            }
            // Paragraph gap after each row.
            body.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6)]))
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

    /// Builds the fixed-width summary column (header card + scrollable text). Its
    /// size/side constraints live in `buildCaptions`; here we just fill it. The
    /// column is parked off-window when collapsed and revealed by the window
    /// growing — no width animation, so no reflow.
    private func buildSummaryColumn(in content: NSView) {
        summaryColumn.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(summaryColumn)

        summarySep.translatesAutoresizingMaskIntoConstraints = false
        summarySep.alphaValue = 0   // only shown while the summary is open
        content.addSubview(summarySep)

        let title = summaryTitleLabel
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = Self.titleColor
        title.translatesAutoresizingMaskIntoConstraints = false

        // Shimmer overlays the title position while the model works.
        summaryShimmer.translatesAutoresizingMaskIntoConstraints = false
        summaryShimmer.isHidden = true

        let headerContainer = insetContainer(draggable: true)   // summary header = drag handle

        let copyButton = iconButton("doc.on.doc", tint: Self.iconColor, hover: Self.hoverNeutral,
                                    action: #selector(copySummaryTapped), help: "Copy summary")
        summaryCopyButton = copyButton
        let closeButton = iconButton("xmark", tint: Self.iconColor, hover: Self.hoverNeutral,
                                     action: #selector(closeSummaryTapped), help: "Close summary")

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

        let scroll = OverlayScrollView()
        scroll.documentView = summaryTextView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.scrollerKnobStyle = .light
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // Bottom follow-up input — wrapped in the same inset card as the player
        // toolbar (matching height/bg), with a trailing send button. Submits on
        // Return or the button.
        let inputContainer = insetContainer()

        followUpField.translatesAutoresizingMaskIntoConstraints = false
        followUpField.placeholderAttributedString = NSAttributedString(
            string: "Ask a follow-up…",
            attributes: [.font: NSFont.systemFont(ofSize: 13),
                         .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.42)])
        followUpField.font = .systemFont(ofSize: 13)
        followUpField.textColor = Self.bodyColor
        followUpField.isBezeled = false
        followUpField.isBordered = false
        followUpField.drawsBackground = false
        followUpField.focusRingType = .none
        followUpField.cell?.usesSingleLineMode = true
        followUpField.cell?.wraps = false
        followUpField.cell?.isScrollable = true
        followUpField.delegate = self
        followUpField.onEscape = { [weak self] in self?.setSummaryShown(false, animated: true) }

        let sendButton = roundButton("arrow.up", action: #selector(sendFollowUpTapped), help: "Send")

        summaryColumn.addSubview(headerContainer)
        summaryColumn.addSubview(scroll)
        summaryColumn.addSubview(inputContainer)
        inputContainer.addSubview(followUpField)
        inputContainer.addSubview(sendButton)
        [title, summaryShimmer, copyButton, closeButton].forEach { headerContainer.addSubview($0) }

        NSLayoutConstraint.activate([
            // Header card — matches the main panel's top container.
            headerContainer.topAnchor.constraint(equalTo: summaryColumn.topAnchor, constant: 12),
            headerContainer.leadingAnchor.constraint(equalTo: summaryColumn.leadingAnchor, constant: 12),
            headerContainer.trailingAnchor.constraint(equalTo: summaryColumn.trailingAnchor, constant: -12),
            headerContainer.heightAnchor.constraint(equalToConstant: 40),

            title.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 14),
            title.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),

            // Shimmer occupies the title slot (between leading edge and copy button).
            summaryShimmer.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 14),
            summaryShimmer.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            summaryShimmer.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -8),
            summaryShimmer.heightAnchor.constraint(equalToConstant: 18),

            closeButton.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),
            copyButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            copyButton.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 24),
            copyButton.heightAnchor.constraint(equalToConstant: 24),

            scroll.topAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: summaryColumn.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: summaryColumn.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: inputContainer.topAnchor, constant: -8),

            // Input card — same inset style/height as the player toolbar.
            inputContainer.leadingAnchor.constraint(equalTo: summaryColumn.leadingAnchor, constant: 12),
            inputContainer.trailingAnchor.constraint(equalTo: summaryColumn.trailingAnchor, constant: -12),
            inputContainer.bottomAnchor.constraint(equalTo: summaryColumn.bottomAnchor, constant: -12),
            inputContainer.heightAnchor.constraint(equalToConstant: 48),

            followUpField.leadingAnchor.constraint(equalTo: inputContainer.leadingAnchor, constant: 14),
            followUpField.centerYAnchor.constraint(equalTo: inputContainer.centerYAnchor),
            followUpField.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -6),

            sendButton.trailingAnchor.constraint(equalTo: inputContainer.trailingAnchor, constant: -10),
            sendButton.centerYAnchor.constraint(equalTo: inputContainer.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 28),
            sendButton.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    /// Opens the summary panel and runs the shimmer while the model works, so
    /// tapping Summarize gives immediate "something's happening" feedback.
    func showSummaryLoading() {
        startShimmer("Summarizing…")
        setSummaryShown(true, animated: true)
    }

    /// Swaps the header title for the sweeping shimmer with the given label;
    /// the body is left untouched until the result replaces it.
    private func startShimmer(_ text: String) {
        summaryTitleLabel.isHidden = true
        summaryShimmer.configure(
            text: text,
            font: .systemFont(ofSize: 12, weight: .semibold),
            base: NSColor(calibratedWhite: 1.0, alpha: 0.30),
            highlight: NSColor(calibratedWhite: 1.0, alpha: 0.95))
        summaryShimmer.isHidden = false
        summaryShimmer.startAnimating()
    }

    private func stopSummaryLoading() {
        summaryShimmer.stopAnimating()
        summaryShimmer.isHidden = true
        summaryTitleLabel.isHidden = false
    }

    func showSummary(_ text: String) {
        stopSummaryLoading()
        summaryText = text
        summaryTextView.textStorage?.setAttributedString(Self.attributedSummary(text))
        setSummaryShown(true, animated: true)
    }

    /// Replace-mode follow-up: the answer alone takes over the summary body.
    /// Re-clicking Summarize restores the (still-cached) summary.
    func showFollowUpAnswer(_ answer: String) {
        stopSummaryLoading()
        summaryText = answer
        summaryTextView.textStorage?.setAttributedString(Self.attributedSummary(answer))
        summaryTextView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    /// Shimmer shown the instant a question is submitted, until the answer lands.
    func showFollowUpPending() {
        startShimmer("Thinking…")
    }

    private func submitFollowUp() {
        let text = followUpField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        followUpField.stringValue = ""
        onFollowUp?(text)
    }

    /// Renders the model's lightweight markdown (**bold**, *italic*, `- ` bullets,
    /// blank-line paragraphs) without a full markdown engine: inline parsing that
    /// preserves whitespace, then maps the strong/emphasis intents to fonts.
    private static func attributedSummary(_ markdown: String) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: 14)
        let strong = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = NSAttributedString(string: trimmed, attributes: [.font: base, .foregroundColor: bodyColor])

        guard let parsed = try? AttributedString(
            markdown: trimmed,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return plain }

        let result = NSMutableAttributedString(parsed)
        let full = NSRange(location: 0, length: result.length)
        result.addAttributes([.font: base, .foregroundColor: bodyColor], range: full)
        result.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
            guard let raw = (value as? NSNumber)?.uintValue else { return }
            let intent = InlinePresentationIntent(rawValue: raw)
            if intent.contains(.stronglyEmphasized) {
                result.addAttribute(.font, value: strong, range: range)
            } else if intent.contains(.emphasized) {
                result.addAttribute(.font, value: NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask), range: range)
            }
        }
        return result
    }

    /// Opens/closes the summary by GROWING THE WINDOW only — the player's layout
    /// is fixed-width and pinned to the edge that stays put, so it never moves.
    /// The summary column is already laid out just off-window; the window growth
    /// reveals it. Single animation driver (the window frame) → no wobble.
    private func setSummaryShown(_ shown: Bool, animated: Bool) {
        guard shown != isSummaryShown else { return }
        isSummaryShown = shown
        let delta = Self.summaryColumnWidth
        // The relayout below otherwise snaps the transcript back to the top —
        // preserve where the user was reading (usually pinned to the bottom).
        let transcriptScroll = scrollView.contentView.bounds.origin

        let target: NSRect
        if shown {
            let f = panel.frame
            preSummaryFrame = f
            // Open toward whichever side has more screen room. The player pins to
            // the OPPOSITE (stationary) edge, so it stays put either way.
            let screen = anchorScreen()
            let onRight = (screen.maxX - f.maxX) >= (f.minX - screen.minX)
            applySummarySide(onRight: onRight)
            summarySep.alphaValue = 1
            panel.contentView?.layoutSubtreeIfNeeded()   // park the summary for the chosen side
            target = onRight
                ? NSRect(x: f.minX, y: f.minY, width: f.width + delta, height: f.height)          // grow right
                : NSRect(x: f.minX - delta, y: f.minY, width: f.width + delta, height: f.height)  // grow left
        } else {
            // Retract to the exact pre-open frame; the player doesn't move.
            let f = panel.frame
            target = preSummaryFrame
                ?? NSRect(x: summaryOnRight ? f.minX : f.minX + delta, y: f.minY,
                          width: f.width - delta, height: f.height)
            preSummaryFrame = nil
            summarySep.alphaValue = 0
        }
        restoreTranscriptScroll(transcriptScroll)

        guard animated else {
            panel.setFrame(target, display: false)
            restoreTranscriptScroll(transcriptScroll)
            panel.invalidateShadow()
            return
        }
        // A borderless, transparent window keeps a stale shadow when its frame
        // changes — drop it for the resize, restore + invalidate once settled.
        isProgrammaticResize = true
        panel.hasShadow = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.restoreTranscriptScroll(transcriptScroll)
                self.panel.hasShadow = true
                self.panel.invalidateShadow()
                self.isProgrammaticResize = false
            }
        })
    }

    private func restoreTranscriptScroll(_ origin: NSPoint) {
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Collapse any open summary (no animation) so a restarted session begins
    /// clean rather than showing the previous conversation's summary.
    func resetSummaryForNewSession() {
        stopSummaryLoading()
        summaryText = ""
        summaryTextView.string = ""
        followUpField.stringValue = ""
        setSummaryShown(false, animated: false)
    }

    func copySummary() {
        guard !summaryText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summaryText, forType: .string)
        flashCopied()
    }

    /// Brief "copied" confirmation: the copy glyph becomes a checkmark in the
    /// same gray as the neighbouring close icon (so the two read as a pair),
    /// then reverts. Re-tapping restarts the timer rather than stacking reverts.
    private func flashCopied() {
        guard let button = summaryCopyButton else { return }
        button.image = Self.symbolImage("checkmark", "Copied")
        button.contentTintColor = Self.iconColor
        copiedRevert?.invalidate()
        copiedRevert = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let button = self.summaryCopyButton else { return }
                button.image = Self.symbolImage("doc.on.doc", "Copy summary")
                button.contentTintColor = button.baseTint
            }
        }
    }

    @objc private func stopTapped() { onStop?() }
    @objc private func collapseTapped() { onToggleCollapse?() }
    @objc private func pauseTapped() { onTogglePause?() }
    @objc private func sourceToggled() { onToggleSource?() }
    @objc private func summarizeTapped() { onSummarize?() }
    @objc private func sendFollowUpTapped() { submitFollowUp() }
    @objc private func copySummaryTapped() { copySummary() }
    @objc private func closeSummaryTapped() { setSummaryShown(false, animated: true) }
    @objc private func restartTapped() { onRestart?() }
    @objc private func cycleSourceTapped() {
        onSourceChange?(currentSource == .systemAudio ? .microphone : .systemAudio)
    }
}

extension LiveCaptionPanelController: NSTextFieldDelegate {
    // Submit on Return only — swallow the keystroke so the field doesn't beep.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === followUpField,
              commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        submitFollowUp()
        return true
    }
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
    // Last (transcript, summary) pair — re-summarizing identical text reuses it.
    private var summaryCache: (text: String, summary: String)?
    // Follow-up Q&A grounding: the summary currently on screen + prior turns.
    // Reset whenever a fresh summary is shown so questions chain within one summary.
    private var lastSummary = ""
    private var followUpHistory: [[String: Any]] = []

    // Active-time accounting. Pause freezes it, so cost/billing only count the
    // time audio is actually streaming, not wall-clock since first start.
    private var accumulatedSeconds: TimeInterval = 0
    private var segmentStart: Date?

    var onMissingAPIKey: (() -> Void)?
    var onMicrophonePermissionDenied: (() -> Void)?

    func toggle(apiKey: String?, targetLanguage: TranslationLanguage) {
        // The hotkey only shows/hides the window — it never changes pause/run state.
        // (Resume is via the pause button or the pill's record glyph.)
        if isRunning || isPaused {
            toggleCollapsed()
        } else {
            start(apiKey: apiKey, targetLanguage: targetLanguage)
        }
    }

    /// Live-update the target language (e.g. when the user changes it in the menu
    /// while a session is active), reconfiguring the running session.
    func updateTargetLanguage(_ language: TranslationLanguage) {
        guard isRunning || isPaused else { return }
        guard language != targetLanguage else { return }
        targetLanguage = language
        summaryCache = nil   // summary is written in this language — stale on change
        session?.setLanguage(LiveTranslationLanguage.apiCode(for: language))
        panel.update(status: currentStatusText())
    }

    func start(apiKey: String?, targetLanguage: TranslationLanguage) {
        guard let apiKey, !apiKey.isEmpty else { onMissingAPIKey?(); return }
        guard !isRunning, !isPaused else { return }
        self.apiKey = apiKey
        self.targetLanguage = targetLanguage
        dialogue = LiveDialogue()
        accumulatedSeconds = 0
        isCollapsed = false
        summaryCache = nil
        lastSummary = ""
        followUpHistory = []
        LiveAudioSource.current = .microphone   // every new session defaults to the mic
        panel.resetSummaryForNewSession()

        panel.onStop = { [weak self] in self?.stop() }
        panel.onToggleCollapse = { [weak self] in self?.toggleCollapsed() }
        panel.onTogglePause = { [weak self] in self?.togglePauseResume() }
        panel.onToggleSource = { [weak self] in self?.toggleSource() }
        panel.onSummarize = { [weak self] in self?.summarize() }
        panel.onFollowUp = { [weak self] question in self?.askFollowUp(question) }
        panel.onRestart = { [weak self] in self?.restart() }
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
        if isPaused { return "Paused - press play to continue" }
        if isRunning { return "Listening → \(targetLanguage.displayName)" }
        return "Stopped"
    }

    private func summarize() {
        let text = dialogue.translationText
        guard !text.isEmpty else { panel.update(status: "Nothing to summarize yet."); return }
        // Reuse the last summary if the transcript hasn't changed — no API call.
        if let cached = summaryCache, cached.text == text {
            startFollowUpThread(with: cached.summary)
            panel.showSummary(cached.summary)
            return
        }
        guard !apiKey.isEmpty else { onMissingAPIKey?(); return }
        panel.update(status: "Summarizing…")
        panel.showSummaryLoading()
        let key = apiKey
        let language = targetLanguage.displayName   // reading language — always summarize in it
        Task { [weak self] in
            do {
                let summary = try await LiveSummarizer.summarize(text, apiKey: key, language: language)
                guard let self else { return }
                self.summaryCache = (text, summary)
                self.startFollowUpThread(with: summary)
                self.panel.showSummary(summary)
                self.panel.update(status: self.currentStatusText())
            } catch {
                guard let self else { return }
                self.panel.showSummary("⚠︎ Couldn't summarize: \(error.localizedDescription)")
                self.panel.update(status: self.currentStatusText())
            }
        }
    }

    /// A freshly shown summary starts a clean follow-up conversation grounded in it.
    private func startFollowUpThread(with summary: String) {
        lastSummary = summary
        followUpHistory = []
    }

    private func askFollowUp(_ question: String) {
        guard !lastSummary.isEmpty else { return }   // only meaningful once a summary exists
        guard !apiKey.isEmpty else { onMissingAPIKey?(); return }
        let transcript = dialogue.translationText   // grounded in the transcript as it stands now
        let summary = lastSummary
        let history = followUpHistory
        let key = apiKey
        let language = targetLanguage.displayName
        panel.showFollowUpPending()
        Task { [weak self] in
            do {
                let answer = try await LiveSummarizer.answer(
                    question: question, transcript: transcript, summary: summary,
                    history: history, apiKey: key, language: language)
                guard let self else { return }
                self.followUpHistory.append(["role": "user", "content": question])
                self.followUpHistory.append(["role": "assistant", "content": answer])
                self.panel.showFollowUpAnswer(answer)
            } catch {
                self?.panel.showFollowUpAnswer("⚠︎ Couldn't answer: \(error.localizedDescription)")
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
        session.onTranslatedDelta = { [weak self] delta, ms in
            guard let self else { return }
            self.dialogue.appendTranslation(delta, ms: ms)
            self.renderTranscripts()
        }
        session.onSourceDelta = { [weak self] delta, ms in
            guard let self else { return }
            self.dialogue.appendOriginal(delta, ms: ms)
            self.renderTranscripts()
        }
        session.onServerError = { [weak self] message in
            // Non-fatal: surface briefly, keep translating.
            self?.panel.update(status: "⚠︎ \(message)")
        }
        session.onStatusChange = { [weak self] status in
            guard let self else { return }
            if case .failed(let message) = status {
                self.stop(finalStatus: "Error: \(message) - stopped.", keepVisible: true)
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

    /// Clears the transcript, summary, and billing and starts a fresh session —
    /// the panel stays open (unlike Stop).
    func restart() {
        guard isRunning || isPaused else { return }
        accumulateActiveTime()
        teardownCaptureAndSession()
        dialogue = LiveDialogue()
        accumulatedSeconds = 0
        segmentStart = nil
        summaryCache = nil
        panel.resetSummaryForNewSession()
        renderTranscripts()
        panel.update(cost: "00:00 · ~$0.00")
        launchSession()
    }

    /// Stops capture + billing but keeps the transcript and panel open so the
    /// user can resume into the same history.
    func pause() {
        guard isRunning else { return }
        isRunning = false
        isPaused = true
        accumulateActiveTime()
        teardownCaptureAndSession()
        renderTranscripts()
        panel.setPaused(true)
        panel.update(status: "Paused - press play to continue")
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
                    guard let self else { return }
                    self.onMicrophonePermissionDenied?()
                    self.stop(finalStatus: "Microphone access needed", keepVisible: false)
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
        panel.setPaused(false)
        renderTranscripts()
        panel.update(status: finalStatus)
        if keepVisible { panel.showCaptions() } else { panel.close() }
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

/// Plain dictation: mic → realtime STT → each completed phrase is typed into
/// whatever field holds the caret (⌘V paste, like the rewrite/replace flow).
/// A small floating REC pill shows elapsed time; clicking it stops. The
/// user's clipboard is snapshotted once at start and restored after stop.
@MainActor
final class DictationController: NSObject {
    private(set) var isRunning = false

    var onMissingAPIKey: (() -> Void)?
    var onMicrophonePermissionDenied: (() -> Void)?

    private var mic: MicrophoneCapture?
    private var session: RealtimeTranscriptionSession?
    private var pill: NSPanel?
    private var indicator: RecordIndicatorView?
    private var elapsedTimer: Timer?
    private var startedAt: Date?
    private var clipboardSnapshot: PasteboardSnapshot?
    private var lastPasteChangeCount: Int?

    func toggle(apiKey: String?) {
        if isRunning { stop() } else { start(apiKey: apiKey) }
    }

    func start(apiKey: String?) {
        guard let apiKey, !apiKey.isEmpty else { onMissingAPIKey?(); return }
        guard !isRunning else { return }
        Task { @MainActor in
            guard await MicrophoneCapture.requestAuthorization() else {
                onMicrophonePermissionDenied?()
                return
            }
            guard !self.isRunning else { return }
            self.isRunning = true
            self.clipboardSnapshot = PasteboardSnapshot.capture(from: .general)
            self.lastPasteChangeCount = nil

            let session = RealtimeTranscriptionSession(
                apiKey: apiKey,
                safetyIdentifier: Self.safetyIdentifier()
            )
            session.onPhrase = { [weak self] phrase in self?.insert(phrase) }
            session.onFailed = { [weak self] _ in self?.stop() }
            self.session = session
            session.connect()

            let mic = MicrophoneCapture()
            mic.onPCM = { [weak session] pcm in session?.append(pcm: pcm) }
            mic.onError = { [weak self] _ in Task { @MainActor in self?.stop() } }
            self.mic = mic
            mic.start()

            self.showPill()
            self.startedAt = Date()
            self.elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tickElapsed() }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        mic?.stop()
        mic = nil
        session?.close()
        session = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        startedAt = nil
        pill?.orderOut(nil)
        pill = nil
        indicator = nil

        // Give the last ⌘V time to land in the target app, then put the
        // user's clipboard back — unless something else claimed it since.
        if let snapshot = clipboardSnapshot, let lastPaste = lastPasteChangeCount {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if NSPasteboard.general.changeCount == lastPaste {
                    snapshot.restore(to: NSPasteboard.general)
                }
            }
        }
        clipboardSnapshot = nil
        lastPasteChangeCount = nil
    }

    private func insert(_ phrase: String) {
        guard isRunning else { return }
        let text = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // ponytail: naive spacing — every phrase gets one trailing space;
        // smart spacing around punctuation if it ever grates.
        pasteboard.setString(text + " ", forType: .string)
        lastPasteChangeCount = pasteboard.changeCount
        KeyboardShortcutPoster.postCommandShortcut(keyCode: CGKeyCode(kVK_ANSI_V))
    }

    private func tickElapsed() {
        guard let startedAt else { return }
        let seconds = Int(Date().timeIntervalSince(startedAt))
        indicator?.setTime(String(format: "%02d:%02d", seconds / 60, seconds % 60))
    }

    /// Same glass pill the live captions collapse into, bottom-right of the
    /// main screen; any click on it stops the dictation.
    private func showPill() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 148, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false

        let root = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        root.autoresizingMask = [.width, .height]
        let glass = GlassHostView(frame: root.bounds, cornerRadius: 20, tintColor: nil, style: .regular)
        glass.autoresizingMask = [.width, .height]
        root.addSubview(glass)
        let chrome = GlassChromeOverlayView(frame: root.bounds)
        chrome.cornerRadius = 20
        chrome.autoresizingMask = [.width, .height]
        root.addSubview(chrome)
        panel.contentView = root

        let indicator = RecordIndicatorView(frame: glass.contentView.bounds)
        indicator.autoresizingMask = [.width, .height]
        indicator.onClick = { [weak self] in self?.stop() }
        indicator.onToggleRecord = { [weak self] in self?.stop() }
        glass.contentView.addSubview(indicator)

        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let inset: CGFloat = 20
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - panel.frame.width - inset,
            y: visible.minY + inset + 56   // above the live pill's default spot
        ))
        panel.orderFrontRegardless()
        self.pill = panel
        self.indicator = indicator
        indicator.setTime("00:00")
    }

    /// Same per-install id (and UserDefaults key) the live captions use.
    private static func safetyIdentifier() -> String {
        let key = "liveTranslationSafetyID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }
}
