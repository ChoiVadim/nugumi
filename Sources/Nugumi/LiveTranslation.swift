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

struct CaptionLine: Equatable {
    var text: String
    var isFinalized: Bool
}

/// Unified translated transcript for a single audio source (no speaker
/// attribution). Streaming deltas accumulate into one open line; complete
/// sentences are split off and finalized as they arrive, and `finalizeCurrent()`
/// (driven by a pause timer or stop) closes any trailing fragment.
struct LiveTranscript {
    private(set) var lines: [CaptionLine] = []

    private static let cjkEnders: Set<Character> = ["。", "！", "？"]
    private static let latinEnders: Set<Character> = [".", "!", "?", "…"]
    private static let closers: Set<Character> = ["\"", "\u{201D}", ")", "»", "'"]

    mutating func append(delta: String) {
        var open = ""
        if let last = lines.last, !last.isFinalized {
            open = lines.removeLast().text
        }
        open += delta
        let (sentences, remainder) = Self.splitSentences(open)
        for sentence in sentences where !sentence.isEmpty {
            lines.append(CaptionLine(text: sentence, isFinalized: true))
        }
        // Keep the open remainder raw (untrimmed) so the next streaming delta
        // joins correctly whether tokens carry leading OR trailing spaces
        // ("How are " + "you?" and "How are" + " you?" both work). Trimming
        // happens only when the line is finalized or split off as a sentence.
        if !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(CaptionLine(text: remainder, isFinalized: false))
        }
    }

    mutating func finalizeCurrent() {
        guard let last = lines.last, !last.isFinalized else { return }
        let trimmed = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            lines.removeLast()
        } else {
            lines[lines.count - 1].text = trimmed
            lines[lines.count - 1].isFinalized = true
        }
    }

    /// Splits text into complete sentences plus a trailing incomplete remainder.
    /// A latin `. ! ? …` ends a sentence only when followed by whitespace, a
    /// closing quote/paren, or end-of-text (so "3.14" / "www.x.com" don't split);
    /// CJK enders always end a sentence.
    static func splitSentences(_ text: String) -> (sentences: [String], remainder: String) {
        var sentences: [String] = []
        var current = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            current.append(c)
            let isEnder: Bool
            if cjkEnders.contains(c) {
                isEnder = true
            } else if latinEnders.contains(c) {
                let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                isEnder = next == nil || next == " " || next == "\n" || next == "\t" || (next.map { closers.contains($0) } ?? false)
            } else {
                isEnder = false
            }
            if isEnder {
                var j = i + 1
                while j < chars.count, chars[j] == " " || chars[j] == "\n" || chars[j] == "\t" || closers.contains(chars[j]) {
                    current.append(chars[j]); j += 1
                }
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
                i = j
                continue
            }
            i += 1
        }
        return (sentences, current)
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
/// Round collapsed indicator: a pulsing red record dot. Drag to move the window,
/// click (without dragging) to expand back to the captions.
final class RecordIndicatorView: NSView {
    var onClick: (() -> Void)?

    private let dot = NSView()
    private var initialMouseLocation: NSPoint?
    private var initialWindowOrigin: NSPoint?
    private var didDrag = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        NSLayoutConstraint.activate([
            dot.centerXAnchor.constraint(equalTo: centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 14),
            dot.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        dot.layer?.cornerRadius = dot.bounds.width / 2
        if dot.layer?.animation(forKey: "blink") == nil { startBlinking() }
    }

    private func startBlinking() {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.2
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.layer?.add(pulse, forKey: "blink")
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
        if !didDrag { onClick?() }
        initialMouseLocation = nil
        initialWindowOrigin = nil
    }
}

@MainActor
final class LiveCaptionPanelController: NSObject {
    private let panel: NSPanel
    private let indicatorPanel: NSPanel

    private let statusLabel = NSTextField(labelWithString: "")
    private let costLabel = NSTextField(labelWithString: "")
    private let sourceControl = NSSegmentedControl(
        labels: LiveAudioSource.allCases.map { $0.title },
        trackingMode: .selectOne, target: nil, action: nil
    )
    private let textView = NSTextView()
    private let scrollView = NSScrollView()

