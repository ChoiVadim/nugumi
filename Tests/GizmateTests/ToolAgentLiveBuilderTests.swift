import Foundation
import XCTest
import GizmateToolAgentCore
@testable import Gizmate

final class ToolAgentLiveBuilderTests: XCTestCase {
    func testFixDiagnosticIsExactAndUTF8BoundedBeforePiRequest() {
        let short = "Expected HELLO, received hello."
        let long = "prefix-" + String(repeating: "😀", count: 5_000) + "-latest-error"

        XCTAssertEqual(ToolAgentLiveBuilder.boundedDiagnostic(short), short)

        let bounded = ToolAgentLiveBuilder.boundedDiagnostic(long)
        XCTAssertLessThanOrEqual(
            bounded.utf8.count,
            ToolAgentProtocolLimitsV1.maximumDiagnosticBytes
        )
        XCTAssertTrue(bounded.hasSuffix("-latest-error"))
        XCTAssertTrue(long.hasSuffix(bounded))
    }

    func testSnapshotsExistingPromptToolForPiEditing() throws {
        let tool = GizmateTool(
            name: "Explain",
            symbolName: "lightbulb",
            kind: .prompt,
            input: .selection,
            output: .panel,
            prompt: "Explain the selected text simply.",
            appliesTargetLanguage: true,
            timeoutSeconds: 45,
            declaresNetwork: true,
            brief: "Explains selected text."
        )

        let installed = try ToolAgentLiveBuilder.installedTool(from: tool, script: "")

        XCTAssertEqual(installed.kind, .prompt)
        XCTAssertEqual(installed.name, tool.name)
        XCTAssertEqual(installed.input, .selection)
        XCTAssertEqual(installed.output, .panel)
        XCTAssertEqual(installed.trigger, .always)
        XCTAssertEqual(installed.prompt, tool.prompt)
        XCTAssertTrue(installed.appliesTargetLanguage)
        XCTAssertEqual(installed.timeoutSeconds, 120)
        XCTAssertFalse(installed.declaresNetwork)
        XCTAssertEqual(installed.source, "")
    }

    func testSnapshotsExistingNativeToolForPiEditing() throws {
        let tool = GizmateTool(
            name: "Open copied link",
            symbolName: "link",
            kind: .native,
            input: .selection,
            output: .notify,
            nativeAction: .openURL,
            target: "{input}",
            brief: "Opens copied Example links."
        )

        let installed = try ToolAgentLiveBuilder.installedTool(from: tool, script: "")

        XCTAssertEqual(installed.kind, .native)
        // The Ring no longer gates on context, so a snapshot always says .always.
        XCTAssertEqual(installed.trigger, .always)
        XCTAssertEqual(installed.hosts, [])
        XCTAssertEqual(installed.extensions, [])
        XCTAssertEqual(installed.nativeAction, .openURL)
        XCTAssertEqual(installed.target, "{input}")
        XCTAssertEqual(installed.source, "")
    }

    func testSnapshotsFullExistingPythonSourceWithoutInventingFixtures() throws {
        let source = """
            # /// script
            # requires-python = ">=3.12"
            # dependencies = []
            # ///
            import sys
            print(sys.argv[1].upper())
            """
        let tool = GizmateTool(
            name: "Uppercase",
            symbolName: "textformat",
            kind: .python,
            input: .files,
            output: .files,
            outputDirectory: "~/Desktop",
            timeoutSeconds: 45,
            declaresNetwork: false,
            brief: "Uppercases copied text."
        )

        let installed = try ToolAgentLiveBuilder.installedTool(from: tool, script: source)

        XCTAssertEqual(installed.kind, .python)
        XCTAssertEqual(installed.source, source)
        XCTAssertEqual(installed.extensions, [])
        XCTAssertEqual(installed.outputDirectory, "~/Desktop")
        XCTAssertEqual(installed.timeoutSeconds, 45)
        XCTAssertFalse(installed.declaresNetwork)
    }

    func testAttestedEditPreservesStoredIdentityAndCreationDate() throws {
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let existing = GizmateTool(
            id: id,
            name: "Old name",
            kind: .prompt,
            prompt: "Old prompt",
            brief: "Old behavior.",
            createdAt: createdAt
        )
        let replacement = try ToolAgentCandidateV1(
            kind: .native,
            name: "Save To Notes",
            brief: "Sends selected text to Notes.",
            symbolName: "doc.text",
            input: .selection,
            output: .notify,
            trigger: .selection,
            nativeAction: .sendTextToApp,
            target: "Notes"
        )

        let generated = ToolAgentLiveBuilder.generatedTool(
            from: replacement,
            preserving: existing
        )

        XCTAssertEqual(generated.tool.id, id)
        XCTAssertEqual(generated.tool.createdAt, createdAt)
        XCTAssertEqual(generated.tool.kind, .native)
        XCTAssertEqual(generated.tool.name, "Save To Notes")
    }

