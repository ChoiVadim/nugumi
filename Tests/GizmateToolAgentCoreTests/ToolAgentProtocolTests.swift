import Foundation
import XCTest
@testable import GizmateToolAgentCore

final class ToolAgentProtocolTests: XCTestCase {
    func testEditRequestRoundTripsInstalledPythonSourceAt64KiB() throws {
        // Given
        let source = "x".repeated(count: ToolAgentProtocolLimitsV1.maximumSourceBytes)
        let installedTool = try ToolAgentInstalledToolV1(
            kind: .python,
            name: "Uppercase",
            brief: "Uppercases copied text.",
            symbolName: "textformat",
            input: .selection,
            output: .clipboard,
            trigger: .always,
            source: source,
            timeoutSeconds: 30
        )
        let request = try ToolBuildRequestV1(
            description: "Make output title case.",
            budgets: .preview,
            operation: .edit,
            currentTool: installedTool
        )
        let start = try ToolAgentStartV1(
            description: request.description,
            budgets: request.budgets,
            operation: request.operation,
            currentTool: request.currentTool,
            failure: request.failure
        )
        let message = ToolAgentMessageV1.start(runID: request.runID, start)

        // When
        let decodedRequest = try JSONDecoder().decode(
            ToolBuildRequestV1.self,
            from: ToolAgentCanonicalJSONV1.encode(request)
        )
        let decodedMessage = try ToolAgentJSONLCodecV1.decode(
            ToolAgentJSONLCodecV1.encode(message)
        )

        // Then
        XCTAssertEqual(decodedRequest, request)
        XCTAssertEqual(decodedMessage, message)
        guard case .start(let decodedStart) = decodedMessage.payload else {
            return XCTFail("Expected start payload")
        }
        XCTAssertEqual(decodedStart.operation, .edit)
        XCTAssertEqual(decodedStart.currentTool?.source.utf8.count, source.utf8.count)
        XCTAssertNil(decodedStart.failure)
    }

    func testOperationContractRejectsInvalidCreateEditAndFixCombinations() throws {
        // Given
        let installedTool = try ToolAgentInstalledToolV1(
            kind: .python,
            name: "Uppercase",
            brief: "Uppercases copied text.",
            symbolName: "textformat",
            input: .selection,
            output: .clipboard,
            trigger: .always,
            source: "print(input())",
            timeoutSeconds: 30
        )

        // Then
        XCTAssertThrowsError(try ToolAgentStartV1(
            description: "Create a tool.",
            budgets: .preview,
            operation: .create,
            currentTool: installedTool
        ))
        XCTAssertThrowsError(try ToolAgentStartV1(
            description: "Edit it.",
            budgets: .preview,
            operation: .edit
        ))
        XCTAssertThrowsError(try ToolAgentStartV1(
            description: "Edit it.",
            budgets: .preview,
            operation: .edit,
            currentTool: installedTool,
            failure: "wrong output"
        ))
        XCTAssertThrowsError(try ToolBuildRequestV1(
            description: "Fix it.",
            budgets: .preview,
            operation: .fix,
            currentTool: installedTool
        ))
        XCTAssertThrowsError(try ToolBuildRequestV1(
            description: "Fix it.",
            budgets: .preview,
            operation: .fix,
            failure: "wrong output"
        ))
    }

    func testInstalledToolRejectsShapesTheStrictSidecarCannotDecode() {
        XCTAssertThrowsError(try ToolAgentInstalledToolV1(
            kind: .native,
            name: "Open Notes",
            brief: "",
            symbolName: "doc.text",
            input: .none,
            output: .panel,
            trigger: .always,
            nativeAction: .openApp,
            target: "Notes"
        ))
        XCTAssertThrowsError(try ToolAgentInstalledToolV1(
            kind: .python,
            name: "Files",
            brief: "",
            symbolName: "folder",
            input: .files,
            output: .files,
            trigger: .files,
            source: "print('ok')",
            outputDirectory: "",
            timeoutSeconds: 30
        ))
        XCTAssertThrowsError(try ToolAgentInstalledToolV1(
            kind: .python,
            name: "Files",
            brief: "",
            symbolName: "folder",
            input: .files,
            output: .files,
            trigger: .files,
            source: "print('ok')",
            outputDirectory: String(
                repeating: "x",
                count: ToolAgentProtocolLimitsV1.maximumTargetBytes + 1
            ),
            timeoutSeconds: 30
        ))
    }