    // Glass palette — mirrors TranslationPanelPalette (which is private to App.swift)
    // so the captions window matches the translate window's white-on-glass look.
    private static let glassCornerRadius: CGFloat = 22
    private static let titleColor = NSColor(calibratedWhite: 1.0, alpha: 0.84)
    private static let costColor = NSColor(calibratedWhite: 1.0, alpha: 0.45)
    private static let bodyColor = NSColor(calibratedWhite: 0.94, alpha: 0.96)
    private static let partialColor = NSColor(calibratedWhite: 1.0, alpha: 0.5)
    private static let iconColor = NSColor(calibratedWhite: 1.0, alpha: 0.6)

    var onStop: (() -> Void)?
    var onToggleCollapse: (() -> Void)?
    var onSourceChange: ((LiveAudioSource) -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false
        )
        indicatorPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 46, height: 46),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        super.init()
        configureFloating(panel)
        configureFloating(indicatorPanel)
        buildCaptions()
        buildIndicator()
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

    private func iconButton(_ symbol: String, tint: NSColor, action: Selector, help: String) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.imageScaling = .scaleProportionallyUpOrDown
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = tint
        button.toolTip = help
        button.translatesAutoresizingMaskIntoConstraints = false
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

        let collapseButton = iconButton("minus.circle.fill", tint: Self.iconColor,
                                        action: #selector(collapseTapped), help: "Minimize")
        let closeButton = iconButton("xmark.circle.fill", tint: .systemRed,
                                     action: #selector(stopTapped), help: "Stop and close")

        sourceControl.target = self
        sourceControl.action = #selector(sourceChanged)
        sourceControl.segmentDistribution = .fillEqually
        sourceControl.controlSize = .small
        sourceControl.translatesAutoresizingMaskIntoConstraints = false

        let separator = HairlineSeparatorView()
        separator.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 15)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        [statusLabel, costLabel, collapseButton, closeButton, sourceControl, separator, scrollView]
            .forEach { content.addSubview($0) }

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            closeButton.widthAnchor.constraint(equalToConstant: 15),
            closeButton.heightAnchor.constraint(equalToConstant: 15),

            collapseButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            collapseButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            collapseButton.widthAnchor.constraint(equalToConstant: 15),
            collapseButton.heightAnchor.constraint(equalToConstant: 15),

            statusLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            costLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            costLabel.trailingAnchor.constraint(equalTo: collapseButton.leadingAnchor, constant: -10),
            costLabel.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 8),

            sourceControl.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 10),
            sourceControl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            sourceControl.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),

            separator.topAnchor.constraint(equalTo: sourceControl.bottomAnchor, constant: 10),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            separator.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    private func buildIndicator() {
        let content = installGlass(in: indicatorPanel, cornerRadius: 23)
        // We handle dragging ourselves (drag to move, click to expand), so don't
        // let the window also move on background drags.
        indicatorPanel.isMovableByWindowBackground = false

        let indicator = RecordIndicatorView(frame: content.bounds)
        indicator.autoresizingMask = [.width, .height]
        indicator.onClick = { [weak self] in self?.onToggleCollapse?() }
        content.addSubview(indicator)
    }

    func setSource(_ source: LiveAudioSource) {
        sourceControl.selectedSegment = (source == .systemAudio) ? 0 : 1
    }

    func showCaptions() {
        indicatorPanel.orderOut(nil)
        if panel.frame.origin == .zero, let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - 460, y: visible.minY + 60))
        }
        panel.orderFrontRegardless()
    }

    func showIndicator() {
        let anchor = panel.frame
        panel.orderOut(nil)
        let origin: NSPoint
        if anchor.origin == .zero {
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
            origin = NSPoint(x: visible.maxX - indicatorPanel.frame.width - 20, y: visible.minY + 60)
        } else {
            origin = NSPoint(x: anchor.maxX - indicatorPanel.frame.width, y: anchor.minY)
        }
        indicatorPanel.setFrameOrigin(origin)
        indicatorPanel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
        indicatorPanel.orderOut(nil)
    }

    func update(status: String) { statusLabel.stringValue = status }

    func update(cost: String) {
        costLabel.stringValue = cost
    }

    func render(_ transcript: LiveTranscript) {
        let body = NSMutableAttributedString()
        let count = transcript.lines.count
        for (idx, line) in transcript.lines.enumerated() {
            let suffix = idx < count - 1 ? "\n\n" : ""
            body.append(NSAttributedString(string: line.text + suffix, attributes: [
                .font: NSFont.systemFont(ofSize: 15),
                .foregroundColor: line.isFinalized ? Self.bodyColor : Self.partialColor
            ]))
        }
        textView.textStorage?.setAttributedString(body)
        textView.scrollToEndOfDocument(nil)
    }

    @objc private func stopTapped() { onStop?() }
    @objc private func collapseTapped() { onToggleCollapse?() }
    @objc private func sourceChanged() {
        onSourceChange?(sourceControl.selectedSegment == 0 ? .systemAudio : .microphone)
    }
}

