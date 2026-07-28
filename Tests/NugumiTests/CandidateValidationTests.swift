import XCTest
@testable import Nugumi

final class CandidateValidationTests: XCTestCase {
    /// The whole point of the no-fixture check is proving the declared
    /// dependencies resolve. A checker that dropped the header would resolve
    /// nothing and pass every candidate, including one that names a package
    /// that does not exist.
    func testCheckerScriptKeepsTheCandidatesDependencyHeader() {
        // Given
        let source = """
        # /// script
        # requires-python = ">=3.12"
        # dependencies = ["httpx==0.28.1"]
        # ///
        import httpx

        httpx.post("https://example.com")
        """

        // When
        let checker = CandidateValidation.checkerScript(for: source)

        // Then
        XCTAssertTrue(checker.hasPrefix("# /// script\n"))
        XCTAssertTrue(checker.contains(#"# dependencies = ["httpx==0.28.1"]"#))
        XCTAssertTrue(checker.contains("compile(sys.argv[1]"))
        // The candidate's own statements must never run: performing the side
        // effect is exactly what this path exists to avoid.
        XCTAssertFalse(checker.contains("httpx.post"))
    }

    func testCheckerScriptHandlesSourcesWithoutAHeader() {
        // Given
        let source = "import sys\n\nprint(sys.argv[1].upper())"

        // When
        let checker = CandidateValidation.checkerScript(for: source)

        // Then
        XCTAssertFalse(checker.contains("# /// script"))
        XCTAssertTrue(checker.contains("compile(sys.argv[1]"))
    }

    func testHeaderExtractionIgnoresACommentThatOnlyLooksLikeATerminator() {
        // Given
        let source = """
        # /// script
        # dependencies = []
        # ///
        # /// not a header
        print("ok")
        """

        // When
        let header = CandidateValidation.pep723Header(of: source)

        // Then
        XCTAssertEqual(header, "# /// script\n# dependencies = []\n# ///\n")
    }
}
