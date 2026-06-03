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

    func testTranscriptAccumulatesPartialUntilSentenceEnd() {
        var t = LiveTranscript()
        t.append(delta: "This is ")
        t.append(delta: "a test")
        XCTAssertEqual(t.lines.count, 1)
        XCTAssertEqual(t.lines[0].text, "This is a test")
        XCTAssertFalse(t.lines[0].isFinalized)
    }

    func testTranscriptSplitsCompletedSentences() {
        var t = LiveTranscript()
        t.append(delta: "Hello there. How are ")
        XCTAssertEqual(t.lines.count, 2)
        XCTAssertEqual(t.lines[0].text, "Hello there.")
        XCTAssertTrue(t.lines[0].isFinalized)
        XCTAssertEqual(t.lines[1].text, "How are")
        XCTAssertFalse(t.lines[1].isFinalized)
    }

    func testTranscriptDoesNotSplitDecimalsOrAbbreviations() {
        var t = LiveTranscript()
        t.append(delta: "It heats to 1.600 degrees via www.x.com")
        XCTAssertEqual(t.lines.count, 1)
        XCTAssertFalse(t.lines[0].isFinalized)
    }

    func testFinalizeClosesTrailingFragment() {
        var t = LiveTranscript()
        t.append(delta: "An unfinished thought")
        t.finalizeCurrent()
        XCTAssertEqual(t.lines.count, 1)
        XCTAssertTrue(t.lines[0].isFinalized)
        XCTAssertEqual(t.lines[0].text, "An unfinished thought")
    }

    func testSplitSentencesHelperSeparatesMultiple() {
        let (sentences, remainder) = LiveTranscript.splitSentences("One. Two! Three? four")
        XCTAssertEqual(sentences, ["One.", "Two!", "Three?"])
        XCTAssertEqual(remainder.trimmingCharacters(in: .whitespaces), "four")
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