/// Owns the live-translation lifecycle: single switchable audio source,
/// sentence-segmented transcript, collapsible panel.
@MainActor
final class LiveTranslationController: NSObject {
    static let perMinuteCostUSD = 0.034

    private(set) var isRunning = false
    private(set) var isCollapsed = false
    private let panel = LiveCaptionPanelController()
    private var transcript = LiveTranscript()
    private var systemCapture: SystemAudioCapture?
    private var micCapture: MicrophoneCapture?
    private var session: RealtimeTranslationSession?
    private var elapsedTimer: Timer?
    private var pauseTimer: Timer?
    private var startDate: Date?
    private var startGeneration = 0
    private var activeSource: LiveAudioSource = .systemAudio
    private var targetLanguage: TranslationLanguage = .defaultLanguage

    var onMissingAPIKey: (() -> Void)?

    func toggle(apiKey: String?, targetLanguage: TranslationLanguage) {
        if isRunning {
            toggleCollapsed()
        } else {
            start(apiKey: apiKey, targetLanguage: targetLanguage)
        }
    }

    func start(apiKey: String?, targetLanguage: TranslationLanguage) {
        guard let apiKey, !apiKey.isEmpty else { onMissingAPIKey?(); return }
        guard !isRunning else { return }
        isRunning = true
        isCollapsed = false
        startGeneration += 1
        transcript = LiveTranscript()
        startDate = Date()
        self.targetLanguage = targetLanguage
        let source = LiveAudioSource.current
        activeSource = source

        panel.onStop = { [weak self] in self?.stop() }
        panel.onToggleCollapse = { [weak self] in self?.toggleCollapsed() }
        panel.onSourceChange = { [weak self] newSource in self?.changeSource(to: newSource) }
        panel.setSource(source)
        panel.render(transcript)
        panel.update(status: "Connecting… → \(targetLanguage.displayName)")
        panel.update(cost: "00:00 · ~$0.00")
        panel.showCaptions()

        let session = RealtimeTranslationSession(
            apiKey: apiKey,
            languageCode: LiveTranslationLanguage.apiCode(for: targetLanguage),
            safetyIdentifier: LiveTranslationController.safetyIdentifier()
        )
        session.onTranslatedDelta = { [weak self] delta in
            guard let self else { return }
            self.transcript.append(delta: delta)
            self.panel.render(self.transcript)
            self.reschedulePauseFinalize()
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
        guard isRunning else { return }
        isCollapsed.toggle()
        if isCollapsed { panel.showIndicator() } else { panel.showCaptions() }
    }

    func stop(finalStatus: String = "Stopped", keepVisible: Bool = false) {
        guard isRunning else { return }
        isRunning = false
        isCollapsed = false
        pauseTimer?.invalidate(); pauseTimer = nil
        elapsedTimer?.invalidate(); elapsedTimer = nil
        session?.onStatusChange = nil
        systemCapture?.stop(); systemCapture = nil
        micCapture?.stop(); micCapture = nil
        session?.close(); session = nil
        transcript.finalizeCurrent()
        panel.render(transcript)
        panel.update(status: finalStatus)
        if keepVisible { panel.showCaptions() } else { panel.close() }
    }

    private func reschedulePauseFinalize() {
        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 1.3, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.transcript.finalizeCurrent()
                self.panel.render(self.transcript)
            }
        }
    }

    private func startCostTimer() {
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateCost() }
        }
        updateCost()
    }

    private func updateCost() {
        guard let startDate else { return }
        let seconds = Date().timeIntervalSince(startDate)
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
