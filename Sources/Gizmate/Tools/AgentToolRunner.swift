import Foundation
import GizmateToolAgentCore

enum AgentToolRunError: LocalizedError {
    case runtimeUnavailable
    case failed(ToolAgentFailureCodeV1, String)
    case endedWithoutAnswer

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            return "The agent runtime isn't installed."
        case .failed(let code, let message):
            switch code {
            case .budgetExhausted:
                return "It ran out of steps before it finished. Give it a bigger step budget, "
                    + "or narrow what you asked for."
            case .timedOut:
                return "It ran past its time limit and was stopped."
            case .cancelled:
                return "Stopped."
            default:
                return message.isEmpty ? "The agent failed." : message
            }
        case .endedWithoutAnswer:
            return "The agent stopped without producing an answer."
        }
    }
}

/// Runs a `.agent` tool: a Pi session that decides what to do as it goes,
/// writing and running Python until it has an answer.
///
/// The same sidecar the tool *builder* uses, started at its other entry point.
/// That is the whole reason this kind is affordable: tool-calling over a
/// text-only backend, budgets, cancellation and fail-closed protocol handling
/// already exist and are already tested, and none of the `LLMBackend`
/// implementations offer native tool calls to build a second loop on.
///
/// **Security posture.** Everything `ToolRunner`'s own note says applies here,
/// more so: the Python this executes was written moments ago by a model and
/// nobody has read it. What stands between that and the user is the approval
/// they gave this tool — see `GizmateApp.presentAgentApproval` — plus a step
/// budget and a wall clock. Real containment is the same `sandbox-exec` follow-up
/// that `.python` tools are already waiting on.
enum AgentToolRunner {
    /// How much of a script's output the model is shown per step. Enough to read
    /// a traceback or a page of JSON; short enough that one `cat` of a big file
    /// cannot eat the entire context and end the run.
    private static let maximumStreamCharacters = 8_000

    struct Progress: Sendable {
        let step: Int
        let purpose: String
    }

    /// - Parameters:
    ///   - input: what the ring handed the tool, already resolved.
    ///   - images: the picture the tool was handed, for an agent whose input is
    ///     a screen. Sent on every turn rather than only the first: the sidecar
    ///     re-serialises the whole conversation as text each time it asks for a
    ///     model call, so an image attached once would be gone by the step that
    ///     needed it. Costs one image per turn — see `budgets(for:)` for how
    ///     many that can be.
    ///   - onProgress: called as each `run_python` step starts, for the HUD.
    /// - Returns: the text the agent finished with.
    @MainActor
    static func run(
        tool: GizmateTool,
        input: String,
        images: [ImageInput] = [],
        backend: any LLMBackend,
        thinkingLevel: ThinkingLevel,
        uv: URL,
        onProgress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async throws -> String {
        guard let runtime = try? ToolAgentRuntimeLocation.resolve(entry: "run.mjs") else {
            throw AgentToolRunError.runtimeUnavailable
        }
        let process = try JSONLProcess.launch(
            executableURL: runtime.node,
            arguments: [runtime.agent.path],
            environment: ["TMPDIR": GizmatePaths.toolAgentRuns.path]
        )
        defer { Task { await process.finish() } }

        // The sidecar enforces the same wall clock on itself, but it can only
        // abort between steps: a script that started just before the deadline
        // would still run its own full timeout on top, taking the whole thing to
        // nearly double what the user set. Each step is capped at what is left.
        let deadline = Date().addingTimeInterval(Double(max(15, tool.timeoutSeconds)))
        let runID = UUID()
        try await send(
            .start(runID: runID, AgentRunStartV1(
                instruction: tool.prompt,
                input: input,
                budgets: budgets(for: tool),
                secretNames: tool.secretNames
            )),
            to: process
        )

        var step = 0
        while true {
            guard let line = try await process.receiveLine() else {
                throw AgentToolRunError.endedWithoutAnswer
            }
            let message = try AgentRunJSONLCodecV1.decode(line)
            guard message.runID == runID else {
                throw AgentToolRunError.failed(.invalidProtocol, "mismatched run ID")
            }

            switch message.payload {
            case .completed(let completed):
                let text = completed.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw AgentToolRunError.endedWithoutAnswer }
                return text

            case .failed(let failure):
                throw AgentToolRunError.failed(failure.code, failure.message)

            case .modelRequest(let request):
                let result = await answerModel(
                    request,
                    images: images,
                    backend: backend,
                    thinkingLevel: thinkingLevel
                )
                try await send(
                    .modelResponse(runID: runID, .init(requestID: request.requestID, result: result)),
                    to: process
                )

            case .toolRequest(let envelope):
                switch envelope.request {
                case .runPython(let python):
                    step += 1
                    onProgress(Progress(step: step, purpose: python.purpose))
                    let response = await runPython(
                        python,
                        tool: tool,
                        remaining: deadline.timeIntervalSinceNow,
                        uv: uv
                    )
                    try await send(
                        .toolResponse(runID: runID, .init(
                            callID: envelope.callID,
                            result: .runPython(response)
                        )),
                        to: process
                    )
                case .finish:
                    // Acknowledged here; the answer itself arrives as the
                    // `completed` envelope, which is the one place the run can
                    // report success.
                    try await send(
                        .toolResponse(runID: runID, .init(
                            callID: envelope.callID,
                            result: .finish(AgentRunFinishResponseV1())
                        )),
                        to: process
                    )
                }

            case .state, .start, .modelResponse, .toolResponse, .cancel:
                // Progress chatter and echoes of our own messages. Nothing to do.
                continue
            }

            if Task.isCancelled {
                try? await send(.cancel(runID: runID, .init(reason: .userRequested)), to: process)
                throw AgentToolRunError.failed(.cancelled, "cancelled")
            }
        }
    }