    func testMapsVerifiedPromptCandidateWithoutScript() throws {
        let candidate = try ToolAgentCandidateV1(
            kind: .prompt,
            name: "Tighten",
            brief: "Rewrites selected text more concisely.",
            symbolName: "pencil",
            input: .selection,
            output: .replace,
            trigger: .selection,
            prompt: "Rewrite the input more concisely. Return only the result.",
            appliesTargetLanguage: true
        )

        let generated = ToolAgentLiveBuilder.generatedTool(from: candidate)

        XCTAssertEqual(generated.tool.kind, .prompt)
        XCTAssertEqual(generated.tool.input, .selection)
        XCTAssertEqual(generated.tool.output, .replace)
        XCTAssertEqual(generated.tool.prompt, candidate.prompt)
        XCTAssertTrue(generated.tool.appliesTargetLanguage)
        XCTAssertEqual(generated.script, "")
    }

    func testMapsVerifiedNativeCandidateWithoutPython() throws {
        let candidate = try ToolAgentCandidateV1(
            kind: .native,
            name: "Save To Notes",
            brief: "Sends selected text to Notes.",
            symbolName: "doc.text",
            input: .selection,
            output: .notify,
            trigger: .selection,
            nativeAction: .sendTextToApp,
            target: "Notes"
        )

        let generated = ToolAgentLiveBuilder.generatedTool(from: candidate)

        XCTAssertEqual(generated.tool.kind, .native)
        XCTAssertEqual(generated.tool.input, .selection)
        XCTAssertEqual(generated.tool.output, .notify)
        XCTAssertEqual(generated.tool.nativeAction, .sendTextToApp)
        XCTAssertEqual(generated.tool.target, "Notes")
        XCTAssertEqual(generated.script, "")
    }

    func testNativeValidationChecksTheTargetWithoutRunningTheAction() throws {
        let candidate = try ToolAgentCandidateV1(
            kind: .native,
            name: "Save To Notes",
            brief: "Sends selected text to Notes.",
            symbolName: "doc.text",
            input: .selection,
            output: .notify,
            trigger: .selection,
            nativeAction: .sendTextToApp,
            target: "Notes"
        )
        let candidateID = UUID()
        let fingerprint = ToolAgentFingerprintV1(String(repeating: "a", count: 64))

        let passed = try ToolAgentHostCandidateValidator.validate(
            candidateID: candidateID,
            fingerprint: fingerprint,
            candidate: candidate,
            applicationExists: { $0 == "Notes" }
        )
        let failed = try ToolAgentHostCandidateValidator.validate(
            candidateID: candidateID,
            fingerprint: fingerprint,
            candidate: candidate,
            applicationExists: { _ in false }
        )

        XCTAssertEqual(passed.outcome, .passed)
        XCTAssertEqual(passed.passingFingerprint, fingerprint)
        XCTAssertEqual(failed.outcome, .failed)
        XCTAssertEqual(failed.failure, .invalidCandidate)
        XCTAssertTrue(failed.stderrDetail?.contains("Notes") == true)
    }

    func testNativeValidationAcceptsSelectedURLInputTemplate() throws {
        let candidate = try ToolAgentCandidateV1(
            kind: .native,
            name: "Open Link",
            brief: "Opens the selected link.",
            symbolName: "link",
            input: .selection,
            output: .notify,
            trigger: .selection,
            nativeAction: .openURL,
            target: "{input}"
        )
        let fingerprint = ToolAgentFingerprintV1(
            String(repeating: "b", count: 64)
        )

        let report = try ToolAgentHostCandidateValidator.validate(
            candidateID: UUID(),
            fingerprint: fingerprint,
            candidate: candidate,
            applicationExists: { _ in false }
        )

        XCTAssertEqual(report.outcome, .passed)
        XCTAssertEqual(report.passingFingerprint, fingerprint)
    }

