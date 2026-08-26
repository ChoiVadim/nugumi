import GizmateToolAgentCore
import XCTest

@testable import Gizmate

/// A run speaks `run_python`/`finish`, which the build-vocabulary
/// `normalized` reads as invalid — that mismatch made `answerModel`'s
/// normalization a silent no-op for months, and a fenced or malformed run
/// reply killed the whole run. These pin the run-side reading.
final class RunModelActionNormalizationTests: XCTestCase {
    private let runAction =
        #"{"version":1,"action":"toolCall","name":"run_python","arguments":{"source":"print(1)","purpose":"count"}}"#

    func testAValidRunActionPassesThroughUntouched() {
        XCTAssertEqual(ToolAgentModelActionValidator.normalizedForRun(runAction), runAction)
        let finish = #"{"version":1,"action":"finalText","text":"done"}"#
        XCTAssertEqual(ToolAgentModelActionValidator.normalizedForRun(finish), finish)
    }

    func testAFencedRunActionIsUnfenced() {
        let fenced = "```json\n\(runAction)\n```"
        XCTAssertEqual(ToolAgentModelActionValidator.normalizedForRun(fenced), runAction)
    }

    /// A valid action with a JSON hedge glued after it — the dominant
    /// malformed shape, the model preemptively appending the finalText
    /// confirmation — is read deterministically as the action, costing no
    /// repair model call inside the run's own deadline.
    func testAGluedFinalTextTrailerIsDroppedDeterministically() {
        let glued = runAction + #"{"version":1,"action":"finalText","text":"done"}"#
        XCTAssertEqual(ToolAgentModelActionValidator.normalizedForRun(glued), runAction)
        // A quoted brace inside the Python source must not end the scan early.
        let braced =
            #"{"version":1,"action":"toolCall","name":"run_python","arguments":{"source":"print('}')","purpose":"p"}}"#
        XCTAssertEqual(
            ToolAgentModelActionValidator.normalizedForRun(
                braced + #"{"version":1,"action":"finalText","text":"done"}"#
            ),
            braced
        )
    }

    /// Prose after the object is not a hedge — that still goes to the repair
    /// turn rather than being silently truncated.
    func testAnActionFollowedByProseIsNotARunAction() {
        XCTAssertNil(ToolAgentModelActionValidator.normalizedForRun(runAction + "\nDone!"))
    }

    func testABuildToolNameIsNotARunAction() {
        let build = #"{"version":1,"action":"toolCall","name":"write_candidate","arguments":{}}"#
        XCTAssertNil(ToolAgentModelActionValidator.normalizedForRun(build))
    }
}

final class AgentToolCandidateTests: XCTestCase {
    private func agentCandidate(
        prompt: String = "Work out what the link is and answer accordingly.",
        fixtures: [ToolAgentFixtureV1] = [],
        maxSteps: Int = 8,
        timeoutSeconds: Int = 120,
        output: ToolAgentCandidateOutputV1 = .panel,
        source: String = ""
    ) throws -> ToolAgentCandidateV1 {
        try ToolAgentCandidateV1(
            kind: .agent,
            name: "Triage",
            brief: "Reads a link and answers in kind.",
            symbolName: "sparkles",
            input: .selection,
            output: output,
            trigger: .always,
            prompt: prompt,
            source: source,
            fixtures: fixtures,
            timeoutSeconds: timeoutSeconds,
            maxSteps: maxSteps
        )
    }

    func testAgentCandidateRoundTrips() throws {
        let candidate = try agentCandidate(
            fixtures: [ToolAgentFixtureV1(input: "https://example.com")]
        )
        let data = try ToolAgentCanonicalJSONV1.encode(candidate)
        let decoded = try JSONDecoder().decode(ToolAgentCandidateV1.self, from: data)
        XCTAssertEqual(decoded, candidate)
        // Same byte-identical re-encoding `ToolAgentModelActionValidator` demands.
        XCTAssertEqual(try ToolAgentCanonicalJSONV1.encode(decoded), data)
    }

    /// An agent's wording cannot be predicted, so a fixture that claims to know
    /// it would fail every build on phrasing rather than on behavior.
    func testAgentFixtureCannotCarryAnExpectedOutput() {
        XCTAssertThrowsError(
            try agentCandidate(fixtures: [
                ToolAgentFixtureV1(input: "https://example.com", expectedOutput: "a summary")
            ])
        )
    }

