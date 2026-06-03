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

    func testDialogueAccumulatesTokensIntoOneSegmentWithoutGaps() {
        var d = LiveDialogue()
        d.appendOriginal("안녕", ms: 100)
        d.appendOriginal("하세요", ms: 200)
        d.appendTranslation("Hi ", ms: 300)
        d.appendTranslation("there", ms: 400)
        XCTAssertEqual(d.segments.count, 1)
        XCTAssertEqual(d.segments[0].original, "안녕하세요")
        XCTAssertEqual(d.segments[0].translation, "Hi there")
    }

    func testDialogueSplitsOnAudioGapAndPairsByIndex() {
        var d = LiveDialogue()
        // Utterance 1
        d.appendOriginal("안녕하세요", ms: 100)
        d.appendTranslation("Hello", ms: 300)
        // Big audio gap (> gapMs) → utterance 2 on both streams
        d.appendOriginal("잘 지내요", ms: 100 + LiveDialogue.gapMs + 200)
        d.appendTranslation("I'm fine", ms: 300 + LiveDialogue.gapMs + 200)
        XCTAssertEqual(d.segments.map(\.original), ["안녕하세요", "잘 지내요"])
        XCTAssertEqual(d.segments.map(\.translation), ["Hello", "I'm fine"])
    }

    func testDialoguePairsTranslationThatLagsBehindOriginal() {
        var d = LiveDialogue()
        // Original finishes utterance 1 and starts utterance 2 before the
        // translation of utterance 1 even arrives — they still pair by index.
        d.appendOriginal("first", ms: 0)
        d.appendOriginal("second", ms: LiveDialogue.gapMs + 100)
        d.appendTranslation("один", ms: 200)
        d.appendTranslation("два", ms: LiveDialogue.gapMs + 300)
        XCTAssertEqual(d.segments.map(\.original), ["first", "second"])
        XCTAssertEqual(d.segments.map(\.translation), ["один", "два"])
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