    /// `saveToNote` writes into Gizmate's own Notes tab, so it has no target and
    /// no app to look for — the same shape `revealInFinder` has. Requiring one
    /// would fail every note candidate the model is now told to write.
    func testNativeValidationAcceptsSaveToNoteWithoutATarget() throws {
        let candidate = try ToolAgentCandidateV1(
            kind: .native,
            name: "Keep This",
            brief: "Keeps the selected text as a note.",
            symbolName: "doc.text",
            input: .selection,
            output: .notify,
            trigger: .selection,
            nativeAction: .saveToNote
        )
        let fingerprint = ToolAgentFingerprintV1(String(repeating: "c", count: 64))

        let report = try ToolAgentHostCandidateValidator.validate(
            candidateID: UUID(),
            fingerprint: fingerprint,
            candidate: candidate,
            applicationExists: { _ in false }
        )
        let generated = ToolAgentLiveBuilder.generatedTool(from: candidate)

        XCTAssertEqual(report.outcome, .passed)
        XCTAssertEqual(generated.tool.nativeAction, .saveToNote)
        XCTAssertTrue(generated.tool.target.isEmpty)
    }

    /// A spoken prompt gizmo saved into the Notes tab: both ends of this change
    /// have to survive the raw-value mapping, or the candidate installs as
    /// "nothing in, toast out".
    func testMapsSpokenPromptCandidateThatKeepsItsAnswerAsANote() throws {
        let candidate = try ToolAgentCandidateV1(
            kind: .prompt,
            name: "Voice Note",
            brief: "Tidies up what you say and keeps it.",
            symbolName: "note.text",
            input: .dictation,
            output: .notes,
            trigger: .always,
            prompt: "Tidy this up into a short note.",
            appliesTargetLanguage: false
        )

        let generated = ToolAgentLiveBuilder.generatedTool(from: candidate)

        XCTAssertEqual(generated.tool.input, .dictation)
        XCTAssertEqual(generated.tool.output, .notes)
        XCTAssertTrue(generated.tool.input.needsDictation)
    }

    func testMapsVerifiedPythonCandidateWithItsFullManifest() throws {
        let candidate = try ToolAgentCandidateV1(
            kind: .python,
            name: "Uppercase",
            brief: "Uppercases copied text",
            symbolName: "textformat",
            input: .selection,
            output: .clipboard,
            trigger: .always,
            source: """
                # /// script
                # requires-python = ">=3.12"
                # dependencies = []
                # ///
                import sys
                print(sys.argv[1].upper())
                """,
            fixtures: [.init(input: "hello", expectedOutput: "HELLO")],
            timeoutSeconds: 45,
            declaresNetwork: false
        )

        let generated = ToolAgentLiveBuilder.generatedTool(from: candidate)

        XCTAssertEqual(generated.tool.name, candidate.name)
        XCTAssertEqual(generated.tool.symbolName, candidate.symbolName)
        XCTAssertEqual(generated.tool.kind, .python)
        XCTAssertEqual(generated.tool.input, .selection)
        XCTAssertEqual(generated.tool.output, .clipboard)
        XCTAssertEqual(generated.tool.timeoutSeconds, 45)
        XCTAssertFalse(generated.tool.declaresNetwork)
        XCTAssertEqual(generated.script, candidate.source)
        XCTAssertEqual(generated.brief, candidate.brief)
        // What was proven is decided by the validation report, not by the
        // mapping, so the summary earns its assurance sentence in `build`.
        XCTAssertEqual(generated.summary, candidate.brief)
    }

    /// The trip the revise flow actually makes: a saved surface gizmo becomes
    /// the snapshot Pi is shown, and — standing in for Pi echoing it back
    /// unchanged, the one thing no Swift code does — a candidate built from
    /// that snapshot's own `layout` (not a fresh literal) becomes the tool
    /// that gets saved. If either host-owned conversion dropped `layout`,
    /// this would come back nil rather than equal to the original.
    func testASurfaceGizmosLayoutSurvivesToolInstalledToolCandidateRoundTrip() throws {
        let layout = ToolAgentLayoutV1.grid(
            cell: .text(.key("name")), minimumWidth: 120, empty: "No downloads"
        )
        let tool = GizmateTool(
            name: "Downloads",
            symbolName: "tray",
            kind: .python,
            input: .none,
            output: .surface,
            layout: layout,
            brief: "Lists recently downloaded files."
        )

        let installed = try ToolAgentLiveBuilder.installedTool(
            from: tool, script: "print('{}')"
        )
        XCTAssertEqual(installed.layout, layout)

        let candidate = try ToolAgentCandidateV1(
            kind: installed.kind,
            name: installed.name,
            brief: installed.brief,
            symbolName: installed.symbolName,
            input: installed.input,
            output: installed.output,
            trigger: installed.trigger,
            source: installed.source,
            layout: installed.layout
        )
        let generated = ToolAgentLiveBuilder.generatedTool(from: candidate)

        XCTAssertEqual(generated.tool.output, .surface)
        XCTAssertEqual(generated.tool.layout, layout)
    }

