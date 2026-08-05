import Foundation

public enum ToolAgentNativeActionV1: String, Codable, Equatable, Sendable {
    case openApp
    case openAppFullScreen
    case sendTextToApp
    case revealInFinder
    case openURL
    case runShortcut
    case saveToNote

    fileprivate var needsTarget: Bool {
        self != .revealInFinder && self != .saveToNote
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
    /// Variants the finished gizmo offers, drawn as a second orbit behind its
    /// Ring button. Optional for the same reason `secretNames` is: the
    /// validator re-encodes a candidate and compares byte for byte, and a plain
    /// array cannot tell `"options":[]` from an absent key. nil is "didn't
    /// say", and a gizmo with no options keeps the fingerprint it always had.
    public let options: [String]?
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
    /// What a surface gizmo draws. Present exactly when `output == .surface`.
    ///
    /// Optional for the same reason `options` and `secretNames` are: the
    /// validator re-encodes a candidate and compares byte for byte, and an
    /// absent key must stay absent on the way back.
    public let layout: ToolAgentLayoutV1?

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
        options: [String]? = nil,
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
        maxSteps: Int = 8,
        layout: ToolAgentLayoutV1? = nil
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
            options: options,
            prompt: prompt,
            nativeAction: nativeAction,
            target: target,
            source: source,
            fixtures: fixtures,
            outputDirectory: outputDirectory,
            timeoutSeconds: timeoutSeconds,
            secretNames: secretNames,
            maxSteps: maxSteps,
            layout: layout
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
        self.options = options
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
        self.layout = layout
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
            input: .selection,
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
        ) ?? .selection
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
        let options = try container.decodeIfPresent([String].self, forKey: .options)
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
        let layout = try container.decodeIfPresent(ToolAgentLayoutV1.self, forKey: .layout)
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
            options: options,
            prompt: prompt,
            nativeAction: nativeAction,
            target: target,
            source: source,
            fixtures: fixtures,
            outputDirectory: outputDirectory,
            timeoutSeconds: timeoutSeconds,
            secretNames: secretNames,
            maxSteps: maxSteps,
            layout: layout
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
        self.options = options
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
        self.layout = layout
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
        try container.encodeIfPresent(options, forKey: .options)
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
            // Present only on a surface — `validate` rejects a layout on any
            // other output, so a non-surface Python tool never had one to omit.
            try container.encodeIfPresent(layout, forKey: .layout)
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
        options: [String]?,
        prompt: String,
        nativeAction: ToolAgentNativeActionV1?,
        target: String,
        source: String,
        fixtures: [ToolAgentFixtureV1],
        outputDirectory: String?,
        timeoutSeconds: Int,
        secretNames: [String]?,
        maxSteps: Int,
        layout: ToolAgentLayoutV1?
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
                  // "none" is the one input a fixture cannot supply a real
                  // value for — the script reads nothing, so an empty string
                  // is the honest fixture, not a missing one. Refusing it
                  // would make a "none"-input candidate — a surface among
                  // them — impossible to ever run-validate: it would be
                  // stuck choosing between a fixture the guard rejects and no
                  // fixture at all, which skips running the script entirely.
                  (input == .none || !$0.input.isEmpty)
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
              trigger != .files || input == .files,
              trigger != .selection || input == .selection else {
            throw ToolAgentFailureCodeV1.invalidCandidate
        }

        if let options {
            var seen = Set<String>()
            guard options.count >= ToolAgentProtocolLimitsV1.minimumOptionCount,
                  options.count <= ToolAgentProtocolLimitsV1.maximumOptionCount,
                  options.allSatisfy({
                      !$0.isEmpty
                          && $0.utf8.count <= ToolAgentProtocolLimitsV1.maximumOptionBytes
                          && seen.insert($0).inserted
                  })
            else {
                throw ToolAgentFailureCodeV1.invalidCandidate
            }
        }

