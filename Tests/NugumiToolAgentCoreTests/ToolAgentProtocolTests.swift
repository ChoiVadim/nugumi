import Foundation
import XCTest
@testable import NugumiToolAgentCore

final class ToolAgentProtocolTests: XCTestCase {
    func testMessageRoundTripsEveryV1Type() throws {
        // Given
        let candidate = try makeCandidate()
        let writeResponse = try ToolAgentWriteCandidateResponseV1(
            candidateID: UUID(),
            fingerprint: ToolAgentFingerprintV1("a".repeated(count: 64))
        )
        let runID = UUID()
        let messages: [ToolAgentMessageV1] = [
            .start(runID: runID, .init(description: "uppercase copied text", budgets: .preview)),
            .modelResponse(runID: runID, .init(requestID: UUID(), result: .text("{}"))),
            .toolResponse(runID: runID, .init(callID: UUID(), result: .writeCandidate(writeResponse))),
            .cancel(runID: runID, .init(reason: .userRequested)),
            .state(runID: runID, .init(state: .writing)),
            .modelRequest(runID: runID, .init(requestID: UUID(), system: "system", user: "user")),
            .toolRequest(runID: runID, .init(callID: UUID(), request: .writeCandidate(.init(candidate: candidate)))),
            .completed(runID: runID, .init(candidateID: writeResponse.candidateID, fingerprint: writeResponse.fingerprint)),
            .failed(runID: runID, .init(code: .invalidModelAction, message: "invalid model action"))
        ]

        // When
        let decoded = try messages.map { try ToolAgentJSONLCodecV1.decode(ToolAgentJSONLCodecV1.encode($0)) }

        // Then
        XCTAssertEqual(decoded, messages)
        XCTAssertTrue(decoded.allSatisfy { $0.version == 1 })
        XCTAssertTrue(decoded.allSatisfy { $0.runID == runID })
    }

