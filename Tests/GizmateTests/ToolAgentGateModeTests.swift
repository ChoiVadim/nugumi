import Foundation
import GizmateToolAgentCore
import XCTest
@testable import Gizmate

final class ToolAgentGateModeTests: XCTestCase {
    func testParseReturnsModeOnlyForExactGateArguments() {
        XCTAssertEqual(
            ToolAgentGateMode.parse(arguments: [
                "Gizmate",
                "--pi-tool-agent-gate",
                "--report",
                "/tmp/report.json",
            ]),
            ToolAgentGateMode(reportPath: "/tmp/report.json")
        )

        let invalidArguments = [
            ["Gizmate"],
            ["Gizmate", "--pi-tool-agent-gate"],
            ["Gizmate", "--pi-tool-agent-gate", "--report"],
            ["Gizmate", "--pi-tool-agent-gate", "--report", ""],
            ["Gizmate", "--report", "/tmp/report.json"],
            [
                "Gizmate",
                "--pi-tool-agent-gate",
                "--report",
                "/tmp/report.json",
                "--unexpected",
            ],
        ]
        for arguments in invalidArguments {
            XCTAssertNil(ToolAgentGateMode.parse(arguments: arguments))
        }
    }

    func testProjectionIsExactSortedAndContainsNoPrivateBuildData() async throws {
        let fixture = try await passingRecord()
        let report = try ToolAgentGateReportV1(
            record: fixture.record,
            result: fixture.result,
            modelRequestCount: 0
        )
        XCTAssertEqual(
            report.firstAttempt.fingerprint,
            "316702b255b6ccb785cfc177b7ff7f112b3d712b73e57fc9fb65eaa5066a9955"
        )
        XCTAssertEqual(
            report.secondAttempt.fingerprint,
            "0657b1b788a15a0ddca96bdfb9bcb907e675e1ed560fad92501fa7cfd70950a2"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), [
            "schemaVersion",
            "gatePassed",
            "runID",
            "entrypoint",
            "modelRequestCount",
            "attemptCount",
            "firstAttempt",
            "secondAttempt",
            "finalState",
            "finalCandidateID",
            "finalFingerprint",
            "counters",
        ])
        XCTAssertEqual(
            Set(try XCTUnwrap(object["firstAttempt"] as? [String: Any]).keys),
            ["candidateID", "fingerprint", "outcome", "failure"]
        )
        XCTAssertEqual(
            Set(try XCTUnwrap(object["secondAttempt"] as? [String: Any]).keys),
            ["candidateID", "fingerprint", "outcome", "passingFingerprint"]
        )
        XCTAssertEqual(
            Set(try XCTUnwrap(object["counters"] as? [String: Any]).keys),
            ["modelTurns", "toolCalls", "repairs"]
        )
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.hasPrefix("{\"attemptCount\":2,\"counters\":{"))
        for forbidden in [
            "\"source\"",
            "\"fixtures\"",
            "\"expectedOutput\"",
            "\"actualOutput\"",
            "\"stdout",
            "\"stderr",
            "\"system\"",
            "\"user\"",
            "API_TOKEN",
            "/private/",
            "print(sys.argv",
            "hello",
            "HELLO",
        ] {
            XCTAssertFalse(json.contains(forbidden), forbidden)
        }
    }

    func testProjectionRejectsAnyModelRequest() async throws {
        let fixture = try await passingRecord()

        XCTAssertThrowsError(
            try ToolAgentGateReportV1(
                record: fixture.record,
                result: fixture.result,
                modelRequestCount: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? ToolAgentGateFailureCodeV1,
                .invalidResult
            )
        }
    }

    func testReportWriterWritesSortedSafeFailureWithoutErrorDescription() async throws {
        struct SensitiveError: LocalizedError {
            var errorDescription: String? {
                "secret API_TOKEN at /private/tmp/user-path"
            }
        }
        let reportURL = temporaryReportURL()
        defer { try? FileManager.default.removeItem(at: reportURL) }

        let status = await ToolAgentGateRunner.runAndWriteReport(to: reportURL) {
            throw SensitiveError()
        }

        XCTAssertEqual(status, 1)
        let data = try Data(contentsOf: reportURL)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(
            json,
            #"{"failure":"workerFailure","gatePassed":false,"schemaVersion":1}"#
        )
    }

    func testReportWriterWritesPassingProjectionAndReturnsZero() async throws {
        let fixture = try await passingRecord()
        let report = try ToolAgentGateReportV1(
            record: fixture.record,
            result: fixture.result,
            modelRequestCount: 0
        )
        let reportURL = temporaryReportURL()
        defer { try? FileManager.default.removeItem(at: reportURL) }

        let status = await ToolAgentGateRunner.runAndWriteReport(to: reportURL) {
            report
        }

        XCTAssertEqual(status, 0)
        XCTAssertEqual(
            try JSONDecoder().decode(
                ToolAgentGateReportV1.self,
                from: Data(contentsOf: reportURL)
            ),
            report
        )
    }

    private func passingRecord() async throws -> (
        record: ToolBuildRecordV1,
        result: ToolBuildResultV1
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ToolBuildStore(directoryURL: directory)
        let request = ToolBuildRequestV1(
            runID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            description: ToolAgentGateRunner.requestDescription
        )
        let bad = try candidate(source: "import sys\nprint(sys.argv[1])\n")
        let repaired = try candidate(
            source: "import sys\nprint(sys.argv[1].upper())\n"
        )
        let badID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000011"
        )!
        let repairedID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000012"
        )!
        let badFingerprint = try ToolAgentCandidateFingerprintV1.make(
            candidate: bad,
            runtimeVersion: ToolAgentGateRunner.runtimeVersion,
            policyVersion: ToolAgentGateRunner.policyVersion
        )
        let repairedFingerprint = try ToolAgentCandidateFingerprintV1.make(
            candidate: repaired,
            runtimeVersion: ToolAgentGateRunner.runtimeVersion,
            policyVersion: ToolAgentGateRunner.policyVersion
        )
        try await store.create(request)
        try await store.appendAttempt(
            runID: request.runID,
            candidateID: badID,
            fingerprint: badFingerprint,
            candidate: bad
        )
        try await store.appendValidation(
            runID: request.runID,
            report: try ToolAgentValidationReportV1(
                candidateID: badID,
                fingerprint: badFingerprint,
                outcome: .failed,
                failure: .wrongOutput,
                fixtureIndex: 0,
                expectedOutput: "HELLO",
                actualOutput: "hello",
                exitCode: 0
            )
        )
        try await store.appendAttempt(
            runID: request.runID,
            candidateID: repairedID,
            fingerprint: repairedFingerprint,
            candidate: repaired
        )
        try await store.appendValidation(
            runID: request.runID,
            report: try ToolAgentValidationReportV1(
                candidateID: repairedID,
                fingerprint: repairedFingerprint,
                outcome: .passed,
                exitCode: 0,
                passingFingerprint: repairedFingerprint
            )
        )
        try await store.charge(
            runID: request.runID,
            toolCalls: 6,
            repairs: 1
        )
        let result = ToolBuildResultV1(
            candidateID: repairedID,
            fingerprint: repairedFingerprint
        )
        try await store.complete(runID: request.runID, result: result)
        return (try await store.record(runID: request.runID), result)
    }

    private func candidate(source: String) throws -> ToolAgentCandidateV1 {
        try ToolAgentCandidateV1(
            name: "Uppercase",
            brief: "Uppercases selected text",
            symbolName: "textformat",
            source: source,
            fixtures: [.init(input: "hello", expectedOutput: "HELLO")]
        )
    }

    private func temporaryReportURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "gizmate-pi-tool-agent-\(UUID().uuidString).json"
            )
    }
}