    func testInstalledToolRejectsIrrelevantFieldsThatWouldBeDroppedOnEncode() {
        XCTAssertThrowsError(try ToolAgentInstalledToolV1(
            kind: .prompt,
            name: "Explain",
            brief: "",
            symbolName: "lightbulb",
            input: .selection,
            output: .panel,
            trigger: .always,
            prompt: "Explain simply.",
            timeoutSeconds: 30,
            declaresNetwork: true
        ))
        XCTAssertThrowsError(try ToolAgentInstalledToolV1(
            kind: .native,
            name: "Open Notes",
            brief: "",
            symbolName: "doc.text",
            input: .none,
            output: .notify,
            trigger: .always,
            appliesTargetLanguage: true,
            nativeAction: .openApp,
            target: "Notes",
            declaresNetwork: true
        ))
        XCTAssertThrowsError(try ToolAgentInstalledToolV1(
            kind: .python,
            name: "Uppercase",
            brief: "",
            symbolName: "textformat",
            input: .selection,
            output: .clipboard,
            trigger: .always,
            prompt: "ignored",
            appliesTargetLanguage: true,
            source: "print('ok')",
            timeoutSeconds: 30
        ))
    }

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
        XCTAssertThrowsError(try makeCandidate(fixtures: Array(repeating: .init(input: "input", expectedOutput: "OK"), count: ToolAgentProtocolLimitsV1.maximumFixtureCount + 1)))
    }

    /// A tool whose whole point is a side effect cannot be handed a fixture
    /// without performing it, and a tool that reads the clock or the network
    /// has no exact output to promise. Both used to be unrepresentable.
    func testCandidateAcceptsUncheckableFixtures() throws {
        XCTAssertNoThrow(try makeCandidate(fixtures: []))
        XCTAssertNoThrow(try makeCandidate(fixtures: [.init(input: "input")]))
    }

    /// The fingerprint is a hash of the canonical encoding, and the model action
    /// validator accepts a candidate by re-encoding it and comparing bytes. Both
    /// break silently if an absent `expectedOutput` encodes as an explicit null.
    func testFixtureWithoutExpectedOutputRoundTripsWithoutTheKey() throws {
        // Given
        let candidate = try makeCandidate(fixtures: [.init(input: "input")])

        // When
        let encoded = try ToolAgentCanonicalJSONV1.encode(candidate)
        let decoded = try JSONDecoder().decode(
            ToolAgentCandidateV1.self,
            from: encoded
        )

        // Then
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("expectedOutput"))
        XCTAssertEqual(decoded, candidate)
        XCTAssertEqual(try ToolAgentCanonicalJSONV1.encode(decoded), encoded)
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
        let validation = try ToolAgentValidationReportV1(
            candidateID: candidateID,
            fingerprint: fingerprint,
            outcome: .passed,
            passingFingerprint: fingerprint
        )
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
        let staleValidation = try ToolAgentValidationReportV1(
            candidateID: UUID(),
            fingerprint: fingerprint,
            outcome: .passed,
            passingFingerprint: fingerprint
        )
        let mismatchedFinish = try ToolAgentFinishCandidateRequestV1(candidateID: write.candidateID, fingerprint: ToolAgentFingerprintV1("b".repeated(count: 64)))

        XCTAssertThrowsError(try ToolAgentAttestationV1(write: write, validation: staleValidation, finish: .init(candidateID: write.candidateID, fingerprint: fingerprint)))
        XCTAssertThrowsError(
            try ToolAgentAttestationV1(
                write: write,
                validation: .init(
                    candidateID: write.candidateID,
                    fingerprint: fingerprint,
                    outcome: .passed,
                    passingFingerprint: fingerprint
                ),
                finish: mismatchedFinish
            )
        )
    }

    func testValidationReportCarriesBoundedRepairDetail() throws {
        // Given
        let fingerprint = ToolAgentFingerprintV1("a".repeated(count: 64))
        let report = try ToolAgentValidationReportV1(
            candidateID: UUID(),
            fingerprint: fingerprint,
            outcome: .failed,
            failure: .wrongOutput,
            fixtureIndex: 0,
            expectedOutput: "HELLO",
            actualOutput: "hello",
            stderrDetail: "",
            exitCode: 0,
            stdoutWasTruncated: false,
            stderrWasTruncated: false,
            durationMilliseconds: 4
        )

        // When
        let decoded = try JSONDecoder().decode(
            ToolAgentValidationReportV1.self,
            from: ToolAgentCanonicalJSONV1.encode(report)
        )

        // Then
        XCTAssertEqual(decoded, report)
        XCTAssertEqual(decoded.failure, .wrongOutput)
        XCTAssertEqual(decoded.expectedOutput, "HELLO")
        XCTAssertEqual(decoded.actualOutput, "hello")
    }

    func testValidationReportRejectsUnattestedPassAndOversizeDetail() {
        // Given
        let fingerprint = ToolAgentFingerprintV1("a".repeated(count: 64))

        // Then
        XCTAssertThrowsError(
            try ToolAgentValidationReportV1(
                candidateID: UUID(),
                fingerprint: fingerprint,
                outcome: .passed
            )
        )
        XCTAssertThrowsError(
            try ToolAgentValidationReportV1(
                candidateID: UUID(),
                fingerprint: fingerprint,
                outcome: .failed,
                failure: .runtimeError,
                stderrDetail: "x".repeated(
                    count: ToolAgentProtocolLimitsV1.maximumDiagnosticBytes + 1
                )
            )
        )
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

    func testAskUserRequestAndResponseRoundTrip() throws {
        // Given
        let request = try ToolAgentAskUserRequestV1(question: "Which app should receive the selected text?")
        let response = try ToolAgentAskUserResponseV1(answer: "Notes")
        let requestEnvelope = ToolAgentToolRequestEnvelopeV1(
            callID: UUID(),
            request: .askUser(request)
        )
        let responseEnvelope = ToolAgentToolResponseEnvelopeV1(
            callID: UUID(),
            result: .askUser(response)
        )

        // When
        let decodedRequest = try JSONDecoder().decode(
            ToolAgentToolRequestEnvelopeV1.self,
            from: ToolAgentCanonicalJSONV1.encode(requestEnvelope)
        )
        let decodedResponse = try JSONDecoder().decode(
            ToolAgentToolResponseEnvelopeV1.self,
            from: ToolAgentCanonicalJSONV1.encode(responseEnvelope)
        )

        // Then
        XCTAssertEqual(decodedRequest, requestEnvelope)
        XCTAssertEqual(decodedResponse, responseEnvelope)
    }

    func testAskUserRejectsUnknownEmptyAndOversizedUTF8Text() throws {
        // Given
        let oversized = "😀".repeated(
            count: (ToolAgentProtocolLimitsV1.maximumSafeMessageBytes / 4) + 1
        )
        let unexpectedField = try ToolAgentCanonicalJSONV1.encode([
            "question": "Where should the result go?",
            "unexpected": "value"
        ])
        let unexpectedResponseField = try ToolAgentCanonicalJSONV1.encode([
            "answer": "Notes",
            "unexpected": "value"
        ])

        // Then
        XCTAssertThrowsError(try ToolAgentAskUserRequestV1(question: ""))
        XCTAssertThrowsError(try ToolAgentAskUserResponseV1(answer: ""))
        XCTAssertThrowsError(try ToolAgentAskUserRequestV1(question: oversized))
        XCTAssertThrowsError(try ToolAgentAskUserResponseV1(answer: oversized))
        XCTAssertThrowsError(
            try JSONDecoder().decode(ToolAgentAskUserRequestV1.self, from: unexpectedField)
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(ToolAgentAskUserResponseV1.self, from: unexpectedResponseField)
        )
    }

    /// Options are optional on the wire on purpose: the validator compares a
    /// re-encoded candidate byte for byte against what the model sent, so a
    /// candidate with no options must not grow an `"options":[]` key it never
    /// wrote — that would change the fingerprint of every gizmo built so far.
    func testOptionsAreOmittedWhenAbsentAndRoundTripWhenPresent() throws {
        let plain = try ToolAgentCandidateV1(
            kind: .prompt,
            name: "Plain",
            brief: "Does one thing.",
            symbolName: "sparkles",
            input: .selection,
            output: .panel,
            trigger: .always,
            prompt: "Do the thing."
        )
        let plainJSON = String(data: try JSONEncoder().encode(plain), encoding: .utf8) ?? ""
        XCTAssertFalse(plainJSON.contains("options"))

        let varied = try ToolAgentCandidateV1(
            kind: .prompt,
            name: "Varied",
            brief: "Does it three ways.",
            symbolName: "sparkles",
            input: .selection,
            output: .panel,
            trigger: .always,
            options: ["short", "medium", "long"],
            prompt: "Write a {option} version."
        )
        let decoded = try JSONDecoder().decode(
            ToolAgentCandidateV1.self,
            from: try JSONEncoder().encode(varied)
        )
        XCTAssertEqual(decoded.options, ["short", "medium", "long"])
    }

    /// One option is not a choice, six do not fan cleanly, and a blank circle is
    /// a button with no name. All three are the model's mistake to fix, not
    /// something to quietly repair on the way in.
    func testOptionsOutsideTheAllowedShapeAreRejected() {
        func candidate(_ options: [String]) throws -> ToolAgentCandidateV1 {
            try ToolAgentCandidateV1(
                kind: .prompt,
                name: "Varied",
                brief: "Does it several ways.",
                symbolName: "sparkles",
                input: .selection,
                output: .panel,
                trigger: .always,
                options: options,
                prompt: "Write a {option} version."
            )
        }
        XCTAssertThrowsError(try candidate(["only"]))
        XCTAssertThrowsError(try candidate(["a", "b", "c", "d", "e", "f"]))
        XCTAssertThrowsError(try candidate(["a", ""]))
        XCTAssertThrowsError(try candidate(["a", "a"]))
        XCTAssertThrowsError(try candidate(["a", String(repeating: "x", count: 65)]))
    }

    func testASurfaceCandidateMustCarryALayout() {
        XCTAssertThrowsError(try ToolAgentCandidateV1(
            kind: .python, name: "Downloads", brief: "Shows my downloads.",
            symbolName: "tray", input: .none, output: .surface, trigger: .always,
            source: "print('{\"rows\":[]}')"
        ))
    }

    func testALayoutOnANonSurfaceCandidateIsRejected() {
        XCTAssertThrowsError(try ToolAgentCandidateV1(
            kind: .python, name: "Slug", brief: "Slugifies.", symbolName: "link",
            input: .selection, output: .clipboard, trigger: .selection,
            source: "print('x')", layout: .text(.literal("x"))
        ))
    }

    func testOnlyAScriptCanBeASurface() {
        for kind in [ToolAgentCandidateKindV1.prompt, .native, .agent] {
            XCTAssertThrowsError(try ToolAgentCandidateV1(
                kind: kind, name: "Downloads", brief: "Shows my downloads.",
                symbolName: "tray", input: .none, output: .surface,
                trigger: .always, prompt: "list files",
                layout: .text(.literal("x"))
            ), "\(kind.rawValue) has no script to print rows")
        }
    }

    /// A surface is never handed anything and is never conditional — it is on an
    /// edge, showing what it shows.
    func testASurfaceTakesNoInputAndAlwaysApplies() {
        XCTAssertThrowsError(try ToolAgentCandidateV1(
            kind: .python, name: "Downloads", brief: "Shows my downloads.",
            symbolName: "tray", input: .selection, output: .surface,
            trigger: .always, source: "print('{}')",
            layout: .text(.literal("x"))
        ))
        XCTAssertThrowsError(try ToolAgentCandidateV1(
            kind: .python, name: "Downloads", brief: "Shows my downloads.",
            symbolName: "tray", input: .none, output: .surface,
            trigger: .files, source: "print('{}')",
            layout: .text(.literal("x"))
        ))
    }

    /// The root has to repeat, or there is nowhere for rows to go.
    func testASurfaceLayoutRootMustBeARepeater() {
        XCTAssertThrowsError(try ToolAgentCandidateV1(
            kind: .python, name: "Downloads", brief: "Shows my downloads.",
            symbolName: "tray", input: .none, output: .surface, trigger: .always,
            source: "print('{}')", layout: .text(.key("name"))
        ))
    }

    /// `grid(cell: list(row: card))` is legal by depth (3) and its root
    /// repeats, but `SurfaceRow` is flat — the inner `list` has no second
    /// collection to iterate. Everything this vocabulary can express has to
    /// mean something; a nested repeater is the one shape that doesn't.
    func testASurfaceLayoutRejectsARepeaterNestedInsideAnotherRepeater() {
        XCTAssertThrowsError(try ToolAgentCandidateV1(
            kind: .python, name: "Downloads", brief: "Shows my downloads.",
            symbolName: "tray", input: .none, output: .surface, trigger: .always,
            source: "print('{\"rows\":[]}')",
            layout: .grid(
                cell: .list(row: .card(title: .key("name"), subtitle: nil, icon: nil, drag: nil, tap: nil),
                            empty: "Nothing here"),
                minimumWidth: 96,
                empty: "Nothing in Downloads"
            )
        ))
    }

    func testTheFolderHubCandidateIsAccepted() throws {
        XCTAssertNoThrow(try ToolAgentCandidateV1(
            kind: .python, name: "Downloads", brief: "Shows my downloads.",
            symbolName: "tray", input: .none, output: .surface, trigger: .always,
            source: "print('{\"rows\":[]}')",
            layout: .grid(
                cell: .card(title: .key("name"), subtitle: .key("size"),
                            icon: .file(key: "path"), drag: .file(key: "path"),
                            tap: .reveal(key: "path")),
                minimumWidth: 96,
                empty: "Nothing in Downloads"
            )
        ))
    }

    /// nil must not survive as an empty key, or the byte-for-byte re-encode in
    /// `ToolAgentModelActionValidator` rejects every candidate that has no layout.
    func testACandidateWithoutALayoutEncodesNoLayoutKey() throws {
        let candidate = try ToolAgentCandidateV1(
            kind: .python, name: "Slug", brief: "Slugifies.", symbolName: "link",
            input: .selection, output: .clipboard, trigger: .selection,
            source: "print('x')"
        )
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(candidate)
        ) as? [String: Any]
        XCTAssertNil(json?["layout"])
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