    func testDecodeRejectsUnknownVersionAndFrameLargerThanOneMiB() throws {
        // Given
        let unknownVersion = Data(#"{"version":2,"type":"cancel","runID":"00000000-0000-0000-0000-000000000000","payload":{"reason":"userRequested"}}"#.utf8)
        let oversizedLine = Data(repeating: 0x20, count: ToolAgentProtocolLimitsV1.maximumFrameBytes + 1)

        XCTAssertThrowsError(try ToolAgentJSONLCodecV1.decode(unknownVersion)) { error in
            XCTAssertEqual(String(describing: error), String(describing: ToolAgentProtocolErrorV1.unsupportedVersion))
        }
        XCTAssertThrowsError(try ToolAgentJSONLCodecV1.decode(oversizedLine)) { error in
            XCTAssertEqual(String(describing: error), String(describing: ToolAgentProtocolErrorV1.frameTooLarge))
        }
    }

    func testCandidateRejectsFieldsBeyondTheirUTF8ByteLimits() throws {
        // Given
        let sourceTooLarge = "s".repeated(count: ToolAgentProtocolLimitsV1.maximumSourceBytes + 1)
        let inputTooLarge = "i".repeated(count: ToolAgentProtocolLimitsV1.maximumFixtureInputBytes + 1)
        let outputTooLarge = "o".repeated(count: ToolAgentProtocolLimitsV1.maximumFixtureOutputBytes + 1)

        XCTAssertThrowsError(try makeCandidate(source: sourceTooLarge))
        XCTAssertThrowsError(try makeCandidate(fixtures: [.init(input: inputTooLarge, expectedOutput: "OK")]))
        XCTAssertThrowsError(try makeCandidate(fixtures: [.init(input: "input", expectedOutput: outputTooLarge)]))
        XCTAssertThrowsError(try makeCandidate(fixtures: []))
        XCTAssertThrowsError(try makeCandidate(fixtures: Array(repeating: .init(input: "input", expectedOutput: "OK"), count: ToolAgentProtocolLimitsV1.maximumFixtureCount + 1)))
    }

    func testCandidateUsesUTF8BytesRatherThanCharacterCount() throws {
        // Given
        let unicodeInput = "😀".repeated(count: (ToolAgentProtocolLimitsV1.maximumFixtureInputBytes / 4) + 1)

        XCTAssertThrowsError(try makeCandidate(fixtures: [.init(input: unicodeInput, expectedOutput: "OK")]))
    }

    func testWorstCaseEscapedCandidateFitsInsideFrameLimit() throws {
        // Given
        let escaped = "\0"
        let candidate = try makeCandidate(
            name: escaped.repeated(count: ToolAgentProtocolLimitsV1.maximumNameBytes),
            brief: escaped.repeated(count: ToolAgentProtocolLimitsV1.maximumBriefBytes),
            symbolName: escaped.repeated(count: ToolAgentProtocolLimitsV1.maximumSymbolNameBytes),
            source: escaped.repeated(count: ToolAgentProtocolLimitsV1.maximumSourceBytes),
            fixtures: Array(repeating: .init(
                input: escaped.repeated(count: ToolAgentProtocolLimitsV1.maximumFixtureInputBytes),
                expectedOutput: escaped.repeated(count: ToolAgentProtocolLimitsV1.maximumFixtureOutputBytes)
            ), count: ToolAgentProtocolLimitsV1.maximumFixtureCount)
        )
        let message = ToolAgentMessageV1.toolRequest(runID: UUID(), .init(callID: UUID(), request: .writeCandidate(.init(candidate: candidate))))

        // When
        let line = try ToolAgentJSONLCodecV1.encode(message)

        // Then
        XCTAssertLessThanOrEqual(line.count, ToolAgentProtocolLimitsV1.maximumFrameBytes)
    }

    func testModelActionParsesOnlyOneClosedToolCallOrFinalText() throws {
        // Given
        let toolCall = #"{"version":1,"action":"toolCall","name":"write_candidate","arguments":{}}"#
        let finalText = #"{"version":1,"action":"finalText","text":"offline tools only"}"#

        // When
        let parsedToolCall = try ModelActionV1.parse(toolCall)
        let parsedFinalText = try ModelActionV1.parse(finalText)

        // Then
        XCTAssertEqual(parsedToolCall, .toolCall(name: .writeCandidate, arguments: .object([:])))
        XCTAssertEqual(parsedFinalText, .finalText("offline tools only"))
    }

    func testModelActionRejectsFencesExtraFieldsAndMalformedPayloads() {
        // Given
        let invalidActions = [
            "```json\n{\"version\":1,\"action\":\"finalText\",\"text\":\"no\"}\n```",
            #"{"version":1,"action":"finalText","text":"no","extra":true}"#,
            #"{"version":1,"action":"toolCall","name":"shell","arguments":{}}"#,
            #"{"version":1,"action":"toolCall","name":"write_candidate"}"#,
            #"{"version":1,"action":"finalText","text":"no"} trailing"#,
            #"{"version":1,"version":1,"action":"finalText","text":"no"}"#,
            #"{"version":1,"action":"toolCall","action":"finalText","text":"no"}"#,
            #"{"version":1,"action":"toolCall","name":"write_candidate","arguments":{"input":"first","input":"second"}}"#
        ]

        for action in invalidActions {
            XCTAssertThrowsError(try ModelActionV1.parse(action))
        }
    }

    func testJSONLRejectsDuplicateNestedPayloadKeyBeforeDecoding() {
        // Given
        let duplicatePayloadKey = Data(#"{"version":1,"type":"cancel","runID":"00000000-0000-0000-0000-000000000000","payload":{"reason":"userRequested","reason":"deadlineExceeded"}}"#.utf8)

        XCTAssertThrowsError(try ToolAgentJSONLCodecV1.decode(duplicatePayloadKey)) { error in
            XCTAssertEqual(String(describing: error), String(describing: ToolAgentProtocolErrorV1.malformedMessage))
        }
    }

    func testFingerprintChangesWhenAnyBoundInputChanges() throws {
        // Given
        let candidate = try makeCandidate()
        let baseline = try ToolAgentCandidateFingerprintV1.make(
            candidate: candidate,
            runtimeVersion: "3.12.11",
            policyVersion: "validation-v1"
        )

        // When
        let sourceChanged = try ToolAgentCandidateFingerprintV1.make(candidate: try makeCandidate(source: "print('changed')"), runtimeVersion: "3.12.11", policyVersion: "validation-v1")
        let fixtureChanged = try ToolAgentCandidateFingerprintV1.make(candidate: try makeCandidate(fixtures: [.init(input: "hello", expectedOutput: "HELLO!")]), runtimeVersion: "3.12.11", policyVersion: "validation-v1")
        let manifestChanged = try ToolAgentCandidateFingerprintV1.make(candidate: try makeCandidate(name: "Changed"), runtimeVersion: "3.12.11", policyVersion: "validation-v1")
        let runtimeChanged = try ToolAgentCandidateFingerprintV1.make(candidate: candidate, runtimeVersion: "3.12.12", policyVersion: "validation-v1")
        let policyChanged = try ToolAgentCandidateFingerprintV1.make(candidate: candidate, runtimeVersion: "3.12.11", policyVersion: "validation-v2")

        // Then
        XCTAssertNotEqual(baseline, sourceChanged)
        XCTAssertNotEqual(baseline, fixtureChanged)
        XCTAssertNotEqual(baseline, manifestChanged)
        XCTAssertNotEqual(baseline, runtimeChanged)
        XCTAssertNotEqual(baseline, policyChanged)
    }

    func testCandidateIDIsHostAssignedAndAttestationBindsItToFingerprint() throws {
        // Given
        let candidate = try makeCandidate()
        let candidateID = UUID()
        let fingerprint = try ToolAgentCandidateFingerprintV1.make(candidate: candidate, runtimeVersion: "3.12.11", policyVersion: "validation-v1")

        // When
        let write = try ToolAgentWriteCandidateResponseV1(candidateID: candidateID, fingerprint: fingerprint)
        let validation = try ToolAgentValidationReportV1(candidateID: candidateID, fingerprint: fingerprint, outcome: .passed)
        let finish = try ToolAgentFinishCandidateRequestV1(candidateID: candidateID, fingerprint: fingerprint)

        // Then
        XCTAssertEqual(write.candidateID, validation.candidateID)
        XCTAssertEqual(validation.fingerprint, finish.fingerprint)
        XCTAssertEqual(try ToolAgentAttestationV1(write: write, validation: validation, finish: finish).fingerprint, fingerprint)
    }

    func testAttestationRejectsStaleCandidateOrFingerprint() throws {
        // Given
        let candidate = try makeCandidate()
        let fingerprint = try ToolAgentCandidateFingerprintV1.make(candidate: candidate, runtimeVersion: "3.12.11", policyVersion: "validation-v1")
        let write = try ToolAgentWriteCandidateResponseV1(candidateID: UUID(), fingerprint: fingerprint)
        let staleValidation = try ToolAgentValidationReportV1(candidateID: UUID(), fingerprint: fingerprint, outcome: .passed)
        let mismatchedFinish = try ToolAgentFinishCandidateRequestV1(candidateID: write.candidateID, fingerprint: ToolAgentFingerprintV1("b".repeated(count: 64)))

        XCTAssertThrowsError(try ToolAgentAttestationV1(write: write, validation: staleValidation, finish: .init(candidateID: write.candidateID, fingerprint: fingerprint)))
        XCTAssertThrowsError(try ToolAgentAttestationV1(write: write, validation: .init(candidateID: write.candidateID, fingerprint: fingerprint, outcome: .passed), finish: mismatchedFinish))
    }

    func testSafeEventMetadataCannotEncodeSensitiveCandidateOrHostData() throws {
        // Given
        let source = "print('/Users/person/private.txt')"
        let fixtureInput = "fixture-secret"
        let stdout = "stdout-secret"
        let stderr = "stderr-secret"
        let event = ToolAgentSafeEventMetadataV1(
            runID: UUID(),
            state: .testing,
            counters: .init(modelTurns: 1, toolCalls: 2, repairs: 0),
            durationMilliseconds: 42,
            failure: .wrongOutput
        )

        // When
        let payload = try XCTUnwrap(String(data: try ToolAgentCanonicalJSONV1.encode(event), encoding: .utf8))

        // Then
        XCTAssertFalse(payload.contains(source))
        XCTAssertFalse(payload.contains(fixtureInput))
        XCTAssertFalse(payload.contains(stdout))
        XCTAssertFalse(payload.contains(stderr))
        XCTAssertFalse(payload.contains("/Users/person/private.txt"))
    }

    private func makeCandidate(
        name: String = "Uppercase",
        brief: String = "Uppercases clipboard text.",
        symbolName: String = "textformat",
        source: String = "import sys\nprint(sys.argv[1].upper())",
        fixtures: [ToolAgentFixtureV1] = [.init(input: "hello", expectedOutput: "HELLO")]
    ) throws -> ToolAgentCandidateV1 {
        try ToolAgentCandidateV1(
            name: name,
            brief: brief,
            symbolName: symbolName,
            source: source,
            fixtures: fixtures
        )
    }
}

private extension String {
    func repeated(count: Int) -> String {
        String(repeating: self, count: count)
    }
}
