# Live Translation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a real-time, two-way live-translation captions feature to Nugumi: capture system audio (Phase 1) and microphone (Phase 2), stream each to OpenAI `gpt-realtime-translate`, and render translated transcript deltas in a floating caption panel.

**Architecture:** A new `Sources/Nugumi/LiveTranslation.swift` subsystem. Audio sources (ScreenCaptureKit / AVAudioEngine) are downsampled to 24 kHz mono PCM16 and fed to per-direction `RealtimeTranslationSession` WebSockets. A `LiveTranslationController` owns lifecycle + the transcript model and drives a floating `LiveCaptionPanel`. Both streams translate into the existing `targetLanguage` setting; only transcript deltas are consumed (no audio playback). Entry points: a status-menu item + a global hotkey.

**Tech Stack:** Swift, AppKit, ScreenCaptureKit, AVFoundation (AVAudioConverter/AVAudioEngine), `URLSessionWebSocketTask`, Carbon hotkeys, XCTest.

**Spec:** `docs/superpowers/specs/2026-06-03-live-translation-design.md`

---

## File Structure

- **Create** `Sources/Nugumi/LiveTranslation.swift` — the whole subsystem:
  - `LiveTranslationLanguage.apiCode(for:)` — `TranslationLanguage` → Realtime ISO code.
  - `RealtimeServerEvent` — decodes server JSON → typed cases (tolerant of unknown).
  - `LiveTranscript` / `CaptionLine` — transcript model (partial + finalized lines).
  - `AudioBatcher` — accumulates PCM bytes, flushes ~100 ms chunks.
  - `PCM16Downsampler` — `AVAudioPCMBuffer` → 24 kHz mono PCM16 `Data`.
  - `RealtimeTranslationSession` — one WebSocket per direction.
  - `SystemAudioCapture` (Phase 1) / `MicrophoneCapture` (Phase 2).
  - `LiveCaptionPanelController` — floating panel UI.
  - `LiveTranslationController` — orchestration + lifecycle + cost timer.
- **Create** `Tests/NugumiTests/LiveTranslationTests.swift` — unit tests for the pure units.
- **Modify** `Sources/Nugumi/GlobalShortcuts.swift` — add `.liveTranslation` action.
- **Modify** `Sources/Nugumi/App.swift` — `TranslationLanguage.current`, menu tag + item, hotkey binding, toggle methods.
- **Modify** `Resources/Info.plist` — `NSMicrophoneUsageDescription` (Phase 2).

---

# PHASE 1 — Incoming (system audio → captions)

## Task 1: Language-code mapping

**Files:**

- Create: `Sources/Nugumi/LiveTranslation.swift`
- Test: `Tests/NugumiTests/LiveTranslationTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/NugumiTests/LiveTranslationTests.swift`:

```swift
import XCTest
@testable import Nugumi

final class LiveTranslationTests: XCTestCase {
    func testAPILanguageCodeMapsChineseToZh() {
        XCTAssertEqual(LiveTranslationLanguage.apiCode(for: TranslationLanguage.language(id: "zh-Hans")), "zh")
    }

    func testAPILanguageCodePassesThroughSimpleCodes() {
        XCTAssertEqual(LiveTranslationLanguage.apiCode(for: TranslationLanguage.language(id: "ko")), "ko")
        XCTAssertEqual(LiveTranslationLanguage.apiCode(for: TranslationLanguage.language(id: "en")), "en")
        XCTAssertEqual(LiveTranslationLanguage.apiCode(for: TranslationLanguage.language(id: "fr")), "fr")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LiveTranslationTests`
Expected: FAIL — `LiveTranslationLanguage` is undefined (compile error).

- [ ] **Step 3: Write minimal implementation**

Create `Sources/Nugumi/LiveTranslation.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LiveTranslationTests`
Expected: PASS (3 assertions).

- [ ] **Step 5: Commit**

```bash
git add Sources/Nugumi/LiveTranslation.swift Tests/NugumiTests/LiveTranslationTests.swift
git commit -m "feat(live-translation): language-code mapping for Realtime API"
```