    /// The candidate→tool half of the carry in isolation, independent of
    /// whatever the installed-tool snapshot the candidate might have started
    /// from — this is what happens on a `create`, where there was no
    /// installed tool to begin with.
    func testMapsVerifiedSurfaceCandidateWithItsLayout() throws {
        let layout = ToolAgentLayoutV1.list(
            row: .text(.key("name")), empty: "Nothing here"
        )
        let candidate = try ToolAgentCandidateV1(
            kind: .python,
            name: "Downloads",
            brief: "Lists recently downloaded files.",
            symbolName: "tray",
            input: .none,
            output: .surface,
            trigger: .always,
            source: "print('{}')",
            layout: layout
        )

        let generated = ToolAgentLiveBuilder.generatedTool(from: candidate)

        XCTAssertEqual(generated.tool.output, .surface)
        XCTAssertEqual(generated.tool.layout, layout)
    }

    func testModelActionValidatorMatchesStrictSidecarCandidateShape() {
        let valid = #"""
            {"version":1,"action":"toolCall","name":"write_candidate","arguments":{"candidate":{"schemaVersion":1,"kind":"native","name":"Save To Notes","brief":"Sends selected text to Notes.","symbolName":"doc.text","input":"selection","output":"notify","trigger":"selection","hosts":[],"extensions":[],"nativeAction":"sendTextToApp","target":"Notes"}}}
            """#
        let extraCandidateKey = valid.replacingOccurrences(
            of: #""target":"Notes""#,
            with: #""target":"Notes","source":"print('wrong kind')""#
        )

        XCTAssertTrue(ToolAgentModelActionValidator.isValid(valid))
        XCTAssertEqual(
            ToolAgentModelActionValidator.normalized("```json\n\(valid)\n```"),
            valid
        )
        XCTAssertNil(
            ToolAgentModelActionValidator.normalized("Here it is:\n```json\n\(valid)\n```")
        )
        XCTAssertNil(
            ToolAgentModelActionValidator.normalized("```json\n\(valid)\n```\nextra")
        )
        XCTAssertFalse(ToolAgentModelActionValidator.isValid(extraCandidateKey))
        XCTAssertTrue(ToolAgentModelActionValidator.isValid(
            #"{"version":1,"action":"toolCall","name":"read_build_context","arguments":{}}"#
        ))
        XCTAssertTrue(ToolAgentModelActionValidator.isValid(
            #"{"version":1,"action":"toolCall","name":"ask_user","arguments":{"questions":[{"question":"Which app should receive the text?","options":["Notes","Mail"]}]}}"#
        ))
        XCTAssertFalse(ToolAgentModelActionValidator.isValid(
            #"{"version":1,"action":"toolCall","name":"ask_user","arguments":{"questions":[{"question":"Which app?"}],"extra":true}}"#
        ))
    }

    /// A tool name in "action" is a rewrap, not a rejection.
    ///
    /// The default builder model is whatever the machine has, and a local one
    /// writes the tool name where the envelope goes: `{"action":"ask_user",
    /// "questions":[…]}` instead of `{"action":"toolCall","name":"ask_user",
    /// "arguments":{"questions":[…]}}`. The intent and every argument are
    /// already exactly right, and telling the model so in a repair turn does
    /// not help — it made the same mistake again with a different tool name,
    /// which is how a build died on turn one having understood the request
    /// perfectly. There is only one thing `"action":"ask_user"` can mean, so
    /// the host means it rather than spending a model turn asking.
    func testModelActionValidatorRewrapsAToolNameWrittenIntoAction() {
        XCTAssertEqual(
            ToolAgentModelActionValidator.normalized(
                #"{"version":1,"action":"ask_user","questions":[{"question":"Which app?","options":["Notes"]}]}"#
            ),
            #"{"action":"toolCall","arguments":{"questions":[{"options":["Notes"],"question":"Which app?"}]},"name":"ask_user","version":1}"#
        )
        // No arguments at all, which is the correct shape for this one.
        XCTAssertTrue(ToolAgentModelActionValidator.isValid(
            #"{"version":1,"action":"read_build_context"}"#
        ))
        // Already nested under "arguments", only the envelope wrong.
        XCTAssertTrue(ToolAgentModelActionValidator.isValid(
            #"{"version":1,"action":"read_build_context","arguments":{}}"#
        ))
        // Fenced and wrapped wrong at once, which is what a weak model does.
        XCTAssertTrue(ToolAgentModelActionValidator.isValid(
            "```json\n" + #"{"version":1,"action":"ask_user","questions":[{"question":"Where?"}]}"# + "\n```"
        ))
        // The rewrap buys no leniency about the arguments themselves.
        XCTAssertFalse(ToolAgentModelActionValidator.isValid(
            #"{"version":1,"action":"ask_user","questions":[]}"#
        ))
        XCTAssertFalse(ToolAgentModelActionValidator.isValid(
            #"{"version":1,"action":"read_build_context","unexpected":1}"#
        ))
        // Not a tool name, so still exactly as wrong as it was.
        XCTAssertFalse(ToolAgentModelActionValidator.isValid(
            #"{"version":1,"action":"ask_the_user","questions":[{"question":"Which app?"}]}"#
        ))
    }

    func testModelActionValidatorMatchesSidecarNativeOutputAndPythonDirectoryRules() {
        let invalidNativeOutput = #"""
            {"version":1,"action":"toolCall","name":"write_candidate","arguments":{"candidate":{"schemaVersion":1,"kind":"native","name":"Open Link","brief":"Opens a selected link.","symbolName":"link","input":"selection","output":"panel","trigger":"selection","hosts":[],"extensions":[],"nativeAction":"openURL","target":"{input}"}}}
            """#
        let validPythonWithoutDirectory = #"""
            {"version":1,"action":"toolCall","name":"write_candidate","arguments":{"candidate":{"schemaVersion":1,"kind":"python","name":"Uppercase","brief":"Uppercases text.","symbolName":"textformat","input":"selection","output":"clipboard","trigger":"always","hosts":[],"extensions":[],"source":"print('OK')","fixtures":[{"input":"ok","expectedOutput":"OK"}],"timeoutSeconds":30,"declaresNetwork":false}}}
            """#
        let emptyPythonDirectory = #"""
            {"version":1,"action":"toolCall","name":"write_candidate","arguments":{"candidate":{"schemaVersion":1,"kind":"python","name":"Write File","brief":"Writes a file.","symbolName":"folder","input":"files","output":"files","trigger":"files","hosts":[],"extensions":[],"source":"print('OK')","fixtures":[{"input":"ok","expectedOutput":"OK"}],"outputDirectory":"","timeoutSeconds":30,"declaresNetwork":false}}}
            """#
        let nullPythonDirectory = #"""
            {"version":1,"action":"toolCall","name":"write_candidate","arguments":{"candidate":{"schemaVersion":1,"kind":"python","name":"Uppercase","brief":"Uppercases text.","symbolName":"textformat","input":"selection","output":"clipboard","trigger":"always","hosts":[],"extensions":[],"source":"print('OK')","fixtures":[{"input":"ok","expectedOutput":"OK"}],"outputDirectory":null,"timeoutSeconds":30,"declaresNetwork":false}}}
            """#
        let oversizedDirectory = String(
            repeating: "x",
            count: ToolAgentProtocolLimitsV1.maximumTargetBytes + 1
        )
        let oversizedPythonDirectory = #"""
            {"version":1,"action":"toolCall","name":"write_candidate","arguments":{"candidate":{"schemaVersion":1,"kind":"python","name":"Write File","brief":"Writes a file.","symbolName":"folder","input":"files","output":"files","trigger":"files","hosts":[],"extensions":[],"source":"print('OK')","fixtures":[{"input":"ok","expectedOutput":"OK"}],"outputDirectory":"\#(oversizedDirectory)","timeoutSeconds":30,"declaresNetwork":false}}}
            """#

        XCTAssertFalse(ToolAgentModelActionValidator.isValid(invalidNativeOutput))
        XCTAssertTrue(ToolAgentModelActionValidator.isValid(validPythonWithoutDirectory))
        XCTAssertFalse(ToolAgentModelActionValidator.isValid(emptyPythonDirectory))
        XCTAssertFalse(ToolAgentModelActionValidator.isValid(nullPythonDirectory))
        XCTAssertFalse(ToolAgentModelActionValidator.isValid(oversizedPythonDirectory))
    }

    // MARK: - Saying why

    /// The validator's `false` is correct and useless on its own. Every case
    /// here is one a model actually has no way to see: the decoder defaults a
    /// missing key while the encoder demands it back, and the encoder writes
    /// only the keys of the candidate's own kind. Left undiagnosed, each of
    /// them burns a build and reaches the user as "the model returned an
    /// invalid agent action".
    func testTheDiagnosisNamesAMissingCandidateKey() {
        let missingHosts = #"""
            {"version":1,"action":"toolCall","name":"write_candidate","arguments":{"candidate":{"schemaVersion":1,"kind":"python","name":"Uppercase","brief":"Uppercases text.","symbolName":"textformat","input":"selection","output":"clipboard","trigger":"always","extensions":[],"source":"print('OK')","fixtures":[{"input":"ok","expectedOutput":"OK"}],"timeoutSeconds":30,"declaresNetwork":false}}}
            """#

        let problem = ToolAgentModelActionDiagnosis.problem(with: missingHosts)

        XCTAssertFalse(ToolAgentModelActionValidator.isValid(missingHosts))
        XCTAssertEqual(problem?.contains("\"hosts\""), true, problem ?? "no diagnosis")
        XCTAssertEqual(problem?.contains("missing"), true, problem ?? "no diagnosis")
    }

    /// The envelope is repaired without a model turn, so it is not the problem.
    ///
    /// A local model wrote `"action":"write_candidate"` around a candidate that
    /// was also missing a required key. Diagnosing the raw text reported only
    /// the envelope, the model spent its one repair fixing something the host
    /// had already forgiven, and the real defect surfaced a turn too late to be
    /// fixed. The diagnosis reads what the host would have run.
    func testTheDiagnosisLooksPastAnEnvelopeTheHostRepairsItself() {
        let wrongEnvelopeAndMissingKey = #"""
            {"version":1,"action":"write_candidate","arguments":{"candidate":{"schemaVersion":1,"kind":"python","name":"Uppercase","brief":"Uppercases text.","symbolName":"textformat","input":"selection","output":"clipboard","trigger":"always","extensions":[],"source":"print('OK')","fixtures":[{"input":"ok","expectedOutput":"OK"}],"timeoutSeconds":30,"declaresNetwork":false}}}
            """#

        let problem = ToolAgentModelActionDiagnosis.problem(with: wrongEnvelopeAndMissingKey)

        XCTAssertFalse(ToolAgentModelActionValidator.isValid(wrongEnvelopeAndMissingKey))
        XCTAssertEqual(problem?.contains("\"hosts\""), true, problem ?? "no diagnosis")
        XCTAssertEqual(problem?.contains("toolCall"), false, problem ?? "no diagnosis")
    }

    func testTheDiagnosisNamesAKeyThatBelongsToAnotherKind() {
        let promptOnPython = #"""
            {"version":1,"action":"toolCall","name":"write_candidate","arguments":{"candidate":{"schemaVersion":1,"kind":"python","name":"Uppercase","brief":"Uppercases text.","symbolName":"textformat","input":"selection","output":"clipboard","trigger":"always","hosts":[],"extensions":[],"prompt":"Uppercase this","source":"print('OK')","fixtures":[{"input":"ok","expectedOutput":"OK"}],"timeoutSeconds":30,"declaresNetwork":false}}}
            """#

        let problem = ToolAgentModelActionDiagnosis.problem(with: promptOnPython)

        XCTAssertFalse(ToolAgentModelActionValidator.isValid(promptOnPython))
        XCTAssertEqual(problem?.contains("\"prompt\""), true, problem ?? "no diagnosis")
        XCTAssertEqual(problem?.contains("python"), true, problem ?? "no diagnosis")
    }

    /// An explicit null is the same shape of mistake and the most tempting one:
    /// the model has a key it decided not to use, and writing `null` looks more
    /// complete than leaving it out. The encoder drops it, so the bytes differ.
    func testTheDiagnosisTellsTheModelToOmitRatherThanNull() {
        let nullDirectory = #"""
            {"version":1,"action":"toolCall","name":"write_candidate","arguments":{"candidate":{"schemaVersion":1,"kind":"python","name":"Uppercase","brief":"Uppercases text.","symbolName":"textformat","input":"selection","output":"clipboard","trigger":"always","hosts":[],"extensions":[],"source":"print('OK')","fixtures":[{"input":"ok","expectedOutput":"OK"}],"outputDirectory":null,"timeoutSeconds":30,"declaresNetwork":false}}}
            """#

        let problem = ToolAgentModelActionDiagnosis.problem(with: nullDirectory)

        XCTAssertEqual(problem?.contains("\"outputDirectory\""), true, problem ?? "no diagnosis")
        XCTAssertEqual(problem?.contains("null"), true, problem ?? "no diagnosis")
    }

    /// A value the enum does not have. The decoder's own message names it, so
    /// the diagnosis carries that rather than paraphrasing it.
    func testTheDiagnosisCarriesTheDecodersOwnComplaint() {
        let unknownOutput = #"""
            {"version":1,"action":"toolCall","name":"write_candidate","arguments":{"candidate":{"schemaVersion":1,"kind":"python","name":"Uppercase","brief":"Uppercases text.","symbolName":"textformat","input":"selection","output":"hologram","trigger":"always","hosts":[],"extensions":[],"source":"print('OK')","fixtures":[],"timeoutSeconds":30,"declaresNetwork":false}}}
            """#

        let problem = ToolAgentModelActionDiagnosis.problem(with: unknownOutput)

        XCTAssertEqual(problem?.contains("hologram"), true, problem ?? "no diagnosis")
    }

    /// The rules `validate` enforces all throw the same bare error, so the one
    /// field that broke one is found by taking keys away until the candidate
    /// decodes. This one is a real python key with a value the rules refuse.
    func testTheDiagnosisNamesTheFieldARuleRefused() {
        let tooLong = String(
            repeating: "x", count: ToolAgentProtocolLimitsV1.maximumBriefBytes + 1
        )
        let oversizedBrief = #"""
            {"version":1,"action":"toolCall","name":"write_candidate","arguments":{"candidate":{"schemaVersion":1,"kind":"python","name":"Uppercase","brief":"\#(tooLong)","symbolName":"textformat","input":"selection","output":"clipboard","trigger":"always","hosts":[],"extensions":[],"source":"print('OK')","fixtures":[],"timeoutSeconds":30,"declaresNetwork":false}}}
            """#

        let problem = ToolAgentModelActionDiagnosis.problem(with: oversizedBrief)

        XCTAssertFalse(ToolAgentModelActionValidator.isValid(oversizedBrief))
        XCTAssertEqual(problem?.contains("\"brief\""), true, problem ?? "no diagnosis")
        XCTAssertEqual(problem?.contains("length"), true, problem ?? "no diagnosis")
    }

    func testTheDiagnosisListsTheRealToolsWhenOneIsInvented() {
        let problem = ToolAgentModelActionDiagnosis.problem(
            with: #"{"version":1,"action":"toolCall","name":"save_candidate","arguments":{}}"#
        )

        XCTAssertEqual(problem?.contains("save_candidate"), true, problem ?? "no diagnosis")
        XCTAssertEqual(problem?.contains("write_candidate"), true, problem ?? "no diagnosis")
    }

    /// A reasoning field beside the action is the other thing models do here,
    /// and the wire format has no room for it.
    func testTheDiagnosisNamesTheOnlyKeysAToolCallMayCarry() {
        let problem = ToolAgentModelActionDiagnosis.problem(
            with: #"{"version":1,"action":"toolCall","name":"read_build_context","arguments":{},"reasoning":"I should read the context first"}"#
        )

        XCTAssertEqual(problem?.contains("\"arguments\""), true, problem ?? "no diagnosis")
    }

    func testProseIsDiagnosedAsProseRatherThanAsASchemaProblem() {
        let problem = ToolAgentModelActionDiagnosis.problem(with: "Sure, I'll build that!")

        XCTAssertEqual(problem?.contains("JSON object"), true, problem ?? "no diagnosis")
    }

    /// The diagnosis runs only on the failure path, so a valid action must
    /// produce nothing at all rather than a sentence nobody needs.
    func testAValidActionHasNoProblem() {
        XCTAssertNil(
            ToolAgentModelActionDiagnosis.problem(
                with: #"{"version":1,"action":"toolCall","name":"read_build_context","arguments":{}}"#
            )
        )
    }

    /// A fenced action is valid, so its fenced *invalid* twin has to be read
    /// through the fence too. Diagnosing it as "not JSON" would send the model
    /// after the wrapper instead of the field it got wrong.
    func testAFencedResponseIsDiagnosedThroughItsFence() {
        let missingHosts = #"""
            {"version":1,"action":"toolCall","name":"write_candidate","arguments":{"candidate":{"schemaVersion":1,"kind":"python","name":"Uppercase","brief":"Uppercases text.","symbolName":"textformat","input":"selection","output":"clipboard","trigger":"always","extensions":[],"source":"print('OK')","fixtures":[],"timeoutSeconds":30,"declaresNetwork":false}}}
            """#

        let problem = ToolAgentModelActionDiagnosis.problem(with: "```json\n\(missingHosts)\n```")

        XCTAssertEqual(problem?.contains("\"hosts\""), true, problem ?? "no diagnosis")
    }

    func testUnsupportedFinalTextIsExtractedWithoutRelaxingOtherFinalText() {
        XCTAssertEqual(
            ToolAgentModelActionInspector.unsupportedMessage(
                in: #"{"version":1,"action":"finalText","text":"UNSUPPORTED: This needs network access."}"#
            ),
            "This needs network access."
        )
        XCTAssertNil(
            ToolAgentModelActionInspector.unsupportedMessage(
                in: #"{"version":1,"action":"finalText","text":"candidate ready"}"#
            )
        )
        XCTAssertNil(
            ToolAgentModelActionInspector.unsupportedMessage(
                in: #"{"version":1,"action":"finalText","text":"UNSUPPORTED:"}"#
            )
        )
    }

    func testProductionSupervisorConstructionWiresClarificationAndCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tool-agent-live-builder-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ToolBuildStore(directoryURL: directory)
        let request = ToolBuildRequestV1(description: "Send selected text")
        let process = try ToolAgentLiveBuilderClarificationProcess(runID: request.runID)
        let probe = ToolAgentLiveBuilderClarificationProbe()
        let invocationProbe = ToolAgentLiveBuilderInvocationProbe()
        let supervisor = ToolAgentLiveBuilder.makeSupervisor(
            store: store,
            runtimeVersion: "test-runtime",
            policyVersion: "test-policy",
            makeProcess: { _ in process.client() },
            model: { _ in
                await invocationProbe.recordModel()
                return .error(.workerFailure)
            },
            validation: { _ in
                await invocationProbe.recordValidation()
                throw ToolAgentFailureCodeV1.workerFailure
            },
            clarification: { request in
                try await probe.handle(request)
            },
            clarificationCancellation: {
                await probe.cancel()
            }
        )
        let build = Task { try await supervisor.build(request) }

        var clarificationStarted = false
        for _ in 0..<100 {
            if await probe.didStart {
                clarificationStarted = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(clarificationStarted)
        guard clarificationStarted else {
            _ = await build.result
            return
        }

        let didCancel = await supervisor.cancel(runID: request.runID)
        let result = await build.result
        guard case .failure(let error) = result else {
            return XCTFail("Expected cancellation")
        }
        let question = await probe.question
        let cancellationCount = await probe.cancellationCount
        let processWasCancelled = await process.wasCancelled
        let invocations = await invocationProbe.values
        XCTAssertTrue(didCancel)
        XCTAssertEqual(error as? ToolAgentFailureCodeV1, .cancelled)
        XCTAssertEqual(question, "Which app should receive the text?")
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertTrue(processWasCancelled)
        XCTAssertEqual(invocations.model, 0)
        XCTAssertEqual(invocations.validation, 0)
    }
}

private actor ToolAgentLiveBuilderClarificationProbe {
    private(set) var question: String?
    private(set) var cancellationCount = 0
    private var continuation: CheckedContinuation<ToolAgentAskUserResponseV1, Error>?

    var didStart: Bool {
        question != nil
    }

    func handle(
        _ request: ToolAgentAskUserRequestV1
    ) async throws -> ToolAgentAskUserResponseV1 {
        question = request.questions.first?.question
        return try await withCheckedThrowingContinuation {
            continuation = $0
        }
    }

    func cancel() {
        cancellationCount += 1
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private actor ToolAgentLiveBuilderInvocationProbe {
    private var model = 0
    private var validation = 0

    func recordModel() {
        model += 1
    }

    func recordValidation() {
        validation += 1
    }

    var values: (model: Int, validation: Int) {
        (model, validation)
    }
}

private actor ToolAgentLiveBuilderClarificationProcess {
    private var messages: [ToolAgentMessageV1]
    private(set) var wasCancelled = false

    init(runID: UUID) throws {
        messages = [
            .state(runID: runID, .init(state: .understanding)),
            .toolRequest(
                runID: runID,
                .init(
                    callID: UUID(),
                    request: .askUser(
                        try .init(questions: [.init(question: "Which app should receive the text?")])
                    )
                )
            ),
        ]
    }

    nonisolated func client() -> ToolBuildProcessClientV1 {
        .init(
            send: { _ in },
            receive: { [self] in await receive() },
            cancel: { [self] in await cancel() }
        )
    }

    private func receive() -> ToolAgentMessageV1? {
        messages.isEmpty ? nil : messages.removeFirst()
    }

    private func cancel() {
        wasCancelled = true
    }
}
