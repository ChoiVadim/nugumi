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
}
