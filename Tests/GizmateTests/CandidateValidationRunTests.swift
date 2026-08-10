import Foundation
import GizmateToolAgentCore
import XCTest
@testable import Gizmate

/// Drives the real `uv` the way a build does. Skipped when uv is not installed
/// yet, in the same spirit as the packaged Pi gate test.
///
/// These are the tests that would have been impossible to write before: every
/// one of them describes a tool the old sandboxed validator had no way to
/// execute, and therefore a tool the agent was instructed never to write.
final class CandidateValidationRunTests: XCTestCase {
    private func uv() throws -> URL {
        let candidates = [
            URL(fileURLWithPath: NSHomeDirectory())
                .appending(path: "Library/Application Support/Gizmate/bin/uv"),
            URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".local/bin/uv"),
            URL(fileURLWithPath: "/opt/homebrew/bin/uv"),
            URL(fileURLWithPath: "/usr/local/bin/uv"),
        ]
        guard let found = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw XCTSkip("uv is not installed")
        }
        return found
    }

    private func input(
        _ candidate: ToolAgentCandidateV1
    ) throws -> ToolBuildValidationInputV1 {
        let fingerprint = try ToolAgentCandidateFingerprintV1.make(
            candidate: candidate,
            runtimeVersion: "test",
            policyVersion: "test"
        )
        return ToolBuildValidationInputV1(
            request: ToolBuildRequestV1(description: "test", budgets: .preview),
            candidateID: UUID(),
            fingerprint: fingerprint,
            candidate: candidate
        )
    }

    private func candidate(
        source: String,
        fixtures: [ToolAgentFixtureV1],
        output: ToolAgentCandidateOutputV1 = .clipboard,
        outputDirectory: String? = nil,
        declaresNetwork: Bool = false,
        input: ToolAgentCandidateInputV1 = .selection,
        trigger: ToolAgentCandidateTriggerV1 = .always,
        layout: ToolAgentLayoutV1? = nil
    ) throws -> ToolAgentCandidateV1 {
        try ToolAgentCandidateV1(
            kind: .python,
            name: "Test Tool",
            brief: "Exercises the real validation path.",
            symbolName: "curlybraces",
            input: input,
            output: output,
            trigger: trigger,
            source: source,
            fixtures: fixtures,
            outputDirectory: outputDirectory,
            timeoutSeconds: 60,
            declaresNetwork: declaresNetwork,
            layout: layout
        )
    }

    func testExactFixtureEarnsVerified() async throws {
        // Given
        let candidate = try candidate(
            source: "import sys\n\nprint(sys.argv[1].upper())",
            fixtures: [.init(input: "hello", expectedOutput: "HELLO")]
        )

        // When
        let report = try await CandidateValidation.validate(
            try input(candidate),
            uv: try uv()
        )

        // Then
        XCTAssertEqual(report.outcome, .passed)
        XCTAssertEqual(report.assurance, .verified)
    }

    func testMismatchedOutputFailsWithBothSidesOfTheComparison() async throws {
        // Given
        let candidate = try candidate(
            source: "print('nope')",
            fixtures: [.init(input: "hello", expectedOutput: "HELLO")]
        )

        // When
        let report = try await CandidateValidation.validate(
            try input(candidate),
            uv: try uv()
        )

        // Then
        XCTAssertEqual(report.outcome, .failed)
        XCTAssertEqual(report.failure, .wrongOutput)
        XCTAssertEqual(report.expectedOutput, "HELLO")
        XCTAssertEqual(report.actualOutput?.trimmingCharacters(in: .whitespacesAndNewlines), "nope")
    }

    /// A tool whose output depends on the clock. Unrepresentable before: it can
    /// never match a fixed string, so it could never pass.
    func testUnpredictableOutputEarnsSmoke() async throws {
        // Given
        let candidate = try candidate(
            source: """
            import sys
            import datetime

            print(f"{sys.argv[1]} at {datetime.datetime.now().isoformat()}")
            """,
            fixtures: [.init(input: "note")]
        )

        // When
        let report = try await CandidateValidation.validate(
            try input(candidate),
            uv: try uv()
        )

        // Then
        XCTAssertEqual(report.outcome, .passed)
        XCTAssertEqual(report.assurance, .smoke)
    }

    /// A tool that promises files has to produce one, even on the smoke path.
    func testFileOutputMustActuallyProduceAFile() async throws {
        // Given
        let liar = try candidate(
            source: "print('saved')",
            fixtures: [.init(input: "note")],
            output: .files,
            outputDirectory: "~/Downloads"
        )
        let honest = try candidate(
            source: """
            import sys
            from pathlib import Path

            Path("note.txt").write_text(sys.argv[1])
            print("saved")
            """,
            fixtures: [.init(input: "note")],
            output: .files,
            outputDirectory: "~/Downloads"
        )

        // When
        let liarReport = try await CandidateValidation.validate(
            try input(liar),
            uv: try uv()
        )
        let honestReport = try await CandidateValidation.validate(
            try input(honest),
            uv: try uv()
        )

        // Then
        XCTAssertEqual(liarReport.outcome, .failed)
        XCTAssertEqual(liarReport.failure, .invalidOutput)
        XCTAssertEqual(honestReport.outcome, .passed)
        XCTAssertEqual(honestReport.assurance, .smoke)
        // Validation must never deliver into the user's real Downloads folder.
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: (NSHomeDirectory() as NSString)
                    .appendingPathComponent("Downloads/note.txt")
            )
        )
    }

    /// Proves the wiring in `CandidateValidation.run`, not just the pure
    /// `SurfaceLayoutCheck` function it calls: a script that really executes
    /// and really prints rows missing a key the layout binds has to fail with
    /// a diagnostic naming that key. This is the assertion an accidental swap
    /// of `result.stdout` for a fixture value (or any other stand-in) would
    /// break — the pure-function unit tests never enter this path, so nothing
    /// today would notice.
    func testSurfaceOutputMissingABoundKeyFailsWithTheKeyNamed() async throws {
        // Given
        // "filename", not "name": the generic not-JSON diagnostic below
        // already contains the example key "name" in its own boilerplate
        // ({"id":"…","name":"…"}), so asserting on "name" would pass even if
        // that wrong branch fired instead of `SurfaceLayoutCheck`'s real one
        // — exactly the false-positive this test exists to rule out.
        let candidate = try candidate(
            source: #"print('{"rows":[{"id":"1","other":"x"}]}')"#,
            fixtures: [.init(input: "")],
            output: .surface,
            input: .none,
            trigger: .always,
            layout: .list(
                row: .card(.init(title: .key("filename"))),
                empty: "Nothing here"
            )
        )

        // When
        let report = try await CandidateValidation.validate(
            try input(candidate),
            uv: try uv()
        )

        // Then
        XCTAssertEqual(report.outcome, .failed)
        XCTAssertEqual(report.failure, .invalidOutput)
        XCTAssertTrue(
            report.stderrDetail?.contains("filename") ?? false,
            report.stderrDetail ?? "<no detail>"
        )
    }

    /// The side-effect case: nothing runs, but a header naming a package that
    /// does not exist still has to fail the build rather than reach the user.
    func testNoFixturesResolvesDependenciesWithoutRunningTheScript() async throws {
        // Given
        let marker = FileManager.default.temporaryDirectory
            .appending(path: "gizmate-must-not-run-\(UUID().uuidString)")
        let resolvable = try candidate(
            source: """
            # /// script
            # dependencies = []
            # ///
            from pathlib import Path

            Path("\(marker.path)").write_text("side effect happened")
            """,
            fixtures: []
        )
        let unresolvable = try candidate(
            source: """
            # /// script
            # dependencies = ["gizmate-package-that-does-not-exist==1.0.0"]
            # ///
            print("ok")
            """,
            fixtures: []
        )

        // When
        let resolvableReport = try await CandidateValidation.validate(
            try input(resolvable),
            uv: try uv()
        )
        let unresolvableReport = try await CandidateValidation.validate(
            try input(unresolvable),
            uv: try uv()
        )

        // Then
        XCTAssertEqual(resolvableReport.outcome, .passed)
        XCTAssertEqual(resolvableReport.assurance, .unverified)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(unresolvableReport.outcome, .failed)
    }

    /// The motivating case for the whole change: an arbitrary third-party
    /// dependency, resolved and imported for real. Needs the network.
    func testThirdPartyDependencyResolvesAndRuns() async throws {
        // Given
        let candidate = try candidate(
            source: """
            # /// script
            # dependencies = ["idna==3.10"]
            # ///
            import sys
            import idna

            print(idna.encode(sys.argv[1]).decode())
            """,
            fixtures: [.init(input: "пример.рф", expectedOutput: "xn--e1afmkfd.xn--p1ai")],
            declaresNetwork: true
        )

        // When
        let report = try await CandidateValidation.validate(
            try input(candidate),
            uv: try uv()
        )

        // Then
        XCTAssertEqual(report.failure, nil, report.stderrDetail ?? "")
        XCTAssertEqual(report.outcome, .passed)
        XCTAssertEqual(report.assurance, .verified)
    }
}
