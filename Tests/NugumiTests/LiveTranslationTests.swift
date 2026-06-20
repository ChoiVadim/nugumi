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

    func testRowsPairSourceAndTranslationByOrder() {
        var d = LiveDialogue()
        // Two source sentences (split by a long pause) + two translated sentences.
        d.appendOriginal("안녕하세요", ms: 100)
        d.appendOriginal("반갑습니다", ms: 100 + LiveDialogue.sourceGapMs + 200)
        d.appendTranslation("Hello.", ms: 300)
        d.appendTranslation(" Nice to meet you.", ms: 600)
        XCTAssertEqual(d.rows, [
            LiveDialogue.Row(source: "안녕하세요", translation: "Hello."),
            LiveDialogue.Row(source: "반갑습니다", translation: "Nice to meet you."),
        ])
    }

    func testTranslationSplitsOnSentencePunctuation() {
        var d = LiveDialogue()
        d.appendTranslation("Hello", ms: 0)
        d.appendTranslation(" world.", ms: 50)   // sentence ends
        d.appendTranslation(" Bye", ms: 100)     // next sentence
        XCTAssertEqual(d.translations, ["Hello world.", " Bye"])
    }

    func testSourceSplitsOnLongPauseNotShortPause() {
        var d = LiveDialogue()
        d.appendOriginal("코딩의", ms: 0)
        d.appendOriginal("흐름이", ms: 800)                      // short phrase pause → same unit
        d.appendOriginal("디자인", ms: 800 + LiveDialogue.sourceGapMs + 100)   // long pause → new unit
        XCTAssertEqual(d.originals, ["코딩의흐름이", "디자인"])
    }

    func testUntranslatedSourceCollectsInLiveRow() {
        var d = LiveDialogue()
        d.appendOriginal("문장하나", ms: 0)
        d.appendOriginal("문장둘", ms: LiveDialogue.sourceGapMs + 100)
        d.appendTranslation("Sentence one.", ms: 200)   // only the first is translated
        XCTAssertEqual(d.rows, [
            LiveDialogue.Row(source: "문장하나", translation: "Sentence one."),
            LiveDialogue.Row(source: "문장둘", translation: ""),   // live edge — not yet translated
        ])
    }

    func testDialogueTranslationTextJoinsAllSegments() {
        var d = LiveDialogue()
        d.appendTranslation("Hello.", ms: 0)
        d.appendTranslation(" Bye", ms: 100)
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

    /// Smoke test for the rebuilt two-column caption panel: constructing it
    /// activates buildCaptions + buildSummaryColumn (the collapsed summary
    /// column at width 0 must not produce conflicting/required constraints),
    /// and rendering must not trap.
    @MainActor
    func testCaptionPanelBuildsAndRendersWithoutCrash() {
        let panel = LiveCaptionPanelController()
        panel.setSource(.systemAudio)
        panel.setSource(.microphone)     // single source toggle swaps its glyph
        panel.setShowSource(true)
        panel.setPaused(true)            // pause/resume glyph swap
        panel.setPaused(false)
        panel.update(status: "Listening → English")
        var d = LiveDialogue()
        d.appendOriginal("안녕하세요", ms: 100)
        d.appendTranslation("Hello", ms: 200)
        panel.render(d, showSource: true)
        // Open the summary: exercises side selection + the parked-column layout.
        panel.showSummary("**TL;DR:** test\n- one\n- two")
    }
}
