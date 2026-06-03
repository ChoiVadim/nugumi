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

    func testDialogueBuffersTranslationUntilUtteranceCompletes() {
        var d = LiveDialogue()
        d.appendTranslation("Hello ")
        d.appendTranslation("there")
        XCTAssertTrue(d.segments.isEmpty)
        XCTAssertEqual(d.pendingTranslation, "Hello there")
    }

    func testDialoguePairsOriginalWithBufferedTranslation() {
        var d = LiveDialogue()
        d.appendTranslation("Hello there")
        d.completeUtterance(original: "안녕하세요")
        XCTAssertEqual(d.segments.count, 1)
        XCTAssertEqual(d.segments[0].original, "안녕하세요")
        XCTAssertEqual(d.segments[0].translation, "Hello there")
        XCTAssertEqual(d.pendingTranslation, "")
    }

    func testDialogueKeepsConsecutiveUtterancesInSync() {
        var d = LiveDialogue()
        d.appendTranslation("How are you?")
        d.completeUtterance(original: "어떻게 지내세요?")
        d.appendTranslation("I'm fine.")
        d.completeUtterance(original: "잘 지내요.")
        XCTAssertEqual(d.segments.map(\.original), ["어떻게 지내세요?", "잘 지내요."])
        XCTAssertEqual(d.segments.map(\.translation), ["How are you?", "I'm fine."])
    }

    func testDialogueFlushPendingCreatesTranslationOnlySegment() {
        var d = LiveDialogue()
        d.appendTranslation("Trailing translation")
        d.flushPending()
        XCTAssertEqual(d.segments.count, 1)
        XCTAssertEqual(d.segments[0].original, "")
        XCTAssertEqual(d.segments[0].translation, "Trailing translation")
    }

    func testDialogueIgnoresEmptyUtterance() {
        var d = LiveDialogue()
        d.completeUtterance(original: "   ")
        d.flushPending()
        XCTAssertTrue(d.segments.isEmpty)
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