    // MARK: - Steps

    /// One `run_python` step. A failing script is **not** an error here — a
    /// traceback is information the agent asked for and has to be handed back so
    /// it can repair its own approach. Only the host failing to run anything at
    /// all is reported as a non-zero exit with the reason on stderr.
    @MainActor
    private static func runPython(
        _ request: AgentRunPythonRequestV1,
        tool: GizmateTool,
        remaining: TimeInterval,
        uv: URL
    ) async -> AgentRunPythonResponseV1 {
        // `ToolRunner` reads its limit off the tool, so the step's share of the
        // run is handed over as a copy rather than a parameter. Its own floor of
        // 5s still applies, which is what a step gets when the clock has already
        // run out — enough for the script to die on its own rather than hang.
        var step = tool
        step.timeoutSeconds = max(5, Int(remaining.rounded(.down)))
        do {
            let result = try await ToolRunner.run(
                tool: step,
                script: request.source,
                arguments: [],
                uv: uv,
                deliverOutputs: false
            )
            let (stdout, outCut) = bounded(result.stdout)
            let (stderr, errorCut) = bounded(result.stderr)
            return AgentRunPythonResponseV1(
                exitCode: result.exitCode,
                stdout: stdout,
                stderr: stderr,
                truncated: outCut || errorCut,
                producedFiles: result.producedFiles.map(\.path)
            )
        } catch {
            return AgentRunPythonResponseV1(
                exitCode: -1,
                stdout: "",
                stderr: error.localizedDescription
            )
        }
    }

    @MainActor
    private static func answerModel(
        _ request: ToolAgentModelRequestV1,
        images: [ImageInput],
        backend: any LLMBackend,
        thinkingLevel: ThinkingLevel
    ) async -> ToolAgentModelResponseResultV1 {
        do {
            let text = try await backend.complete(
                systemPrompt: request.system,
                userPrompt: request.user,
                images: images,
                thinkingLevel: thinkingLevel,
                onPartial: { _ in }
            )
            // The same repair the builder does: models wrap their JSON in a
            // markdown fence often enough that failing the whole run over it
            // would be the most common way an agent tool dies.
            return .text(ToolAgentModelActionValidator.normalized(text) ?? text)
        } catch {
            return .error(error is CancellationError ? .cancelled : .workerFailure)
        }
    }

    // MARK: - Helpers

    /// Budgets for one run. `maxSteps` is what the user set; the model needs a
    /// turn per step plus one to finish and one to say it finished, and a couple
    /// of tool calls beyond the steps for `finish` itself.
    private static func budgets(for tool: GizmateTool) -> ToolAgentBudgetsV1 {
        let steps = max(1, min(24, tool.maxSteps))
        return ToolAgentBudgetsV1(
            modelTurns: steps + 3,
            toolCalls: steps + 2,
            repairs: 0,
            durationSeconds: max(15, min(900, tool.timeoutSeconds))
        )
    }

    private static func bounded(_ text: String) -> (String, Bool) {
        guard text.count > maximumStreamCharacters else { return (text, false) }
        // Kept from both ends: the first lines say what the script was doing, the
        // last lines carry the exception that actually stopped it.
        let head = text.prefix(maximumStreamCharacters / 2)
        let tail = text.suffix(maximumStreamCharacters / 2)
        return ("\(head)\n…[cut]…\n\(tail)", true)
    }

    private static func send(_ message: AgentRunMessageV1, to process: JSONLProcess) async throws {
        try await process.sendLine(AgentRunJSONLCodecV1.encode(message))
    }
}
