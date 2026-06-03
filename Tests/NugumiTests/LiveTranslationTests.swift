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
}