---

## Task 2: Realtime server-event decoding

**Files:**

- Modify: `Sources/Nugumi/LiveTranslation.swift`
- Test: `Tests/NugumiTests/LiveTranslationTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `LiveTranslationTests`:

```swift
    func testDecodeTranslatedDelta() {
        let json = #"{"type":"session.output_transcript.delta","delta":"안녕"}"#
        XCTAssertEqual(RealtimeServerEvent(jsonString: json), .translatedDelta("안녕"))
    }

    func testDecodeSourceDelta() {
        let json = #"{"type":"session.input_transcript.delta","delta":"hello"}"#
        XCTAssertEqual(RealtimeServerEvent(jsonString: json), .sourceDelta("hello"))
    }

    func testDecodeClosed() {
        XCTAssertEqual(RealtimeServerEvent(jsonString: #"{"type":"session.closed"}"#), .closed)
    }

    func testDecodeError() {
        let json = #"{"type":"error","error":{"message":"bad key"}}"#
        XCTAssertEqual(RealtimeServerEvent(jsonString: json), .error("bad key"))
    }

    func testDecodeUnknownEventIsIgnored() {
        let json = #"{"type":"session.output_audio.delta","delta":"<base64>"}"#
        XCTAssertEqual(RealtimeServerEvent(jsonString: json), .ignored)
    }

    func testDecodeMalformedIsIgnored() {
        XCTAssertEqual(RealtimeServerEvent(jsonString: "not json"), .ignored)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LiveTranslationTests`
Expected: FAIL — `RealtimeServerEvent` undefined.

- [ ] **Step 3: Write minimal implementation**

Append to `LiveTranslation.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LiveTranslationTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nugumi/LiveTranslation.swift Tests/NugumiTests/LiveTranslationTests.swift
git commit -m "feat(live-translation): tolerant Realtime server-event decoding"
```

---

## Task 3: Transcript model

**Files:**

- Modify: `Sources/Nugumi/LiveTranslation.swift`
- Test: `Tests/NugumiTests/LiveTranslationTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `LiveTranslationTests`:

```swift
    func testTranscriptAccumulatesDeltasIntoOnePartialLine() {
        var t = LiveTranscript()
        t.appendDelta(speaker: .them, text: "Hel")
        t.appendDelta(speaker: .them, text: "lo")
        XCTAssertEqual(t.lines.count, 1)
        XCTAssertEqual(t.lines[0].speaker, .them)
        XCTAssertEqual(t.lines[0].text, "Hello")
        XCTAssertFalse(t.lines[0].isFinalized)
    }

    func testSwitchingSpeakerFinalizesPreviousLine() {
        var t = LiveTranscript()
        t.appendDelta(speaker: .them, text: "Hello")
        t.appendDelta(speaker: .me, text: "Hi")
        XCTAssertEqual(t.lines.count, 2)
        XCTAssertTrue(t.lines[0].isFinalized)
        XCTAssertEqual(t.lines[1].speaker, .me)
        XCTAssertEqual(t.lines[1].text, "Hi")
    }

    func testFinalizeRollsToNewLineForSameSpeaker() {
        var t = LiveTranscript()
        t.appendDelta(speaker: .them, text: "First")
        t.finalizeCurrent()
        t.appendDelta(speaker: .them, text: "Second")
        XCTAssertEqual(t.lines.map(\.text), ["First", "Second"])
        XCTAssertTrue(t.lines[0].isFinalized)
        XCTAssertFalse(t.lines[1].isFinalized)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LiveTranslationTests`
Expected: FAIL — `LiveTranscript` undefined.

- [ ] **Step 3: Write minimal implementation**

Append to `LiveTranslation.swift`:

```swift
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
            if !lines.isEmpty, lines[lines.count - 1].isFinalized == false {
                lines[lines.count - 1].isFinalized = true
            }
            lines.append(CaptionLine(speaker: speaker, text: text, isFinalized: false))
        }
    }

    mutating func finalizeCurrent() {
        guard let last = lines.last, !last.isFinalized else { return }
        lines[lines.count - 1].isFinalized = true
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LiveTranslationTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nugumi/LiveTranslation.swift Tests/NugumiTests/LiveTranslationTests.swift
git commit -m "feat(live-translation): caption transcript model"
```

---

## Task 4: Audio batcher

**Files:**

- Modify: `Sources/Nugumi/LiveTranslation.swift`
- Test: `Tests/NugumiTests/LiveTranslationTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `LiveTranslationTests`:

```swift
    func testBatcherFlushesAtThreshold() {
        // 24kHz mono PCM16 => 48000 bytes/sec => 4800 bytes per 100ms.
        var flushed: [Data] = []
        let batcher = AudioBatcher(thresholdBytes: 4800) { flushed.append($0) }
        batcher.add(Data(count: 3000))
        XCTAssertTrue(flushed.isEmpty)
        batcher.add(Data(count: 2000)) // total 5000 >= 4800 -> flush
        XCTAssertEqual(flushed.count, 1)
        XCTAssertEqual(flushed[0].count, 5000)
    }

    func testBatcherFlushPushesRemainder() {
        var flushed: [Data] = []
        let batcher = AudioBatcher(thresholdBytes: 4800) { flushed.append($0) }
        batcher.add(Data(count: 100))
        batcher.flush()
        XCTAssertEqual(flushed.map(\.count), [100])
        batcher.flush() // empty buffer -> no extra flush
        XCTAssertEqual(flushed.count, 1)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LiveTranslationTests`
Expected: FAIL — `AudioBatcher` undefined.

- [ ] **Step 3: Write minimal implementation**

Append to `LiveTranslation.swift`:

```swift
/// Accumulates raw PCM bytes and flushes whole chunks once they reach a byte
/// threshold (~100 ms), so we send fewer, larger `input_audio_buffer.append`
/// frames instead of one per capture callback.
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LiveTranslationTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nugumi/LiveTranslation.swift Tests/NugumiTests/LiveTranslationTests.swift
git commit -m "feat(live-translation): PCM audio batcher"
```

---

## Task 5: PCM16 downsampler

**Files:**

- Modify: `Sources/Nugumi/LiveTranslation.swift`
- Test: `Tests/NugumiTests/LiveTranslationTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `LiveTranslationTests`:

```swift
    func testDownsampler48kFloatTo24kPCM16HalvesFrames() throws {
        let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let frames: AVAudioFrameCount = 4800 // 100ms @ 48k
        let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames)!
        inBuffer.frameLength = frames
        for i in 0..<Int(frames) { inBuffer.floatChannelData![0][i] = 0 }

        let downsampler = PCM16Downsampler()
        let data = try downsampler.pcm16Data(from: inBuffer)
        // 2400 frames @ 24k * 2 bytes = 4800 bytes (allow small converter slack).
        XCTAssertGreaterThan(data.count, 4000)
        XCTAssertLessThan(data.count, 5200)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LiveTranslationTests`
Expected: FAIL — `PCM16Downsampler` undefined.

- [ ] **Step 3: Write minimal implementation**

Append to `LiveTranslation.swift`:

```swift
/// Converts arbitrary-format capture buffers to the Realtime API's required
/// 24 kHz mono PCM16 little-endian byte stream. One converter is lazily built
/// per distinct input format.
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
        guard let converter else { return Data() }

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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LiveTranslationTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nugumi/LiveTranslation.swift Tests/NugumiTests/LiveTranslationTests.swift
git commit -m "feat(live-translation): 24kHz mono PCM16 downsampler"
```

---

## Task 6: Realtime translation WebSocket session

**Files:**

- Modify: `Sources/Nugumi/LiveTranslation.swift`

This component is network I/O; verification is build + Task 11 manual E2E. It reuses `RealtimeServerEvent` (Task 2) and `AudioBatcher` (Task 4).

- [ ] **Step 1: Implement the session**

Append to `LiveTranslation.swift`:

```swift
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

    init(apiKey: String, languageCode: String, safetyIdentifier: String) {
        self.apiKey = apiKey
        self.languageCode = languageCode
        self.safetyIdentifier = safetyIdentifier
    }

    func connect() {
        isClosing = false
        onStatusChange?(reconnectAttempts == 0 ? .connecting : .reconnecting)

        var request = URLRequest(
            url: URL(string: "wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate")!
        )
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(safetyIdentifier, forHTTPHeaderField: "OpenAI-Safety-Identifier")

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        task.resume()
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
        // Give the server a moment to reply session.closed; then tear down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.task?.cancel(with: .normalClosure, reason: nil)
            self?.onStatusChange?(.closed)
        }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        reconnectAttempts = 0
        // Configure target language for translation output.
        sendJSON([
            "type": "session.update",
            "session": ["audio": ["output": ["language": languageCode]]]
        ])
        onStatusChange?(.listening)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard !isClosing else { return }
        scheduleReconnect()
    }

    // MARK: Private

    private func receiveNext() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                if !self.isClosing { self.scheduleReconnect() }
            case .success(let message):
                if case let .string(text) = message {
                    self.handle(event: RealtimeServerEvent(jsonString: text))
                }
                self.receiveNext()
            }
        }
    }

    private func handle(event: RealtimeServerEvent) {
        switch event {
        case .translatedDelta(let text):
            DispatchQueue.main.async { self.onTranslatedDelta?(text) }
        case .error(let message):
            DispatchQueue.main.async { self.onStatusChange?(.failed(message)) }
        case .closed:
            DispatchQueue.main.async { self.onStatusChange?(.closed) }
        case .sourceDelta, .ignored:
            break
        }
    }

    private func sendAudioChunk(_ pcm: Data) {
        sendJSON(["type": "session.input_audio_buffer.append",
                  "audio": pcm.base64EncodedString()])
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(string)) { _ in }
    }

    private func scheduleReconnect() {
        reconnectAttempts += 1
        guard reconnectAttempts <= 5 else {
            DispatchQueue.main.async { self.onStatusChange?(.failed("Connection lost")) }
            return
        }
        let delay = min(pow(2.0, Double(reconnectAttempts)), 16.0)
        DispatchQueue.main.async { self.onStatusChange?(.reconnecting) }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isClosing else { return }
            self.connect()
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds (no errors).

- [ ] **Step 3: Commit**

```bash
git add Sources/Nugumi/LiveTranslation.swift
git commit -m "feat(live-translation): Realtime WebSocket session"
```

---

## Task 7: System-audio capture (ScreenCaptureKit)

**Files:**

- Modify: `Sources/Nugumi/LiveTranslation.swift`

I/O component; verified by build + Task 11. Reuses `PCM16Downsampler`.

- [ ] **Step 1: Implement system-audio capture**

Append to `LiveTranslation.swift`:

```swift
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
            // Minimal video config (ScreenCaptureKit requires it even for audio).
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
        stream?.stopCapture { _ in }
        stream = nil
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
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/Nugumi/LiveTranslation.swift
git commit -m "feat(live-translation): ScreenCaptureKit system-audio capture"
```

---

## Task 8: Caption panel UI

**Files:**

- Modify: `Sources/Nugumi/LiveTranslation.swift`

I/O/UI component; verified by build + Task 11. Renders a `LiveTranscript` (Task 3).

- [ ] **Step 1: Implement the caption panel**

Append to `LiveTranslation.swift`:

```swift
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
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/Nugumi/LiveTranslation.swift
git commit -m "feat(live-translation): floating caption panel"
```

---

## Task 9: Live translation controller (Phase 1, single session)

**Files:**

- Modify: `Sources/Nugumi/LiveTranslation.swift`

Orchestration; verified by build + Task 11. Wires `SystemAudioCapture` → `RealtimeTranslationSession` → `LiveTranscript` → `LiveCaptionPanelController`, with an elapsed/cost timer.

- [ ] **Step 1: Implement the controller**

Append to `LiveTranslation.swift`:

```swift
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
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/Nugumi/LiveTranslation.swift
git commit -m "feat(live-translation): controller orchestration (Phase 1)"
```

---

## Task 10: Entry points (menu item + hotkey + target-language accessor)

**Files:**

- Modify: `Sources/Nugumi/GlobalShortcuts.swift:5-76`
- Modify: `Sources/Nugumi/App.swift` (MenuItemTag, TranslationLanguage, setupStatusItem, bindings, new methods)

- [ ] **Step 1: Add the shortcut action**

In `Sources/Nugumi/GlobalShortcuts.swift`, add `case liveTranslation` to the enum (after `askNugumi`, line ~10):

```swift
    case askNugumi
    case liveTranslation
```

Add its `id` (in the `var id: UInt32` switch, after `.askNugumi`):

```swift
        case .askNugumi: return 5
        case .liveTranslation: return 6
```

Add its `menuTitle` (in the `var menuTitle` switch):

```swift
        case .askNugumi: return "Ask Nugumi"
        case .liveTranslation: return "Live translation captions"
```

Add its `defaultShortcut` (in the `var defaultShortcut` switch, before the closing brace):

```swift
        case .liveTranslation:
            return GlobalShortcut(
                keyCode: UInt32(kVK_ANSI_4),
                modifiers: [.control],
                keyEquivalent: "4",
                keyDisplay: "4"
            )
```

- [ ] **Step 2: Add a current-language accessor**

In `Sources/Nugumi/App.swift`, inside the `TranslationLanguage` struct (after `static func language(id:)`, near line 537), add:

```swift
    /// The user's active target language, read from the same default the menu writes.
    static var current: TranslationLanguage {
        language(id: UserDefaults.standard.string(forKey: "targetLanguageID") ?? defaultLanguage.id)
    }
```

- [ ] **Step 3: Add the menu tag**

In `MenuItemTag` (App.swift:11-39), add after `permissionsOnboarding = 126`:

```swift
    case liveTranslation = 127
```

- [ ] **Step 4: Add the controller property + menu item + toggle**

In the `AppDelegate` class, add a stored property near `globalHotKeys` (App.swift:851):

```swift
    private lazy var liveTranslationController: LiveTranslationController = {
        let controller = LiveTranslationController()
        controller.onMissingAPIKey = { [weak self] in self?.presentLiveTranslationAPIKeyAlert() }
        return controller
    }()
```

In `setupStatusItem()`, in the "Shortcuts" section (after the `translateOrReplySelection` item near App.swift:1826), add:

```swift
        menu.addItem(makeMenuItem(
            title: "Live translation captions",
            tag: .liveTranslation,
            symbolName: "captions.bubble",
            action: #selector(toggleLiveTranslationFromMenu)
        ))
```

Add these methods to `AppDelegate` (near the other `@objc` menu handlers, e.g. after `translateOrReplySelectionFromMenu` at App.swift:3479):

```swift
    @MainActor
    @objc private func toggleLiveTranslationFromMenu() {
        toggleLiveTranslation()
    }

    @MainActor
    private func toggleLiveTranslation() {
        liveTranslationController.toggle(
            apiKey: KeychainStore.apiKey(for: .openAI),
            targetLanguage: TranslationLanguage.current
        )
    }

    @MainActor
    private func presentLiveTranslationAPIKeyAlert() {
        let alert = NSAlert()
        alert.messageText = "OpenAI API key required"
        alert.informativeText = "Live translation uses OpenAI's realtime model. Add an OpenAI API key from the model menu (API key models) and try again."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
```

- [ ] **Step 5: Register the hotkey**

In the bindings array (App.swift:1092-1098), add a row:

```swift
            (.askNugumi, { [weak self] in self?.startAskNugumiPrompt() }),
            (.liveTranslation, { [weak self] in self?.toggleLiveTranslation() })
```

- [ ] **Step 6: Build and test**

Run: `swift build && swift test --filter LiveTranslationTests`
Expected: Build succeeds; tests PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/Nugumi/GlobalShortcuts.swift Sources/Nugumi/App.swift
git commit -m "feat(live-translation): menu item + global hotkey entry points"
```

---

## Task 11: Phase 1 manual end-to-end verification

**Files:** none (verification only).

ScreenCaptureKit permission identity is stable only in the signed bundle, so verify with the real app, not `swift run`.

- [ ] **Step 1: Build the app bundle**

Run: `bash Scripts/build-app-bundle.sh`
Expected: `dist/Nugumi.app` produced.

- [ ] **Step 2: Launch and grant permission**

Run: `open dist/Nugumi.app`

- Ensure an OpenAI API key is set (model menu → API key models).
- Trigger "Live translation captions" from the status menu (or Control+4).
- Grant Screen Recording when prompted (System Settings → Privacy → Screen Recording → enable Nugumi → relaunch if required).

- [ ] **Step 3: Verify captions**

- Play a foreign-language video (e.g., a YouTube clip not in your target language) with audio audible to the system.
- Expected: the panel shows status "Listening → <target>", and translated `Them:` caption lines appear and update live; the cost/elapsed readout ticks.

- [ ] **Step 4: Verify stop + reconnect**

- Click Stop (or Control+4): status becomes "Stopped", capture ends.
- Restart, then toggle Wi-Fi off briefly: status shows "Reconnecting…", then "Listening" again on restore.

- [ ] **Step 5: Commit (notes only, if any tweaks were needed)**

```bash
git commit --allow-empty -m "test(live-translation): Phase 1 manual E2E verified"
```

---

# PHASE 2 — Microphone direction

## Task 12: Microphone capture

**Files:**

- Modify: `Sources/Nugumi/LiveTranslation.swift`

I/O component; verified by build + Task 15. Reuses `PCM16Downsampler`.

- [ ] **Step 1: Implement microphone capture**

Append to `LiveTranslation.swift`:

```swift
/// Captures the default input device via AVAudioEngine and emits 24 kHz mono
/// PCM16 byte chunks.
final class MicrophoneCapture {
    var onPCM: ((Data) -> Void)?
    var onError: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let downsampler = PCM16Downsampler()

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
        input.installTap(onBus: 0, bufferSize: 2400, format: format) { [weak self] buffer, _ in
            guard let self, let data = try? self.downsampler.pcm16Data(from: buffer) else { return }
            self.onPCM?(data)
        }
        do {
            try engine.start()
        } catch {
            onError?("Microphone capture failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/Nugumi/LiveTranslation.swift
git commit -m "feat(live-translation): microphone capture"
```

---

## Task 13: Microphone usage description

**Files:**

- Modify: `Resources/Info.plist`

- [ ] **Step 1: Add the usage string**

In `Resources/Info.plist`, add alongside the other usage descriptions (next to `NSScreenCaptureUsageDescription`):

```xml
	<key>NSMicrophoneUsageDescription</key>
	<string>Nugumi uses the microphone to translate what you say in real time into live captions.</string>
```

- [ ] **Step 2: Build to verify the plist is valid**

Run: `plutil -lint Resources/Info.plist`
Expected: `Resources/Info.plist: OK`

- [ ] **Step 3: Commit**

```bash
git add Resources/Info.plist
git commit -m "feat(live-translation): microphone usage description"
```

---

## Task 14: Add the mic session to the controller

**Files:**

- Modify: `Sources/Nugumi/LiveTranslation.swift` (`LiveTranslationController`)

Wires a second session for `.me`, requests mic auth, and bumps the billed-session count.

- [ ] **Step 1: Add mic fields**

In `LiveTranslationController`, add stored properties next to the system ones:

```swift
    private var micCapture: MicrophoneCapture?
    private var micSession: RealtimeTranslationSession?
```

- [ ] **Step 2: Start the mic direction**

In `LiveTranslationController.start(apiKey:targetLanguage:)`, after `startCostTimer()`, append:

```swift
        // Microphone direction (best-effort; system audio works without it).
        let safetyID = LiveTranslationController.safetyIdentifier()
        Task { [weak self] in
            guard await MicrophoneCapture.requestAuthorization() else {
                self?.panel.update(status: "Microphone permission denied — captions show their audio only.")
                return
            }
            guard let self, self.isRunning else { return }
            let micSession = RealtimeTranslationSession(
                apiKey: apiKey, languageCode: languageCode, safetyIdentifier: safetyID
            )
            micSession.onTranslatedDelta = { [weak self] delta in
                guard let self else { return }
                self.transcript.appendDelta(speaker: .me, text: delta)
                self.panel.render(self.transcript)
            }
            micSession.connect()
            self.micSession = micSession

            let mic = MicrophoneCapture()
            mic.onPCM = { [weak micSession] data in micSession?.append(pcm: data) }
            mic.onError = { [weak self] message in self?.panel.update(status: message) }
            mic.start()
            self.micCapture = mic
            self.activeSessionCount = 2
        }
```

> Note: `languageCode` is already a local `let` in `start(...)` from Task 9; reuse it. `safetyID` reuses the same per-install identifier.

- [ ] **Step 3: Tear down the mic direction**

In `LiveTranslationController.stop()`, before `transcript.finalizeCurrent()`, add:

```swift
        micCapture?.stop(); micCapture = nil
        micSession?.close(); micSession = nil
        activeSessionCount = 1
```

- [ ] **Step 4: Build and test**

Run: `swift build && swift test --filter LiveTranslationTests`
Expected: Build succeeds; tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nugumi/LiveTranslation.swift
git commit -m "feat(live-translation): add microphone direction (Phase 2)"
```

---

## Task 15: Phase 2 manual end-to-end verification

**Files:** none (verification only).

- [ ] **Step 1: Build the app bundle**

Run: `bash Scripts/build-app-bundle.sh`
Expected: `dist/Nugumi.app` produced.

- [ ] **Step 2: Launch, grant mic permission**

Run: `open dist/Nugumi.app`

- Start live translation; grant Microphone when prompted.

- [ ] **Step 3: Verify two-way captions**

- Speak a non-target language into the mic → expect `Me:` translated caption lines.
- Simultaneously play foreign system audio → expect `Them:` lines interleaved.
- Expect the cost readout reflect two sessions (~$0.068/min).

- [ ] **Step 4: Verify graceful mic-denied path**

- Deny Microphone (System Settings) and restart: expect a status message that only system audio is captioned; `Them:` lines still work.

- [ ] **Step 5: Commit**

```bash
git commit --allow-empty -m "test(live-translation): Phase 2 manual E2E verified"
```

---

## Self-Review Notes

- **Spec coverage:** audio capture (Tasks 7, 12), two Realtime sessions (Tasks 6, 9, 14), transcript-only captions (Tasks 3, 8), reuse existing target language (Task 10 `TranslationLanguage.current`), menu + hotkey (Task 10), permissions (Tasks 7, 12, 13), error handling (session `.failed`, capture `onError`, missing-key alert), cost display (Task 9), language-code mapping incl. `zh-Hans` (Task 1), phased build (Phase 1 → Phase 2). All spec sections map to tasks.
- **Type consistency:** `RealtimeServerEvent`, `AudioBatcher(thresholdBytes:onChunk:)`, `PCM16Downsampler.pcm16Data(from:)`, `LiveTranscript.appendDelta(speaker:text:)`/`finalizeCurrent()`, `RealtimeTranslationSession(apiKey:languageCode:safetyIdentifier:)` + `append(pcm:)`/`connect()`/`close()`, `LiveTranslationController.toggle(apiKey:targetLanguage:)` are referenced consistently across tasks.
- **Known follow-ups (out of scope):** local VAD silence-gating, idle auto-pause, per-direction target languages, transcript export.

```

```
