import XCTest
@testable import Gizmate

final class BrowserSummaryTests: XCTestCase {
    func testKnownBrowsersAreDetected() {
        XCTAssertTrue(BrowserPageReader.isBrowser("com.apple.Safari"))
        XCTAssertTrue(BrowserPageReader.isBrowser("com.google.Chrome"))
        XCTAssertTrue(BrowserPageReader.isBrowser("company.thebrowser.Browser"))
        XCTAssertTrue(BrowserPageReader.isBrowser("com.naver.whale"))
        XCTAssertFalse(BrowserPageReader.isBrowser("com.kakao.KakaoTalkMac"))
        XCTAssertFalse(BrowserPageReader.isBrowser(nil))
    }

    // .summarizePage must mirror .summarizeChat's behavior contract — a page
    // summary that quietly landed in history or picked up composition
    // settings would be a regression.
    func testSummarizePageMirrorsSummarizeChatContract() {
        XCTAssertEqual(TranslationMode.summarizePage.resultLabel, TranslationMode.summarizeChat.resultLabel)
        XCTAssertEqual(TranslationMode.summarizePage.loadingPlaceholder, TranslationMode.summarizeChat.loadingPlaceholder)
        XCTAssertFalse(TranslationMode.summarizePage.usesCompositionSettings)
    }
}
