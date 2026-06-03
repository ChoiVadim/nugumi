import AVFoundation
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

    func testDecodeTranslatedDeltaWithTimestamp() {
        let json = #"{"type":"session.output_transcript.delta","delta":"안녕","elapsed_ms":24000}"#
        XCTAssertEqual(RealtimeServerEvent(jsonString: json), .translatedDelta("안녕", ms: 24000))
    }

    func testDecodeSourceDeltaWithoutTimestamp() {
        let json = #"{"type":"session.input_transcript.delta","delta":"hello"}"#
        XCTAssertEqual(RealtimeServerEvent(jsonString: json), .sourceDelta("hello", ms: nil))
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

    private func tagged(_ d: LiveDialogue) -> [String] {
        d.timeline.map { ($0.isOriginal ? "o:" : "t:") + $0.text }
    }

    func testDialogueAccumulatesTokensIntoOneSegmentWithoutGaps() {
        var d = LiveDialogue()
        d.appendOriginal("안녕", ms: 100)
        d.appendOriginal("하세요", ms: 200)
        d.appendTranslation("Hi ", ms: 300)
        d.appendTranslation("there", ms: 400)
        XCTAssertEqual(tagged(d), ["o:안녕하세요", "t:Hi there"])
    }

    func testTimelineOrdersByAudioTimeNotArrival() {
        var d = LiveDialogue()
        // Both originals arrive first; translations arrive later in a batch.
        // Sorting by audio time must still interleave each pair correctly.
        d.appendOriginal("привет", ms: 1000)
        d.appendOriginal("пока", ms: 1000 + LiveDialogue.gapMs + 100)
        d.appendTranslation("hello", ms: 1100)
        d.appendTranslation("bye", ms: 1000 + LiveDialogue.gapMs + 200)
        XCTAssertEqual(tagged(d), ["o:привет", "t:hello", "o:пока", "t:bye"])
    }

    func testTimelineSplitsStreamOnAudioGap() {
        var d = LiveDialogue()
        d.appendTranslation("one", ms: 0)
        d.appendTranslation("two", ms: LiveDialogue.gapMs + 100)
        XCTAssertEqual(d.timeline.filter { !$0.isOriginal }.map(\.text), ["one", "two"])
    }

    func testTimelineTiePutsOriginalBeforeTranslation() {
        var d = LiveDialogue()
        d.appendTranslation("hi", ms: 500)
        d.appendOriginal("привет", ms: 500)
        XCTAssertEqual(d.timeline.map(\.isOriginal), [true, false])
    }

    func testDialogueTranslationTextJoinsAllSegments() {
        var d = LiveDialogue()
        d.appendTranslation("Hello", ms: 0)
        d.appendTranslation(".", ms: 100)
        d.appendTranslation("Bye", ms: LiveDialogue.gapMs + 200)
        XCTAssertEqual(d.translationText, "Hello. Bye")
    }

    func testBatcherFlushesAtThreshold() {
        var flushed: [Data] = []
        let batcher = AudioBatcher(thresholdBytes: 4800) { flushed.append($0) }
        batcher.add(Data(count: 3000))
        XCTAssertTrue(flushed.isEmpty)
        batcher.add(Data(count: 2000))
        XCTAssertEqual(flushed.count, 1)
        XCTAssertEqual(flushed[0].count, 5000)
    }

    func testBatcherFlushPushesRemainder() {
        var flushed: [Data] = []
        let batcher = AudioBatcher(thresholdBytes: 4800) { flushed.append($0) }
        batcher.add(Data(count: 100))
        batcher.flush()
        XCTAssertEqual(flushed.map(\.count), [100])
        batcher.flush()
        XCTAssertEqual(flushed.count, 1)
    }

    func testDownsampler48kFloatTo24kPCM16HalvesFrames() throws {
        let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let frames: AVAudioFrameCount = 4800
        let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames)!
        inBuffer.frameLength = frames
        for i in 0..<Int(frames) { inBuffer.floatChannelData![0][i] = 0 }

        let downsampler = PCM16Downsampler()
        let data = try downsampler.pcm16Data(from: inBuffer)
        XCTAssertGreaterThan(data.count, 4000)
        XCTAssertLessThan(data.count, 5200)
    }
}
