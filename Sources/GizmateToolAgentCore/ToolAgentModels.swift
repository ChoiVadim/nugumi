import CryptoKit
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
    case clipboardText
    case clipboardURL
    case files
    /// The user drags out a screen area when the tool runs; the tool is handed
    /// the path to the captured PNG.
    case screenshot
    /// The same drag, read by Vision; the tool is handed the recognised text.
    case screenshotText
    case none
}

public enum ToolAgentCandidateOutputV1: String, Codable, Equatable, Sendable {
    case panel
    case replace
    case clipboard
    case files
    case notify
}

public enum ToolAgentCandidateTriggerV1: String, Codable, Equatable, Sendable {
    case always
    case selection
    case link
    case files
}

public enum ToolAgentNativeActionV1: String, Codable, Equatable, Sendable {
    case openApp
    case openAppFullScreen
    case sendTextToApp
    case revealInFinder
    case openURL
    case runShortcut

    fileprivate var needsTarget: Bool {
        self != .revealInFinder
    }
}

public struct ToolAgentCandidateV1: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: ToolAgentCandidateKindV1
    public let name: String
    public let brief: String
    public let symbolName: String
    public let input: ToolAgentCandidateInputV1
    public let output: ToolAgentCandidateOutputV1
    public let trigger: ToolAgentCandidateTriggerV1
    public let hosts: [String]
    public let extensions: [String]
    public let prompt: String
    public let appliesTargetLanguage: Bool
    public let nativeAction: ToolAgentNativeActionV1?
    public let target: String
    public let source: String
    public let fixtures: [ToolAgentFixtureV1]
    public let outputDirectory: String?
    public let timeoutSeconds: Int
    public let declaresNetwork: Bool
    /// Names of the user's stored secrets this tool asks to be handed, as
    /// environment variables. Names only — a value never crosses this protocol
    /// in either direction, so the model can write `os.environ["OPENAI_API_KEY"]`
    /// without ever being shown the key.
    ///
    /// Optional for the same reason `outputDirectory` is:
    /// `ToolAgentModelActionValidator` accepts a candidate by re-encoding it and
    /// comparing byte for byte against what the model sent, and a plain array
    /// cannot tell `"secretNames":[]` from an absent key — they decode to the
    /// same value and one of them would not survive the trip back. nil is
    /// "didn't say", `[]` is "said none", and both mean no secrets.
    public let secretNames: [String]?
    /// `.agent` only: how many scripts the agent may run before it must answer.
    public let maxSteps: Int

    public init(
        kind: ToolAgentCandidateKindV1,
        name: String,
        brief: String,
        symbolName: String,
        input: ToolAgentCandidateInputV1,
        output: ToolAgentCandidateOutputV1,
        trigger: ToolAgentCandidateTriggerV1,
        hosts: [String] = [],
        extensions: [String] = [],
        prompt: String = "",
        appliesTargetLanguage: Bool = false,
        nativeAction: ToolAgentNativeActionV1? = nil,
        target: String = "",
        source: String = "",
        fixtures: [ToolAgentFixtureV1] = [],
        outputDirectory: String? = nil,
        timeoutSeconds: Int = 120,
        declaresNetwork: Bool = false,
        secretNames: [String]? = nil,
        maxSteps: Int = 8
    ) throws {
        try Self.validate(
            kind: kind,
            name: name,
            brief: brief,
            symbolName: symbolName,
            input: input,
            output: output,
            trigger: trigger,
            hosts: hosts,
            extensions: extensions,
            prompt: prompt,
            nativeAction: nativeAction,
            target: target,
            source: source,
            fixtures: fixtures,
            outputDirectory: outputDirectory,
            timeoutSeconds: timeoutSeconds,
            secretNames: secretNames,
            maxSteps: maxSteps
        )
        self.schemaVersion = 1
        self.kind = kind
        self.name = name
        self.brief = brief
        self.symbolName = symbolName
        self.input = input
        self.output = output
        self.trigger = trigger
        self.hosts = hosts
        self.extensions = extensions
        self.prompt = prompt
        self.appliesTargetLanguage = appliesTargetLanguage
        self.nativeAction = nativeAction
        self.target = target
        self.source = source
        self.fixtures = fixtures
        self.outputDirectory = outputDirectory
        self.timeoutSeconds = timeoutSeconds
        self.declaresNetwork = declaresNetwork
        self.secretNames = secretNames
        self.maxSteps = maxSteps
    }

    /// Keeps persisted phase-zero Python runs and existing protocol fixtures
    /// readable while the candidate contract grows to cover every Gizmate kind.
    public init(
        name: String,
        brief: String,
        symbolName: String,
        source: String,
        fixtures: [ToolAgentFixtureV1]
    ) throws {
        try self.init(
            kind: .python,
            name: name,
            brief: brief,
            symbolName: symbolName,
            input: .clipboardText,
            output: .clipboard,
            trigger: .always,
            source: source,
            fixtures: fixtures,
            timeoutSeconds: 30
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let kind = try container.decodeIfPresent(
            ToolAgentCandidateKindV1.self,
            forKey: .kind
        ) ?? .python
        let name = try container.decode(String.self, forKey: .name)
        let brief = try container.decode(String.self, forKey: .brief)
        let symbolName = try container.decode(String.self, forKey: .symbolName)
        let input = try container.decodeIfPresent(
            ToolAgentCandidateInputV1.self,
            forKey: .input
        ) ?? .clipboardText
        let output = try container.decodeIfPresent(
            ToolAgentCandidateOutputV1.self,
            forKey: .output
        ) ?? .clipboard
        let trigger = try container.decodeIfPresent(
            ToolAgentCandidateTriggerV1.self,
            forKey: .trigger
        ) ?? .always
        let hosts = try container.decodeIfPresent([String].self, forKey: .hosts) ?? []
        let extensions = try container.decodeIfPresent([String].self, forKey: .extensions) ?? []
        let prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        let appliesTargetLanguage = try container.decodeIfPresent(
            Bool.self,
            forKey: .appliesTargetLanguage
        ) ?? false
        let nativeAction = try container.decodeIfPresent(
            ToolAgentNativeActionV1.self,
            forKey: .nativeAction
        )
        let target = try container.decodeIfPresent(String.self, forKey: .target) ?? ""
        let source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        let fixtures = try container.decodeIfPresent(
            [ToolAgentFixtureV1].self,
            forKey: .fixtures
        ) ?? []
        let outputDirectory = try container.decodeIfPresent(
            String.self,
            forKey: .outputDirectory
        )
        let timeoutSeconds = try container.decodeIfPresent(
            Int.self,
            forKey: .timeoutSeconds
        ) ?? (kind == .python ? 30 : 120)
        let declaresNetwork = try container.decodeIfPresent(
            Bool.self,
            forKey: .declaresNetwork
        ) ?? false
        let secretNames = try container.decodeIfPresent(
            [String].self,
            forKey: .secretNames
        )
        let maxSteps = try container.decodeIfPresent(Int.self, forKey: .maxSteps) ?? 8
        guard schemaVersion == 1 else {
            throw ToolAgentFailureCodeV1.invalidCandidate
        }
        try Self.validate(
            kind: kind,
            name: name,
            brief: brief,
            symbolName: symbolName,
            input: input,
            output: output,
            trigger: trigger,
            hosts: hosts,
            extensions: extensions,
            prompt: prompt,
            nativeAction: nativeAction,
            target: target,
            source: source,
            fixtures: fixtures,
            outputDirectory: outputDirectory,
            timeoutSeconds: timeoutSeconds,
            secretNames: secretNames,
            maxSteps: maxSteps
        )
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.name = name
        self.brief = brief
        self.symbolName = symbolName
        self.input = input
        self.output = output
        self.trigger = trigger
        self.hosts = hosts
        self.extensions = extensions
        self.prompt = prompt
        self.appliesTargetLanguage = appliesTargetLanguage
        self.nativeAction = nativeAction
        self.target = target
        self.source = source
        self.fixtures = fixtures
        self.outputDirectory = outputDirectory
        self.timeoutSeconds = timeoutSeconds
        self.declaresNetwork = declaresNetwork
        self.secretNames = secretNames
        self.maxSteps = maxSteps
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(brief, forKey: .brief)
        try container.encode(symbolName, forKey: .symbolName)
        try container.encode(input, forKey: .input)
        try container.encode(output, forKey: .output)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(hosts, forKey: .hosts)
        try container.encode(extensions, forKey: .extensions)
        switch kind {
        case .prompt:
            try container.encode(prompt, forKey: .prompt)
            try container.encode(appliesTargetLanguage, forKey: .appliesTargetLanguage)
        case .native:
            try container.encode(nativeAction, forKey: .nativeAction)
            try container.encode(target, forKey: .target)
        case .python:
            try container.encode(source, forKey: .source)
            try container.encode(fixtures, forKey: .fixtures)
            try container.encodeIfPresent(outputDirectory, forKey: .outputDirectory)
            try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
            try container.encode(declaresNetwork, forKey: .declaresNetwork)
            // Omitted when empty, not written as `[]`. `ToolAgentModelActionValidator`
            // accepts a candidate by re-encoding it and comparing byte for byte
            // against what the model sent, so a key the model had no reason to
            // write must not appear on the way back — and a tool with no secrets
            // keeps the exact fingerprint it had before secrets existed.
            try container.encodeIfPresent(secretNames, forKey: .secretNames)
        case .agent:
            try container.encode(prompt, forKey: .prompt)
            try container.encode(fixtures, forKey: .fixtures)
            try container.encode(maxSteps, forKey: .maxSteps)
            try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
            try container.encodeIfPresent(secretNames, forKey: .secretNames)
        }
    }

    private static func validate(
        kind: ToolAgentCandidateKindV1,
        name: String,
        brief: String,
        symbolName: String,
        input: ToolAgentCandidateInputV1,
        output: ToolAgentCandidateOutputV1,
        trigger: ToolAgentCandidateTriggerV1,
        hosts: [String],
        extensions: [String],
        prompt: String,
        nativeAction: ToolAgentNativeActionV1?,
        target: String,
        source: String,
        fixtures: [ToolAgentFixtureV1],
        outputDirectory: String?,
        timeoutSeconds: Int,
        secretNames: [String]?,
        maxSteps: Int
    ) throws {
        // nil and [] both mean "no secrets". Only the wire format tells them
        // apart, and that distinction is the encoder's business, not this one's.
        let declared = secretNames ?? []
        guard !name.isEmpty,
              !brief.isEmpty,
              !symbolName.isEmpty,
              name.utf8.count <= ToolAgentProtocolLimitsV1.maximumNameBytes,
              brief.utf8.count <= ToolAgentProtocolLimitsV1.maximumBriefBytes,
              symbolName.utf8.count <= ToolAgentProtocolLimitsV1.maximumSymbolNameBytes,
              hosts.count <= ToolAgentProtocolLimitsV1.maximumFilterCount,
              extensions.count <= ToolAgentProtocolLimitsV1.maximumFilterCount,
              (hosts + extensions).allSatisfy({
                  !$0.isEmpty
                      && $0.utf8.count <= ToolAgentProtocolLimitsV1.maximumFilterValueBytes
              }),
              fixtures.allSatisfy({
                  !$0.input.isEmpty
                      && $0.input.utf8.count <= ToolAgentProtocolLimitsV1.maximumFixtureInputBytes
                      && $0.expectedOutput.map({
                          $0.utf8.count <= ToolAgentProtocolLimitsV1.maximumFixtureOutputBytes
                      }) ?? true
              }),
              // Shape is not checked here — the alphabet is enforced where it
              // actually matters, in `ToolSecrets`, which resolves these into a
              // path and refuses anything that could leave its directory.
              declared.count <= ToolAgentProtocolLimitsV1.maximumSecretNameCount,
              Set(declared).count == declared.count,
              declared.allSatisfy({
                  !$0.isEmpty
                      && $0.utf8.count <= ToolAgentProtocolLimitsV1.maximumSecretNameBytes
              }),
              trigger != .link || input == .clipboardURL,
              trigger != .files || input == .files,
              trigger != .selection || input == .selection else {
            throw ToolAgentFailureCodeV1.invalidCandidate
        }

        switch kind {
        case .prompt:
            // Only a Python tool reads a process environment, so a prompt or
            // native candidate that declares secrets has misunderstood what it
            // is building rather than found a way to use one.
            // Three ways for text the user is looking at to arrive: selected,
            // read off the screen by Vision, or typed when the tool runs. The
            // sidecar's schema and the capability description have always
            // offered all three; this guard used to accept only the first, so a
            // screenshotText prompt candidate — which the model was explicitly
            // told to write — came back as invalidCandidate.
            guard input == .selection || input == .ask || input == .screenshotText,
                  output != .files,
                  output != .notify,
                  !prompt.isEmpty,
                  prompt.utf8.count <= ToolAgentProtocolLimitsV1.maximumPromptBytes,
                  nativeAction == nil,
                  target.isEmpty,
                  source.isEmpty,
                  fixtures.isEmpty,
                  declared.isEmpty,
                  outputDirectory == nil else {
                throw ToolAgentFailureCodeV1.invalidCandidate
            }
        case .native:
            guard let nativeAction,
                  output == .replace || output == .clipboard || output == .notify,
                  prompt.isEmpty,
                  source.isEmpty,
                  fixtures.isEmpty,
                  declared.isEmpty,
                  outputDirectory == nil,
                  target.utf8.count <= ToolAgentProtocolLimitsV1.maximumTargetBytes,
                  !nativeAction.needsTarget || !target.isEmpty else {
                throw ToolAgentFailureCodeV1.invalidCandidate
            }
        case .python:
            // Zero fixtures is legal. A tool whose whole point is a real side
            // effect — sending mail, moving the user's files — cannot be run
            // during validation without doing the thing, so it is checked by
            // compiling it and resolving its dependencies instead. Demanding a
            // fixture there is what forced every earlier candidate to be a pure
            // text transform.
            guard !source.isEmpty,
                  source.utf8.count <= ToolAgentProtocolLimitsV1.maximumSourceBytes,
                  fixtures.count <= ToolAgentProtocolLimitsV1.maximumFixtureCount,
                  prompt.isEmpty,
                  nativeAction == nil,
                  target.isEmpty,
                  outputDirectory.map({
                      !$0.isEmpty
                          && $0.utf8.count <= ToolAgentProtocolLimitsV1.maximumTargetBytes
                  }) ?? true,
                  (5...1_800).contains(timeoutSeconds),
                  output != .files || outputDirectory != nil else {
                throw ToolAgentFailureCodeV1.invalidCandidate
            }
        case .agent:
            // An agent tool is its instruction plus its bounds: no source,
            // because it writes its own at run time, and no file output, because
            // it finishes with text.
            //
            // Fixtures mean here what they mean for Python, with the same
            // choice behind them: at most one, as the input a harmless trial run
            // should use, and none at all when actually running the tool would
            // do something to the user's data or to the outside world. An
            // expected output is never allowed — an agent's answer is not
            // predictable, and pretending otherwise would make every build fail
            // on wording.
            guard !prompt.isEmpty,
                  prompt.utf8.count <= ToolAgentProtocolLimitsV1.maximumPromptBytes,
                  output != .files,
                  nativeAction == nil,
                  target.isEmpty,
                  source.isEmpty,
                  fixtures.count <= 1,
                  fixtures.allSatisfy({ $0.expectedOutput == nil }),
                  outputDirectory == nil,
                  (1...24).contains(maxSteps),
                  (15...900).contains(timeoutSeconds) else {
                throw ToolAgentFailureCodeV1.invalidCandidate
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case kind
        case name
        case brief
        case symbolName
        case input
        case output
        case trigger
        case hosts
        case extensions
        case prompt
        case appliesTargetLanguage
        case nativeAction
        case target
        case source
        case fixtures
        case outputDirectory
        case timeoutSeconds
        case declaresNetwork
        case secretNames
        case maxSteps
    }
}

/// A complete, bounded installed-tool snapshot supplied only when Pi is
/// revising an existing tool. Unlike a candidate, Python fixtures are omitted:
/// they are not stored with installed tools and must never be invented merely
/// to construct editing context.
public struct ToolAgentInstalledToolV1: Codable, Equatable, Sendable {
    public let kind: ToolAgentCandidateKindV1
    public let name: String
    public let brief: String
    public let symbolName: String
    public let input: ToolAgentCandidateInputV1
    public let output: ToolAgentCandidateOutputV1
    public let trigger: ToolAgentCandidateTriggerV1
    public let hosts: [String]
    public let extensions: [String]
    public let prompt: String
    public let appliesTargetLanguage: Bool
    public let nativeAction: ToolAgentNativeActionV1?
    public let target: String
    public let source: String
    public let outputDirectory: String?
    public let timeoutSeconds: Int
    public let declaresNetwork: Bool
    /// Which secrets the installed tool already reads, so an edit can keep them
    /// rather than silently dropping the tool's credentials. Names only.
    public let secretNames: [String]
    /// `.agent` only, and preserved across an edit for the same reason.
    public let maxSteps: Int

    public init(
        kind: ToolAgentCandidateKindV1,
        name: String,
        brief: String,
        symbolName: String,
        input: ToolAgentCandidateInputV1,
        output: ToolAgentCandidateOutputV1,
        trigger: ToolAgentCandidateTriggerV1,
        hosts: [String] = [],
        extensions: [String] = [],
        prompt: String = "",
        appliesTargetLanguage: Bool = false,
        nativeAction: ToolAgentNativeActionV1? = nil,
        target: String = "",
        source: String = "",
        outputDirectory: String? = nil,
        timeoutSeconds: Int = 120,
        declaresNetwork: Bool = false,
        secretNames: [String] = [],
        maxSteps: Int = 8
    ) throws {
        try Self.validate(
            kind: kind,
            name: name,
            brief: brief,
            symbolName: symbolName,
            input: input,
            output: output,
            trigger: trigger,
            hosts: hosts,
            extensions: extensions,
            prompt: prompt,
            appliesTargetLanguage: appliesTargetLanguage,
            nativeAction: nativeAction,
            target: target,
            source: source,
            outputDirectory: outputDirectory,
            timeoutSeconds: timeoutSeconds,
            declaresNetwork: declaresNetwork,
            secretNames: secretNames,
            maxSteps: maxSteps
        )
        self.kind = kind
        self.name = name
        self.brief = brief
        self.symbolName = symbolName
        self.input = input
        self.output = output
        self.trigger = trigger
        self.hosts = hosts
        self.extensions = extensions
        self.prompt = prompt
        self.appliesTargetLanguage = appliesTargetLanguage
        self.nativeAction = nativeAction
        self.target = target
        self.source = source
        self.outputDirectory = outputDirectory
        self.timeoutSeconds = timeoutSeconds
        self.declaresNetwork = declaresNetwork
        self.secretNames = secretNames
        self.maxSteps = maxSteps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: try container.decode(ToolAgentCandidateKindV1.self, forKey: .kind),
            name: try container.decode(String.self, forKey: .name),
            brief: try container.decode(String.self, forKey: .brief),
            symbolName: try container.decode(String.self, forKey: .symbolName),
            input: try container.decode(ToolAgentCandidateInputV1.self, forKey: .input),
            output: try container.decode(ToolAgentCandidateOutputV1.self, forKey: .output),
            trigger: try container.decode(ToolAgentCandidateTriggerV1.self, forKey: .trigger),
            hosts: try container.decodeIfPresent([String].self, forKey: .hosts) ?? [],
            extensions: try container.decodeIfPresent([String].self, forKey: .extensions) ?? [],
            prompt: try container.decodeIfPresent(String.self, forKey: .prompt) ?? "",
            appliesTargetLanguage: try container.decodeIfPresent(Bool.self, forKey: .appliesTargetLanguage) ?? false,
            nativeAction: try container.decodeIfPresent(ToolAgentNativeActionV1.self, forKey: .nativeAction),
            target: try container.decodeIfPresent(String.self, forKey: .target) ?? "",
            source: try container.decodeIfPresent(String.self, forKey: .source) ?? "",
            outputDirectory: try container.decodeIfPresent(String.self, forKey: .outputDirectory),
            timeoutSeconds: try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
                ?? (try container.decode(ToolAgentCandidateKindV1.self, forKey: .kind) == .python ? 30 : 120),
            declaresNetwork: try container.decodeIfPresent(Bool.self, forKey: .declaresNetwork) ?? false,
            secretNames: try container.decodeIfPresent([String].self, forKey: .secretNames) ?? [],
            maxSteps: try container.decodeIfPresent(Int.self, forKey: .maxSteps) ?? 8
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(brief, forKey: .brief)
        try container.encode(symbolName, forKey: .symbolName)
        try container.encode(input, forKey: .input)
        try container.encode(output, forKey: .output)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(hosts, forKey: .hosts)
        try container.encode(extensions, forKey: .extensions)
        switch kind {
        case .prompt:
            try container.encode(prompt, forKey: .prompt)
            try container.encode(appliesTargetLanguage, forKey: .appliesTargetLanguage)
        case .native:
            try container.encode(nativeAction, forKey: .nativeAction)
            try container.encode(target, forKey: .target)
        case .python:
            try container.encode(source, forKey: .source)
            try container.encodeIfPresent(outputDirectory, forKey: .outputDirectory)
            try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
            try container.encode(declaresNetwork, forKey: .declaresNetwork)
            // Same as the candidate: absent rather than `[]`, so a tool with no
            // secrets serialises exactly as it did before this field existed.
            if !secretNames.isEmpty {
                try container.encode(secretNames, forKey: .secretNames)
            }
        case .agent:
            try container.encode(prompt, forKey: .prompt)
            try container.encode(maxSteps, forKey: .maxSteps)
            try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
            if !secretNames.isEmpty {
                try container.encode(secretNames, forKey: .secretNames)
            }
        }
    }

    private static func validate(
        kind: ToolAgentCandidateKindV1,
        name: String,
        brief: String,
        symbolName: String,
        input: ToolAgentCandidateInputV1,
        output: ToolAgentCandidateOutputV1,
        trigger: ToolAgentCandidateTriggerV1,
        hosts: [String],
        extensions: [String],
        prompt: String,
        appliesTargetLanguage: Bool,
        nativeAction: ToolAgentNativeActionV1?,
        target: String,
        source: String,
        outputDirectory: String?,
        timeoutSeconds: Int,
        declaresNetwork: Bool,
        secretNames: [String],
        maxSteps: Int
    ) throws {
        guard !name.isEmpty,
              !symbolName.isEmpty,
              name.utf8.count <= ToolAgentProtocolLimitsV1.maximumNameBytes,
              brief.utf8.count <= ToolAgentProtocolLimitsV1.maximumBriefBytes,
              symbolName.utf8.count <= ToolAgentProtocolLimitsV1.maximumSymbolNameBytes,
              hosts.count <= ToolAgentProtocolLimitsV1.maximumFilterCount,
              extensions.count <= ToolAgentProtocolLimitsV1.maximumFilterCount,
              (hosts + extensions).allSatisfy({
                  !$0.isEmpty
                      && $0.utf8.count <= ToolAgentProtocolLimitsV1.maximumFilterValueBytes
              }),
              secretNames.count <= ToolAgentProtocolLimitsV1.maximumSecretNameCount,
              Set(secretNames).count == secretNames.count,
              secretNames.allSatisfy({
                  !$0.isEmpty
                      && $0.utf8.count <= ToolAgentProtocolLimitsV1.maximumSecretNameBytes
              }),
              trigger != .link || input == .clipboardURL,
              trigger != .files || input == .files,
              trigger != .selection || input == .selection else {
            throw ToolAgentFailureCodeV1.invalidCandidate
        }

        switch kind {
        case .prompt:
            // Three ways for text the user is looking at to arrive: selected,
            // read off the screen by Vision, or typed when the tool runs. The
            // sidecar's schema and the capability description have always
            // offered all three; this guard used to accept only the first, so a
            // screenshotText prompt candidate — which the model was explicitly
            // told to write — came back as invalidCandidate.
            guard input == .selection || input == .ask || input == .screenshotText,
                  output != .files,
                  output != .notify,
                  !prompt.isEmpty,
                  prompt.utf8.count <= ToolAgentProtocolLimitsV1.maximumPromptBytes,
                  nativeAction == nil,
                  target.isEmpty,
                  source.isEmpty,
                  secretNames.isEmpty,
                  outputDirectory == nil,
                  timeoutSeconds == 120,
                  !declaresNetwork else {
                throw ToolAgentFailureCodeV1.invalidCandidate
            }
        case .native:
            guard let nativeAction,
                  output == .replace || output == .clipboard || output == .notify,
                  prompt.isEmpty,
                  !appliesTargetLanguage,
                  source.isEmpty,
                  secretNames.isEmpty,
                  outputDirectory == nil,
                  timeoutSeconds == 120,
                  !declaresNetwork,
                  target.utf8.count <= ToolAgentProtocolLimitsV1.maximumTargetBytes,
                  !nativeAction.needsTarget || !target.isEmpty else {
                throw ToolAgentFailureCodeV1.invalidCandidate
            }
        case .python:
            guard !source.isEmpty,
                  source.utf8.count <= ToolAgentProtocolLimitsV1.maximumSourceBytes,
                  prompt.isEmpty,
                  !appliesTargetLanguage,
                  nativeAction == nil,
                  target.isEmpty,
                  outputDirectory.map({
                      !$0.isEmpty
                          && $0.utf8.count <= ToolAgentProtocolLimitsV1.maximumTargetBytes
                  }) ?? true,
                  (5...1_800).contains(timeoutSeconds),
                  output != .files || outputDirectory != nil else {
                throw ToolAgentFailureCodeV1.invalidCandidate
            }
        case .agent:
            guard !prompt.isEmpty,
                  prompt.utf8.count <= ToolAgentProtocolLimitsV1.maximumPromptBytes,
                  output != .files,
                  !appliesTargetLanguage,
                  nativeAction == nil,
                  target.isEmpty,
                  source.isEmpty,
                  outputDirectory == nil,
                  (1...24).contains(maxSteps),
                  (15...900).contains(timeoutSeconds) else {
                throw ToolAgentFailureCodeV1.invalidCandidate
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case name
        case brief
        case symbolName
        case input
        case output
        case trigger
        case hosts
        case extensions
        case prompt
        case appliesTargetLanguage
        case nativeAction
        case target
        case source
        case outputDirectory
        case timeoutSeconds
        case declaresNetwork
        case secretNames
        case maxSteps
    }
}

public enum ToolAgentRequestContractV1 {
    public static func validate(
        operation: ToolAgentOperationV1,
        currentTool: ToolAgentInstalledToolV1?,
        failure: String?
    ) throws {
        guard failure.map({ !$0.isEmpty && $0.utf8.count <= ToolAgentProtocolLimitsV1.maximumDiagnosticBytes }) ?? true else {
            throw ToolAgentFailureCodeV1.invalidProtocol
        }

        switch operation {
        case .create:
            guard currentTool == nil, failure == nil else {
                throw ToolAgentFailureCodeV1.invalidProtocol
            }
        case .edit:
            guard currentTool != nil, failure == nil else {
                throw ToolAgentFailureCodeV1.invalidProtocol
            }
        case .fix:
            guard currentTool != nil, failure != nil else {
                throw ToolAgentFailureCodeV1.invalidProtocol
            }
        }
    }
}

public struct ToolAgentFingerprintV1: Codable, Equatable, Hashable, Sendable {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }
}

public enum ToolAgentCanonicalJSONV1 {
    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

public enum ToolAgentCandidateFingerprintV1 {
    public static func make(
        candidate: ToolAgentCandidateV1,
        runtimeVersion: String,
        policyVersion: String
    ) throws -> ToolAgentFingerprintV1 {
        guard !runtimeVersion.isEmpty, !policyVersion.isEmpty else {
            throw ToolAgentFailureCodeV1.invalidCandidate
        }
        let canonical = try ToolAgentCanonicalJSONV1.encode(
            FingerprintInput(candidate: candidate, runtimeVersion: runtimeVersion, policyVersion: policyVersion)
        )
        let digest = SHA256.hash(data: canonical)
        return ToolAgentFingerprintV1(digest.map { String(format: "%02x", $0) }.joined())
    }

    private struct FingerprintInput: Codable {
        let candidate: ToolAgentCandidateV1
        let runtimeVersion: String
        let policyVersion: String
    }
}

public struct ToolAgentWriteCandidateRequestV1: Codable, Equatable, Sendable {
    public let candidate: ToolAgentCandidateV1

    public init(candidate: ToolAgentCandidateV1) {
        self.candidate = candidate
    }
}
