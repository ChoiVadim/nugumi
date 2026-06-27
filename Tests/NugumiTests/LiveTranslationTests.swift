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

    /// Decoupled streams: source and translation are SEPARATE rows (each carries only
    /// its own side), rendered in the order their first tokens arrived.
    func testSourceAndTranslationAreSeparateRowsInArrivalOrder() {
        var d = LiveDialogue()
        d.appendOriginal("привет.", ms: 1000)
        d.appendTranslation("Hello.", ms: 1200)
        XCTAssertEqual(d.rows, [
            LiveDialogue.Row(source: "привет.", translation: ""),
            LiveDialogue.Row(source: "", translation: "Hello."),
        ])
    }

    /// A long translation splits per sentence into its OWN rows — no giant block
    /// piling onto one source segment (the wall-of-text complaint).
    func testTranslationSplitsPerSentenceIntoSeparateRows() {
        var d = LiveDialogue()
        d.appendOriginal("исходник.", ms: 1000)
        d.appendTranslation("One.", ms: 1100)
        d.appendTranslation(" Two.", ms: 1200)
        d.appendTranslation(" Three.", ms: 1300)
        XCTAssertEqual(d.rows.filter { !$0.translation.isEmpty }.map(\.translation),
                       ["One.", "Two.", "Three."])
    }

    /// Interleaved arrival order is preserved (source1, trans1, source2, trans2…).
    func testInterleavedArrivalOrderPreserved() {
        var d = LiveDialogue()
        let gap = LiveDialogue.sourceGapMs
        d.appendOriginal("рус1.", ms: 1000)
        d.appendTranslation("Eng1.", ms: 1200)
        d.appendOriginal("рус2.", ms: 1000 + gap + 200)
        d.appendTranslation("Eng2.", ms: 4000)
        XCTAssertEqual(d.rows, [
            LiveDialogue.Row(source: "рус1.", translation: ""),
            LiveDialogue.Row(source: "", translation: "Eng1."),
            LiveDialogue.Row(source: "рус2.", translation: ""),
            LiveDialogue.Row(source: "", translation: "Eng2."),
        ])
    }

    /// When the translation LEADS the source (the sign-flipped lag that broke
    /// pairing), it simply renders first — no merging, no offset, no crash.
    func testTranslationLeadingSourceRendersTranslationFirst() {
        var d = LiveDialogue()
        d.appendTranslation("We went fishing.", ms: 1000)    // translation arrives first
        d.appendOriginal("выехали на рыбалку.", ms: 1500)     // its source lands later
        XCTAssertEqual(d.rows, [
            LiveDialogue.Row(source: "", translation: "We went fishing."),
            LiveDialogue.Row(source: "выехали на рыбалку.", translation: ""),
        ])
    }

    func testCollapseLoopsCollapsesRepeatedWordGroups() {
        XCTAssertEqual(LiveDialogue.collapseLoops("ты ты ты ты должен был"), "ты должен был")
        XCTAssertEqual(
            LiveDialogue.collapseLoops("нам стоит уйти, нам стоит уйти, нам стоит уйти, нам стоит уйти."),
            "нам стоит уйти, нам стоит уйти.")
        // Two reps survive (genuine emphasis), only 3+ collapse.
        XCTAssertEqual(LiveDialogue.collapseLoops("very very good"), "very very good")
        XCTAssertEqual(LiveDialogue.collapseLoops("symmetrically, symmetrically."), "symmetrically, symmetrically.")
    }

    func testSourceSplitsOnLongPauseNotShortPause() {
        var d = LiveDialogue()
        d.appendOriginal("코딩의", ms: 0)
        d.appendOriginal("흐름이", ms: 800)                                  // short phrase pause → same row
        d.appendOriginal("디자인", ms: 800 + LiveDialogue.sourceGapMs + 100) // long pause → new row
        XCTAssertEqual(d.rows.map(\.source), ["코딩의흐름이", "디자인"])
    }

    func testSourceSplitsOnSentenceEndWithoutPause() {
        var d = LiveDialogue()
        d.appendOriginal("Hello.", ms: 1000)   // sentence ends
        d.appendOriginal(" Bye", ms: 1100)     // next sentence, no pause
        XCTAssertEqual(d.rows.map(\.source), ["Hello.", "Bye"])
    }

    /// Untranslated source still shows (as its own rows) while the translation
    /// catches up — nothing waits on a pairing.
    func testUntranslatedSourceStillShows() {
        var d = LiveDialogue()
        let gap = LiveDialogue.sourceGapMs
        d.appendOriginal("문장하나.", ms: 1000)
        d.appendOriginal("문장둘.", ms: 1000 + gap + 100)
        d.appendTranslation("Sentence one.", ms: 1100)  // only first translated so far
        XCTAssertEqual(d.rows, [
            LiveDialogue.Row(source: "문장하나.", translation: ""),
            LiveDialogue.Row(source: "문장둘.", translation: ""),
            LiveDialogue.Row(source: "", translation: "Sentence one."),
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
