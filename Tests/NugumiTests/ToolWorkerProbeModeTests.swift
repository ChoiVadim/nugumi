import Foundation
import NugumiToolIPC
import XCTest
@testable import Nugumi

final class ToolWorkerProbeModeTests: XCTestCase {
    func testParseReturnsNilWithoutProbeArguments() {
        XCTAssertNil(ToolWorkerProbeMode.parse(arguments: ["Nugumi"]))
    }

    func testParseReturnsReportPathForCompleteProbeArguments() {
        let mode = ToolWorkerProbeMode.parse(
            arguments: [
                "Nugumi",
                "--tool-worker-probe",
                "--report",
                "/tmp/report.json",
            ]
        )

        XCTAssertEqual(mode?.reportPath, "/tmp/report.json")
    }

    func testParseRejectsMissingOrExtraProbeArguments() {
        XCTAssertNil(
            ToolWorkerProbeMode.parse(
                arguments: ["Nugumi", "--tool-worker-probe", "--report"]
            )
        )
        XCTAssertNil(
            ToolWorkerProbeMode.parse(
                arguments: [
                    "Nugumi",
                    "--tool-worker-probe",
                    "--report",
                    "/tmp/report.json",
                    "--unexpected",
                ]
            )
        )
    }

    func testFixturePolicyAcceptsOnlyExactProbeURL() {
        let cases: [(String, Bool)] = [
            ("https://example.com/", true),
            ("https://example.com:443/", true),
            ("http://example.com/", false),
            ("https://example.com.evil.test/", false),
            ("https://example.com:444/", false),
            ("https://user@example.com/", false),
            ("https://example.com/path", false),
            ("https://example.com/?query=1", false),
            ("https://example.com/#fragment", false),
        ]

        for (rawURL, expected) in cases {
            let url = try! XCTUnwrap(URL(string: rawURL))
            XCTAssertEqual(
                ProbeFixturePolicy.accepts(url),
                expected,
                rawURL
            )
        }
    }

    func testFixturePolicyRejectsRedirects() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/"))

        XCTAssertFalse(ProbeFixturePolicy.allowsRedirect(to: url))
    }

    func testFixturePolicyReturnsOnlyBoundedStatus200Body() {
        let body = Data("fixture".utf8)
        XCTAssertEqual(
            ProbeFixturePolicy.response(statusCode: 200, body: body),
            ProbeFixtureResponse(accepted: true, statusCode: 200, body: body)
        )
        XCTAssertEqual(
            ProbeFixturePolicy.response(statusCode: 204, body: body),
            ProbeFixtureResponse(accepted: false, statusCode: 204, body: Data())
        )
        XCTAssertEqual(
            ProbeFixturePolicy.response(
                statusCode: 200,
                body: Data(repeating: 0, count: 65_537)
            ),
            ProbeFixtureResponse(accepted: false, statusCode: 200, body: Data())
        )
    }

    func testFixtureSessionConfigurationDisablesAmbientState() {
        let configuration = ProbeFixturePolicy.sessionConfiguration()

        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(
            configuration.requestCachePolicy,
            .reloadIgnoringLocalAndRemoteCacheData
        )
    }

    func testRunAndWriteReportWritesSortedPassingReport() async throws {
        let reportURL = temporaryReportURL()
        defer { try? FileManager.default.removeItem(at: reportURL) }
        let result = passingResult()

        let status = await ToolWorkerClient.runAndWriteReport(
            to: reportURL,
            runProbe: { result }
        )

        XCTAssertEqual(status, 0)
        let data = try Data(contentsOf: reportURL)
        XCTAssertEqual(
            try JSONDecoder().decode(SandboxProbeGateReport.self, from: data),
            SandboxProbeGateReport(result: result)
        )
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.hasPrefix("{\"gatePassed\":true,\"result\":{"))
        XCTAssertLessThan(
            try XCTUnwrap(json.range(of: "\"dependencyVersion\"")?.lowerBound),
            try XCTUnwrap(json.range(of: "\"hostReadDenied\"")?.lowerBound)
        )
    }

    func testRunAndWriteReportWritesTypedFailureAndReturnsOne() async throws {
        let reportURL = temporaryReportURL()
        defer { try? FileManager.default.removeItem(at: reportURL) }

        let status = await ToolWorkerClient.runAndWriteReport(
            to: reportURL,
            runProbe: { throw ToolWorkerClientError.invalidReply }
        )

        XCTAssertEqual(status, 1)
        let data = try Data(contentsOf: reportURL)
        XCTAssertEqual(
            try JSONDecoder().decode(SandboxProbeReply.self, from: data),
            .failure(
                SandboxProbeFailure(
                    runID: nil,
                    code: .invalidProbeOutput
                )
            )
        )
    }

    func testRunAndWriteReportReturnsOneWhenGateFails() async throws {
        let reportURL = temporaryReportURL()
        defer { try? FileManager.default.removeItem(at: reportURL) }
        let failed = result(rawNetworkDenied: false)

        let status = await ToolWorkerClient.runAndWriteReport(
            to: reportURL,
            runProbe: { failed }
        )

        XCTAssertEqual(status, 1)
        XCTAssertEqual(
            try JSONDecoder().decode(
                SandboxProbeGateReport.self,
                from: Data(contentsOf: reportURL)
            ),
            SandboxProbeGateReport(result: failed)
        )
    }

    func testWithSentinelsCreatesHostFixturesAndRemovesRunDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nugumi-gate-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var runDirectory: URL?

        let result = try await ToolWorkerClient.withSentinels(at: root) {
            request in
            let readURL = URL(fileURLWithPath: request.deniedReadPath)
            let writeURL = URL(fileURLWithPath: request.deniedWritePath)
            runDirectory = readURL.deletingLastPathComponent()
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: readURL.path)
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: writeURL.path)
            )
            XCTAssertEqual(
                runDirectory?.deletingLastPathComponent().lastPathComponent,
                "ToolWorkerGate"
            )
            return passingResult(runID: request.runID)
        }

        XCTAssertTrue(result.gatePassed)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: try XCTUnwrap(runDirectory).path
            )
        )
    }

    private func temporaryReportURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nugumi-probe-\(UUID().uuidString).json")
    }

    private func passingResult(runID: UUID? = nil) -> SandboxProbeResult {
        result(rawNetworkDenied: true, runID: runID)
    }

    private func result(
        rawNetworkDenied: Bool,
        runID: UUID? = nil
    ) -> SandboxProbeResult {
        SandboxProbeResult(
            runID: runID
                ?? UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            pythonVersion: "3.12.11",
            dependencyVersion: "3.10",
            workspaceWriteSucceeded: true,
            hostReadDenied: true,
            hostWriteDenied: true,
            rawNetworkDenied: rawNetworkDenied,
            mediatedNetworkSucceeded: true,
            stdoutBounded: true,
            stderrBounded: true,
            timedOutProcessGroupTerminated: true
        )
    }
}