    func testAgentCandidateTakesAtMostOneFixture() {
        XCTAssertThrowsError(
            try agentCandidate(fixtures: [
                ToolAgentFixtureV1(input: "https://example.com"),
                ToolAgentFixtureV1(input: "https://example.org"),
            ])
        )
    }

    func testAgentCandidateRejectsBoundsItCannotHonour() {
        XCTAssertThrowsError(try agentCandidate(maxSteps: 0))
        XCTAssertThrowsError(try agentCandidate(maxSteps: 25))
        // The whole run has to fit a wall clock the user can wait out.
        XCTAssertThrowsError(try agentCandidate(timeoutSeconds: 5))
        XCTAssertThrowsError(try agentCandidate(timeoutSeconds: 1_800))
    }

    /// An agent writes its own code, so a candidate that also ships source has
    /// misunderstood the kind — and files are not something it can produce.
    func testAgentCandidateRejectsScriptAndFileOutput() {
        XCTAssertThrowsError(try agentCandidate(source: "print('hi')"))
        XCTAssertThrowsError(try agentCandidate(output: .files))
    }

    func testAgentCandidateNeedsAnInstruction() {
        XCTAssertThrowsError(try agentCandidate(prompt: ""))
    }
}

@MainActor
final class AgentToolApprovalTests: XCTestCase {
    private func makeStore() throws -> ToolsStore {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "gizmate-agent-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ToolsStore(directoryURL: directory, migrateLegacy: false)
    }

    private func agentTool() -> GizmateTool {
        GizmateTool(
            name: "Triage",
            kind: .agent,
            input: .selection,
            output: .panel,
            prompt: "Read the link and answer accordingly.",
            brief: "Reads a link."
        )
    }

    /// An agent tool has no code to hash, so its approval covers the three
    /// things that decide what it may do. Each of them changing has to ask
    /// again — otherwise editing the instruction is a silent grant.
    func testApprovalHashCoversInstructionStepsAndSecrets() throws {
        let store = try makeStore()
        var tool = agentTool()
        store.save(tool)
        let original = try XCTUnwrap(store.approvalHash(for: tool))

        tool.prompt += " Be brief."
        XCTAssertNotEqual(store.approvalHash(for: tool), original)

        tool = agentTool()
        tool.maxSteps = 12
        XCTAssertNotEqual(store.approvalHash(for: tool), original)

        tool = agentTool()
        tool.secretNames = ["OPENAI_API_KEY"]
        XCTAssertNotEqual(store.approvalHash(for: tool), original)

        // Same tool, same everything: the user is not asked twice.
        XCTAssertEqual(store.approvalHash(for: agentTool()), original)
    }

    /// A prompt or native tool executes nothing arbitrary, so there is nothing
    /// to approve and no dialog to show.
    func testKindsWithNothingToApproveHaveNoHash() throws {
        let store = try makeStore()
        XCTAssertNil(store.approvalHash(for: GizmateTool(name: "Fix", kind: .prompt, prompt: "Fix it.")))
        XCTAssertNil(store.approvalHash(for: GizmateTool(name: "Open", kind: .native, target: "Safari")))
    }

    func testAgentToolIsRunnableWithoutAScript() throws {
        let store = try makeStore()
        let tool = agentTool()
        store.save(tool)
        XCTAssertTrue(store.isRunnable(tool))
        XCTAssertTrue(tool.isUsable)
        // An instruction is the whole tool; without one there is nothing to run.
        var empty = tool
        empty.prompt = ""
        XCTAssertFalse(empty.isUsable)
    }

    /// Manifests written before agent tools existed have to keep working, and
    /// land on bounds the runner will accept.
    func testLegacyManifestDecodesWithUsableAgentDefaults() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Old","kind":"python"}
        """
        let tool = try JSONDecoder().decode(GizmateTool.self, from: Data(json.utf8))
        XCTAssertEqual(tool.maxSteps, 8)
        XCTAssertEqual(tool.secretNames, [])
    }

    func testAbsurdStepCountsAreClampedOnDecode() throws {
        for (stored, expected) in [(0, 1), (500, 24)] {
            let json = """
            {"id":"\(UUID().uuidString)","name":"Odd","kind":"agent","maxSteps":\(stored)}
            """
            let tool = try JSONDecoder().decode(GizmateTool.self, from: Data(json.utf8))
            XCTAssertEqual(tool.maxSteps, expected)
        }
    }
}