        switch kind {
        case .prompt:
            // Only a Python tool reads a process environment, so a prompt or
            // native candidate that declares secrets has misunderstood what it
            // is building rather than found a way to use one.
            // Deliberately no input or output allowlist. This guard has now
            // twice been the thing that rejected a candidate the model was
            // explicitly told to write — first screenshotText, then
            // drawnScreen — because a new case was added to the enum, the
            // sidecar schema and the capability description while this list
            // stayed where it was. A prompt tool works on whatever it is
            // handed and its answer goes wherever the user said; the pairing
            // rules are guidance in the prompt, not a wall here, so a wrong
            // pairing produces a tool that disappoints rather than a build
            // that fails with nothing to point at.
            guard
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
                  ToolAgentCandidateOutputV1.nativeDeliverable.contains(output),
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
                  ToolAgentCandidateOutputV1.agentDeliverable.contains(output),
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

        // A surface is drawn by a script's stdout, never runs on demand, and
        // is handed nothing to act on — it sits on a screen edge showing
        // whatever it shows. Any other output must not carry a layout: the
        // field exists only to answer "what does the surface draw".
        if output == .surface {
            guard kind == .python else { throw ToolAgentFailureCodeV1.invalidCandidate }
            guard input == .none, trigger == .always else {
                throw ToolAgentFailureCodeV1.invalidCandidate
            }
            guard let layout, layout.isRepeater, !layout.containsNestedRepeater else {
                throw ToolAgentFailureCodeV1.invalidCandidate
            }
        } else if layout != nil {
            throw ToolAgentFailureCodeV1.invalidCandidate
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
        case options
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
        case layout
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
    /// Variants the finished gizmo offers, drawn as a second orbit behind its
    /// Ring button. Optional for the same reason `secretNames` is: the
    /// validator re-encodes a candidate and compares byte for byte, and a plain
    /// array cannot tell `"options":[]` from an absent key. nil is "didn't
    /// say", and a gizmo with no options keeps the fingerprint it always had.
    public let options: [String]?
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
    /// What an existing surface gizmo draws, carried into an edit session for
    /// the same reason `secretNames` is: without it, revising a surface gives
    /// the model no way to see its current layout, and it would have to
    /// invent a new one from scratch on every edit.
    public let layout: ToolAgentLayoutV1?

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
        options: [String]? = nil,
        prompt: String = "",
        appliesTargetLanguage: Bool = false,
        nativeAction: ToolAgentNativeActionV1? = nil,
        target: String = "",
        source: String = "",
        outputDirectory: String? = nil,
        timeoutSeconds: Int = 120,
        declaresNetwork: Bool = false,
        secretNames: [String] = [],
        maxSteps: Int = 8,
        layout: ToolAgentLayoutV1? = nil
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
            options: options,
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
        self.options = options
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
        self.layout = layout
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
            options: try container.decodeIfPresent([String].self, forKey: .options),
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
            maxSteps: try container.decodeIfPresent(Int.self, forKey: .maxSteps) ?? 8,
            // Not `try?`, unlike `GizmateTool.layout`'s decode. This crosses
            // the trusted host↔sidecar boundary — the host wrote this JSON
            // itself, in the same build, to hand the model back its own
            // layout for an edit — while `GizmateTool.layout` is read off a
            // user's disk, where a newer build may have written a shape this
            // one predates. One side can trust its own recent output; the
            // other has to survive its own past.
            layout: try container.decodeIfPresent(ToolAgentLayoutV1.self, forKey: .layout)
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
        try container.encodeIfPresent(options, forKey: .options)
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
            // Present only on a surface, same as the candidate: any other
            // Python tool never had one to write, and this type enforces
            // nothing about the pairing itself — that stays on the candidate.
            try container.encodeIfPresent(layout, forKey: .layout)
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
        options: [String]?,
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
              trigger != .files || input == .files,
              trigger != .selection || input == .selection else {
            throw ToolAgentFailureCodeV1.invalidCandidate
        }

        if let options {
            var seen = Set<String>()
            guard options.count >= ToolAgentProtocolLimitsV1.minimumOptionCount,
                  options.count <= ToolAgentProtocolLimitsV1.maximumOptionCount,
                  options.allSatisfy({
                      !$0.isEmpty
                          && $0.utf8.count <= ToolAgentProtocolLimitsV1.maximumOptionBytes
                          && seen.insert($0).inserted
                  })
            else {
                throw ToolAgentFailureCodeV1.invalidCandidate
            }
        }

        switch kind {
        case .prompt:
            // Deliberately no input or output allowlist. This guard has now
            // twice been the thing that rejected a candidate the model was
            // explicitly told to write — first screenshotText, then
            // drawnScreen — because a new case was added to the enum, the
            // sidecar schema and the capability description while this list
            // stayed where it was. A prompt tool works on whatever it is
            // handed and its answer goes wherever the user said; the pairing
            // rules are guidance in the prompt, not a wall here, so a wrong
            // pairing produces a tool that disappoints rather than a build
            // that fails with nothing to point at.
            guard
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
                  ToolAgentCandidateOutputV1.nativeDeliverable.contains(output),
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
                  ToolAgentCandidateOutputV1.agentDeliverable.contains(output),
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
        case options
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
        case layout
    }
}
