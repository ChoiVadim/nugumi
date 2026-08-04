import Foundation

public enum ToolAgentProtocolLimitsV1 {
    public static let maximumFrameBytes = 1_024 * 1_024
    public static let maximumCandidateEncodedBytes = 900 * 1_024
    public static let maximumNameBytes = 128
    public static let maximumBriefBytes = 1_024
    public static let maximumSymbolNameBytes = 128
    public static let maximumPromptBytes = 16 * 1_024
    public static let maximumTargetBytes = 8 * 1_024
    public static let maximumSourceBytes = 64 * 1_024
    public static let maximumFixtureInputBytes = 8 * 1_024
    public static let maximumFixtureOutputBytes = 16 * 1_024
    public static let maximumDiagnosticBytes = 16 * 1_024
    public static let maximumFixtureCount = 3
    /// A tool that claims it needs eight different credentials has misunderstood
    /// the request, not found a use case.
    public static let maximumSecretNameCount = 8
    public static let maximumSecretNameBytes = 64
    /// Mirrors LIMITS.optionCount / LIMITS.optionBytes in protocol.ts. Five is
    /// what the outer orbit fans cleanly; two is the smallest real choice.
    public static let maximumOptionCount = 5
    public static let minimumOptionCount = 2
    public static let maximumOptionBytes = 64
    public static let maximumFilterCount = 16
    public static let maximumFilterValueBytes = 255
    public static let maximumSafeMessageBytes = 1_024
}

public enum ToolAgentFailureCodeV1: String, Codable, CaseIterable, Equatable, Error, Sendable {
    case invalidProtocol
    case invalidModelAction
    case invalidCandidate
    case syntaxError
    case runtimeError
    case invalidOutput
    case wrongOutput
    case timedOut
    case outputLimit
    case cancelled
    case workerFailure
    case budgetExhausted
    case attestationFailed
}

public enum ToolAgentBuildStateV1: String, Codable, CaseIterable, Equatable, Sendable {
    case created
    case understanding
    case writing
    case testing
    case diagnosing
    case repairing
    case verifying
    case candidateReady
    case failed
    case cancelled
    case budgetExhausted
}

/// How much a passing validation actually proves.
///
/// Validation used to be one bit, and the bit meant "reproduced an exact
/// string". Tools that talk to the network, write files, or read the clock can
/// never earn that bit, so the agent was forbidden from writing them at all.
/// Grading the proof instead of demanding the strongest one lets those tools
/// exist, as long as Gizmate says plainly which grade a tool earned.
public enum ToolAgentAssuranceV1: String, Codable, CaseIterable, Equatable, Sendable {
    /// Ran on every fixture and matched the expected output exactly.
    case verified
    /// Ran on real input and survived: exit 0, and any promised file appeared.
    case smoke
    /// Never executed. The source compiles and its dependencies resolve.
    case unverified
}

public struct ToolAgentFixtureV1: Codable, Equatable, Sendable {
    public let input: String
    /// Supplied only when the tool is deterministic enough that an exact string
    /// is a fair test. A fixture without one is a smoke run: the candidate has
    /// to survive real input, not reproduce a byte-exact answer. Most useful
    /// tools — anything touching the network, the clock, or the filesystem —
    /// can only be checked that way.
    public let expectedOutput: String?

    public init(input: String, expectedOutput: String? = nil) {
        self.input = input
        self.expectedOutput = expectedOutput
    }
}

public struct ToolAgentAskUserRequestV1: Codable, Equatable, Sendable {
    public let question: String

    public init(question: String) throws {
        guard !question.isEmpty,
              question.utf8.count <= ToolAgentProtocolLimitsV1.maximumSafeMessageBytes else {
            throw ToolAgentFailureCodeV1.invalidProtocol
        }
        self.question = question
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ToolAgentDynamicCodingKeyV1.self)
        guard Set(container.allKeys.map(\.stringValue)) == Set(["question"]) else {
            throw ToolAgentFailureCodeV1.invalidProtocol
        }
        try self.init(question: container.decode(String.self, forKey: .required("question")))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(question, forKey: .question)
    }

    private enum CodingKeys: String, CodingKey { case question }
}

public struct ToolAgentAskUserResponseV1: Codable, Equatable, Sendable {
    public let answer: String

    public init(answer: String) throws {
        guard !answer.isEmpty,
              answer.utf8.count <= ToolAgentProtocolLimitsV1.maximumSafeMessageBytes else {
            throw ToolAgentFailureCodeV1.invalidProtocol
        }
        self.answer = answer
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ToolAgentDynamicCodingKeyV1.self)
        guard Set(container.allKeys.map(\.stringValue)) == Set(["answer"]) else {
            throw ToolAgentFailureCodeV1.invalidProtocol
        }
        try self.init(answer: container.decode(String.self, forKey: .required("answer")))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(answer, forKey: .answer)
    }

    private enum CodingKeys: String, CodingKey { case answer }
}

public enum ToolAgentCandidateKindV1: String, Codable, Equatable, Sendable {
    case prompt
    case native
    case python
    /// An instruction carried out at run time by an agent that writes and runs
    /// its own Python. Unlike the other three, what it will actually do is not
    /// decided until the user presses the button.
    case agent
}

public enum ToolAgentOperationV1: String, Codable, CaseIterable, Equatable, Sendable {
    case create
    case edit
    case fix
}

public enum ToolAgentCandidateInputV1: String, Codable, Equatable, Sendable {
    case selection
    /// The user types the tool's input into a capsule when it runs; the tool is
    /// handed exactly that text, in the slot a selection would occupy.
    case ask
    /// The same slot again, spoken instead of typed: the user talks while the
    /// tool runs and it is handed the transcript.
    case dictation
    /// The files selected in Finder. One argument per file.
    case files
    /// The user drags out a screen area when the tool runs; the tool is handed
    /// the path to the captured PNG.
    case screenshot
    /// The same drag, read by Vision; the tool is handed the recognised text.
    case screenshotText
    /// The whole screen with the user's own marks drawn on it.
    case drawnScreen
    case none
}

public enum ToolAgentCandidateOutputV1: String, Codable, Equatable, Sendable {
    case panel
    case replace
    case clipboard
    case files
    case notify
    /// Kept as a new note in Gizmate's own Notes tab, titled with the gizmo.
    case notes
    /// Read out loud instead of shown.
    case speak
    /// Drawn over the screen as shapes instead of shown as text.
    case annotate

    /// What a `.native` tool can actually deliver — exactly the cases its runner
    /// switches on, plus the toast every other case already falls through to.
    ///
    /// The editor offers a native gizmo the same set, so a tool the user saved
    /// by hand round-trips through an edit session instead of throwing
    /// `invalidCandidate` on the way in. Left out: `.panel` and `.annotate`,
    /// which need a model to produce something a fixed macOS action has no way
    /// to produce, and `.files`, which needs a script that wrote some.
    public static let nativeDeliverable: Set<ToolAgentCandidateOutputV1> = [
        .replace, .clipboard, .notify, .notes, .speak
    ]
}

public enum ToolAgentCandidateTriggerV1: String, Codable, Equatable, Sendable {
    case always
    case selection
    case files
}
