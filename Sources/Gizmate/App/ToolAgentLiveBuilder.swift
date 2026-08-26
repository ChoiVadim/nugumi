import Foundation
import GizmateToolAgentCore

enum ToolAgentLiveBuilderError: LocalizedError {
    case runtimeUnavailable
    case model(String)
    case invalidResult
    case failed(ToolAgentFailureCodeV1)

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            return "The tool-building agent isn't available in this copy of Gizmate."
        case .model(let detail):
            return detail
        case .invalidResult:
            return "The agent finished without a verified tool."
        case .failed(let failure):
            switch failure {
            case .cancelled:
                return "Tool creation was cancelled."
            case .timedOut:
                return "The agent took too long. Try a smaller request."
            case .budgetExhausted:
                return "The agent couldn't make the tool pass after several attempts."
            case .invalidModelAction:
                return "The model returned an invalid agent action. Try again or choose another model."
            case .syntaxError, .runtimeError, .invalidOutput, .wrongOutput:
                return "The generated tool still failed its checks."
            case .workerFailure:
                return "Gizmate couldn't complete the tool checks."
            case .invalidCandidate:
                return "The model described a tool Gizmate can't represent. Try again or choose another model."
            case .attestationFailed:
                return "The finished tool didn't match the one Gizmate tested, so it was discarded."
            case .outputLimit:
                return "The tool produced far more output than Gizmate can check."
            case .invalidProtocol:
                // Reaching a user means the app and its bundled agent disagree,
                // which a shipped build cannot do — so say that plainly rather
                // than blaming the tool they asked for.
                return "Gizmate couldn't understand its own tool agent. This build's agent and app don't match."
            }
        }
    }
}

private actor ToolAgentModelFailure {
    private var message: String?

    func record(_ error: Error) {
        guard message == nil else { return }
        message = error.localizedDescription
    }

    func record(message: String) {
        guard self.message == nil else { return }
        self.message = message
    }

    var value: String? { message }
}

// A picture shown to a build rides along on every model turn of that build,
// and this is the second answer to the question. The first was "the first turn
// only", reasoned from the sidecar re-sending the whole conversation as text
// each turn: the model's own reading of the picture would stay in context
// after the picture itself was gone.
//
// It does not, and a trace said so. The first turn of a real build was the
// agent asking "what would you like to change?", which mentions no picture at
// all, so turn two had neither the image nor a word about it and the agent
// asked the user to attach the reference it had already been given. A model's
// reading only persists if the model happened to write it down, and a turn
// that asks a question never does.
//
// The cost is a vision payload per turn, bounded by the run's own 12-turn
// model budget. Losing the reference halfway through a build costs the whole
// build.

enum ToolAgentLiveBuilder {
    typealias ClarificationCancellation = @Sendable () async -> Void

    /// Asked when a candidate declares a secret the user has not stored yet.
    ///
    /// The declaration *is* the request: a model that writes
    /// `os.environ["GEMINI_API_KEY"]` has said what it needs more precisely than
    /// any question could, and it can say it at any point in the build rather
    /// than only in the three clarifications it is allowed before writing code.
    /// Returning false means the user declined — the validation run then fails
    /// on the missing key like any other error, which is the truth.
    typealias SecretRequest = @Sendable (String) async -> Bool

    /// Fills in any secret a candidate declares but the user has not stored,
    /// before anything tries to run it. Without this the run reaches
    /// `generatedTool`, which drops the unstored name, and the script dies on a
    /// `KeyError` the model then tries to "repair" by removing the key it needs.
    static func collectMissingSecrets(
        for candidate: ToolAgentCandidateV1,
        request: SecretRequest,
        onStatus: @Sendable (String) -> Void
    ) async {
        for name in candidate.secretNames ?? []
        where ToolSecrets.isValidName(name) && ToolSecrets.value(for: name) == nil {
            onStatus("Waiting for \(name)…")
            _ = await request(name)
        }
    }

    static func makeSupervisor(
        store: ToolBuildStore,
        runtimeVersion: String,
        policyVersion: String,
        makeProcess: @escaping ToolBuildProcessFactoryV1,
        model: @escaping ToolBuildModelHandlerV1,
        validation: @escaping ToolBuildValidationHandlerV1,
        clarification: @escaping ToolBuildClarificationHandlerV1 = {
            _ in throw ToolAgentFailureCodeV1.invalidProtocol
        },
        clarificationCancellation: @escaping ClarificationCancellation = {}
    ) -> ToolBuildSupervisor {
        ToolBuildSupervisor(
            store: store,
            runtimeVersion: runtimeVersion,
            policyVersion: policyVersion,
            makeProcess: makeProcess,
            model: model,
            validation: validation,
            clarification: clarification,
            clarificationCancellation: clarificationCancellation,
            // Read at call time, not from the request: the user may have stored
            // the key seconds ago, in the row this very build put in front of them.
            secretNames: { ToolSecrets.names() },
            notesAvailable: { NotesAccess.isEnabled }
        )
    }

    static func boundedDiagnostic(_ text: String) -> String {
        let maximum = ToolAgentProtocolLimitsV1.maximumDiagnosticBytes
        guard text.utf8.count > maximum else { return text }
        var bytes = Array(text.utf8.suffix(maximum))
        while !bytes.isEmpty, String(bytes: bytes, encoding: .utf8) == nil {
            bytes.removeFirst()
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    static func installedTool(
        from tool: GizmateTool,
        script: String
    ) throws -> ToolAgentInstalledToolV1 {
        let kind = ToolAgentCandidateKindV1(rawValue: tool.kind.rawValue) ?? .prompt
        let input = ToolAgentCandidateInputV1(rawValue: tool.input.rawValue) ?? .none
        let output = ToolAgentCandidateOutputV1(rawValue: tool.output.rawValue) ?? .notify
        return try ToolAgentInstalledToolV1(
            kind: kind,
            name: tool.name,
            brief: tool.brief,
            symbolName: tool.symbolName,
            input: input,
            output: output,
            // Gizmos are no longer gated on context — every one of them sits in
            // the Ring at all times — but the wire protocol still carries the
            // field, and `.always` is the value that validates against any input.
            trigger: .always,
            hosts: [],
            extensions: [],
            options: tool.options.isEmpty ? nil : tool.options,
            // An agent tool's instruction lives in the same field a prompt tool's
            // prompt does, so both carry it into an edit.
            prompt: kind == .prompt || kind == .agent ? tool.prompt : "",
            appliesTargetLanguage: kind == .prompt && tool.appliesTargetLanguage,
            // Carried so an edit session shows the model the current values —
            // without them, a revision that never mentioned notes stripped them.
            usesNotes: kind == .native ? nil : tool.usesNotes,
            usesVoice: kind == .prompt || kind == .agent ? tool.usesVoice : nil,
            nativeAction: kind == .native
                ? ToolAgentNativeActionV1(rawValue: tool.nativeAction.rawValue)
                : nil,
            target: kind == .native ? tool.target : "",
            source: kind == .python ? script : "",
            outputDirectory: kind == .python ? tool.outputDirectory : nil,
            timeoutSeconds: kind == .python || kind == .agent ? tool.timeoutSeconds : 120,
            declaresNetwork: kind == .python && tool.declaresNetwork,
            secretNames: kind == .python || kind == .agent ? tool.secretNames : [],
            maxSteps: tool.maxSteps,
            layout: output == .surface ? tool.layout : nil,
            refreshSeconds: output == .surface ? tool.refreshSeconds : nil
        )
    }

    @MainActor
    static func build(
        description: String,
        images: [ImageInput] = [],
        backend: any LLMBackend,
        thinkingLevel: ThinkingLevel,
        uv: URL,
        runID: UUID = UUID(),
        onStatus: @escaping @Sendable (String) -> Void,
        clarification: @escaping ToolBuildClarificationHandlerV1 = {
            _ in throw ToolAgentFailureCodeV1.invalidProtocol
        },
        clarificationCancellation: @escaping ClarificationCancellation = {},
        secretRequest: @escaping SecretRequest = { _ in false }
    ) async throws -> GeneratedTool {
        let requestText = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestText.isEmpty else {
            throw ToolGeneratorError.emptyDescription
        }
        // The caller may supply the run ID so it can read this build's journal
        // afterwards — every candidate the model wrote and every diagnostic it
        // was given back. That is what the eval reads to explain a failure.
        let request = ToolBuildRequestV1(
            runID: runID,
            description: requestText,
            budgets: .preview,
            availableSecretNames: ToolSecrets.names()
        )
        return try await build(
            request: request,
            images: images,
            backend: backend,
            thinkingLevel: thinkingLevel,
            uv: uv,
            onStatus: onStatus,
            clarification: clarification,
            clarificationCancellation: clarificationCancellation,
            secretRequest: secretRequest
        )
    }

    @MainActor
    static func revise(
        tool: GizmateTool,
        script: String,
        instruction: String,
        images: [ImageInput] = [],
        failure: String? = nil,
        backend: any LLMBackend,
        thinkingLevel: ThinkingLevel,
        uv: URL,
        onStatus: @escaping @Sendable (String) -> Void,
        clarification: @escaping ToolBuildClarificationHandlerV1 = {
            _ in throw ToolAgentFailureCodeV1.invalidProtocol
        },
        clarificationCancellation: @escaping ClarificationCancellation = {},
        secretRequest: @escaping SecretRequest = { _ in false }
    ) async throws -> GeneratedTool {
        let requestText = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestText.isEmpty else {
            throw ToolGeneratorError.emptyDescription
        }
        let snapshot = try installedTool(from: tool, script: script)
        let boundedFailure = failure.map(boundedDiagnostic)
        let request = try ToolBuildRequestV1(
            description: requestText,
            budgets: .preview,
            operation: boundedFailure == nil ? .edit : .fix,
            currentTool: snapshot,
            failure: boundedFailure,
            availableSecretNames: ToolSecrets.names()
        )
        let generated = try await build(
            request: request,
            images: images,
            backend: backend,
            thinkingLevel: thinkingLevel,
            uv: uv,
            onStatus: onStatus,
            clarification: clarification,
            clarificationCancellation: clarificationCancellation,
            secretRequest: secretRequest
        )
        return preservingIdentity(of: tool, in: generated)
    }

    @MainActor
    private static func build(
        request: ToolBuildRequestV1,
        images: [ImageInput] = [],
        backend: any LLMBackend,
        thinkingLevel: ThinkingLevel,
        uv: URL,
        onStatus: @escaping @Sendable (String) -> Void,
        clarification: @escaping ToolBuildClarificationHandlerV1,
        clarificationCancellation: @escaping ClarificationCancellation,
        secretRequest: @escaping SecretRequest = { _ in false }
    ) async throws -> GeneratedTool {
        let runtime = try ToolAgentRuntimeLocation.resolve()
        let store = try ToolBuildStore(directoryURL: GizmatePaths.toolAgentRuns)
        let modelFailure = ToolAgentModelFailure()
        let fixtures = ToolAgentFixtureHistory()
        let supervisor = makeSupervisor(
            store: store,
            runtimeVersion: ToolAgentGateRunner.runtimeVersion,
            policyVersion: ToolAgentGateRunner.policyVersion,
            makeProcess: { _ in
                let process = try JSONLProcess.launch(
                    executableURL: runtime.node,
                    arguments: [runtime.agent.path],
                    environment: ["TMPDIR": GizmatePaths.toolAgentRuns.path]
                )
                return process.client()
            },
            model: { request in
                onStatus("Building the tool…")
                do {
                    let text = try await answerPiModelRequest(
                        request,
                        images: images,
                        backend: backend,
                        thinkingLevel: thinkingLevel,
                        onStatus: onStatus
                    )
                    if let message = ToolAgentModelActionInspector
                        .unsupportedMessage(in: text) {
                        await modelFailure.record(message: message)
                    }
                    return .text(text)
                } catch ToolAgentLiveBuilderError.model(let detail) {
                    // Said in full to the user rather than collapsed into the
                    // code: `invalidModelAction` is the truth about the run and
                    // `detail` is the only thing anyone can act on.
                    await modelFailure.record(message: detail)
                    return .error(.invalidModelAction)
                } catch ToolAgentLiveBuilderError.failed(let failure) {
                    return .error(failure)
                } catch {
                    await modelFailure.record(error)
                    return .error(error is CancellationError ? .cancelled : .workerFailure)
                }
            },
            validation: { input in
                // Before the switch, because every kind below that runs anything
                // resolves its environment through `generatedTool`, which keeps
                // only the secrets that exist on disk at that moment.
                await collectMissingSecrets(
                    for: input.candidate,
                    request: secretRequest,
                    onStatus: onStatus
                )
                let report: ToolAgentValidationReportV1
                switch input.candidate.kind {
                case .prompt:
                    onStatus("Checking the prompt…")
                    report = try ToolAgentHostCandidateValidator.validate(
                        candidateID: input.candidateID,
                        fingerprint: input.fingerprint,
                        candidate: input.candidate,
                        applicationExists: { _ in true }
                    )
                case .native:
                    onStatus("Checking the macOS action…")
                    report = try await MainActor.run {
                        try ToolAgentHostCandidateValidator.validate(
                            candidateID: input.candidateID,
                            fingerprint: input.fingerprint,
                            candidate: input.candidate,
                            applicationExists: ToolAgentHostCandidateValidator
                                .installedApplicationExists
                        )
                    }
                case .python:
                    if let retreat = try await fixtures.retreatReport(for: input) {
                        report = retreat
                        break
                    }
                    onStatus(
                        input.candidate.fixtures.isEmpty
                            ? "Checking its dependencies…"
                            : "Running it to see whether it works…"
                    )
                    report = try await CandidateValidation.validate(
                        input,
                        uv: uv
                    )
                case .agent:
                    // An agent candidate cannot be checked the way the others
                    // are: there is no code to compile and no output to compare,
                    // because both are decided at run time. What can be checked
                    // is that it runs at all — the sidecar starts, the model
                    // drives it, and it reaches an answer. A candidate with no
                    // fixture is one the model judged unsafe to trial (it sends,
                    // publishes or deletes something), and is taken on structure
                    // alone rather than doing that thing during a build.
                    onStatus(
                        input.candidate.fixtures.isEmpty
                            ? "Checking how it is set up…"
                            : "Running it once to see whether it gets there…"
                    )
                    report = try await AgentCandidateValidation.validate(
                        input,
                        backend: backend,
                        thinkingLevel: thinkingLevel,
                        uv: uv
                    )
                }
                guard report.outcome == .passed else {
                    onStatus("Found an error. Repairing it…")
                    return report
                }
                switch report.assurance {
                case .verified:
                    onStatus("It works. Finishing the tool…")
                case .smoke:
                    onStatus("It ran cleanly. Finishing the tool…")
                case .unverified:
                    onStatus("Its dependencies check out. Finishing the tool…")
                }
                return report
            },
            clarification: clarification,
            clarificationCancellation: clarificationCancellation
        )

        onStatus("Understanding your request…")
        let result: ToolBuildResultV1
        do {
            result = try await supervisor.build(request)
        } catch let failure as ToolAgentFailureCodeV1 {
            if let message = await modelFailure.value {
                throw ToolAgentLiveBuilderError.model(message)
            }
            throw ToolAgentLiveBuilderError.failed(failure)
        } catch {
            if let message = await modelFailure.value {
                throw ToolAgentLiveBuilderError.model(message)
            }
            throw error
        }

        let record = try await store.record(runID: request.runID)
        guard
            record.state == .candidateReady,
            record.result == result,
            let attempt = record.attempts.last(where: {
                $0.candidateID == result.candidateID
                    && $0.fingerprint == result.fingerprint
            }),
            let validation = record.validations.last(where: {
                $0.report.candidateID == result.candidateID
                    && $0.report.fingerprint == result.fingerprint
            })?.report,
            validation.outcome == .passed,
            validation.passingFingerprint == result.fingerprint
        else {
            throw ToolAgentLiveBuilderError.invalidResult
        }

        var generated = generatedTool(from: attempt.candidate)
        generated.assurance = validation.assurance
        generated.summary = "\(attempt.candidate.brief) \(validation.assurance.explanation)"
        return generated
    }

    @MainActor
    private static func answerPiModelRequest(
        _ request: ToolAgentModelRequestV1,
        images: [ImageInput] = [],
        backend: any LLMBackend,
        thinkingLevel: ThinkingLevel,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        // Traced because the whole path is invisible from the outside: a
        // picture that never reaches this line and a picture the provider
        // discards look identical from the transcript, where the model simply
        // says it didn't get one.
        // The backend is named because "the model returned nonsense" is a
        // different bug for a local 4B and for a cloud flagship, and the
        // transcript never says which one answered.
        NSLog(
            "[Gizmate/Build] model turn with %d picture(s) on %@",
            images.count,
            String(describing: type(of: backend))
        )
        let first = try await backend.complete(
            systemPrompt: request.system,
            userPrompt: request.user,
            images: images,
            thinkingLevel: thinkingLevel,
            onPartial: { _ in }
        )
        if let normalized = ToolAgentModelActionValidator.normalized(first) {
            return normalized
        }

        onStatus("Correcting the model's response format…")
        // The repair used to be blind: the same instructions that had just
        // failed, plus the rejected text, and no statement of what was wrong
        // with it. A model cannot fix a key it does not know it omitted, so the
        // second attempt usually failed the same way as the first and the user
        // was told "the model returned an invalid agent action", which names
        // neither the action nor the problem. The naming, logging and payload
        // now live in `ToolAgentModelActionRepair`, shared with the agent run.
        let repair = ToolAgentModelActionRepair.turn(
            agentContext: request.user,
            rejected: first,
            logLabel: "Build"
        )
        guard let repairPayload = repair.payload else {
            throw ToolAgentLiveBuilderError.model(repair.problem)
        }
        let repaired = try await backend.complete(
            systemPrompt: request.system + ToolAgentModelActionRepair.systemSuffix,
            userPrompt: repairPayload,
            images: [],
            thinkingLevel: thinkingLevel,
            onPartial: { _ in }
        )
        guard let normalized = ToolAgentModelActionValidator.normalized(repaired) else {
            // What the second attempt got wrong, not the first: the repair may
            // have fixed one thing and broken another, and reporting the stale
            // problem would send the next reader after the wrong field.
            let after = ToolAgentModelActionDiagnosis.problem(with: repaired) ?? repair.problem
            throw ToolAgentLiveBuilderError.model(
                "The model's reply did not match the agent protocol, twice in a "
                    + "row. \(after) Try again, or choose another model."
            )
        }
        return normalized
    }

    static func generatedTool(from candidate: ToolAgentCandidateV1) -> GeneratedTool {
        let stored = Set(ToolSecrets.names())
        let kind: ToolKind = switch candidate.kind {
        case .prompt: .prompt
        case .native: .native
        case .python: .python
        case .agent: .agent
        }
        let input = ToolInput(rawValue: candidate.input.rawValue) ?? .none
        let output = ToolOutput(rawValue: candidate.output.rawValue) ?? .notify
        let nativeAction = candidate.nativeAction
            .flatMap { NativeAction(rawValue: $0.rawValue) }
            ?? .openApp
        let tool = GizmateTool(
            name: candidate.name,
            symbolName: ToolIcons.curated.contains(candidate.symbolName)
                ? candidate.symbolName
                : ToolIcons.fallback,
            kind: kind,
            input: input,
            output: output,
            options: candidate.options ?? [],
            prompt: candidate.prompt,
            appliesTargetLanguage: candidate.appliesTargetLanguage,
            nativeAction: nativeAction,
            target: candidate.target,
            outputDirectory: kind == .python ? candidate.outputDirectory : nil,
            timeoutSeconds: candidate.timeoutSeconds,
            declaresNetwork: kind == .python && candidate.declaresNetwork,
            // Filtered against what the user actually stored: a model that
            // invents `STRIPE_KEY` must not leave a tool permanently declaring a
            // secret nobody has, where the only symptom is a None at run time.
            secretNames: kind == .python || kind == .agent
                ? (candidate.secretNames ?? []).filter(stored.contains)
                : [],
            layout: output == .surface ? candidate.layout : nil,
            refreshSeconds: output == .surface ? candidate.refreshSeconds : nil,
            maxSteps: candidate.maxSteps,
            brief: candidate.brief,
            usesVoice: candidate.usesVoice ?? false,
            usesNotes: candidate.usesNotes ?? false
        )
        return GeneratedTool(
            tool: tool,
            script: kind == .python ? candidate.source : "",
            summary: candidate.brief,
            brief: candidate.brief
        )
    }

    static func generatedTool(
        from candidate: ToolAgentCandidateV1,
        preserving existing: GizmateTool
    ) -> GeneratedTool {
        var generated = preservingIdentity(of: existing, in: generatedTool(from: candidate))
        // nil is "the model didn't say", and an edit that never mentioned notes
        // or voice must not strip them — only an explicit false turns them off.
        // This is the same defect class ToolProtocolEnumParityTests guards: a
        // field the round trip silently drops.
        generated.tool.usesNotes = candidate.usesNotes ?? existing.usesNotes
        generated.tool.usesVoice = candidate.usesVoice ?? existing.usesVoice
        // Same contract for a surface's cadence: an edit that reworded the
        // brief must not turn a live monitor into a once-per-reveal one.
        if generated.tool.output == .surface {
            generated.tool.refreshSeconds = candidate.refreshSeconds ?? existing.refreshSeconds
        }
        return generated
    }

    static func preservingIdentity(
        of existing: GizmateTool,
        in replacement: GeneratedTool
    ) -> GeneratedTool {
        var generated = replacement
        generated.tool.id = existing.id
        generated.tool.createdAt = existing.createdAt
        return generated
    }
}
