import Foundation

public enum ToolBuildSupervisorError: Error, Equatable, Sendable {
    case alreadyRunning
    case invalidRequest
}

public struct ToolBuildValidationInputV1: Sendable {
    public let request: ToolBuildRequestV1
    public let candidateID: UUID
    public let fingerprint: ToolAgentFingerprintV1
    public let candidate: ToolAgentCandidateV1

    public init(
        request: ToolBuildRequestV1,
        candidateID: UUID,
        fingerprint: ToolAgentFingerprintV1,
        candidate: ToolAgentCandidateV1
    ) {
        self.request = request
        self.candidateID = candidateID
        self.fingerprint = fingerprint
        self.candidate = candidate
    }
}

public typealias ToolBuildProcessFactoryV1 = @Sendable (ToolBuildRequestV1) async throws -> ToolBuildProcessClientV1
public typealias ToolBuildModelHandlerV1 = @Sendable (ToolAgentModelRequestV1) async throws -> ToolAgentModelResponseResultV1
public typealias ToolBuildValidationHandlerV1 = @Sendable (ToolBuildValidationInputV1) async throws -> ToolAgentValidationReportV1
public typealias ToolBuildClarificationHandlerV1 = @Sendable (ToolAgentAskUserRequestV1) async throws -> ToolAgentAskUserResponseV1
public typealias ToolBuildSleepV1 = @Sendable (UInt64) async throws -> Void

/// What the user has stored **right now**, asked at the moment the model calls
/// `read_build_context` rather than taken from the request.
///
/// The request's `availableSecretNames` is a snapshot from before the build
/// started, and the one moment a user reaches for a key is halfway through the
/// build that just told them it needs one. Answering from the snapshot makes
/// "add it and tell me when it's there" a loop that can never terminate.
public typealias ToolBuildSecretNamesV1 = @Sendable () async -> [String]

public actor ToolBuildSupervisor {
    let store: ToolBuildStore
    let runtimeVersion: String
    let policyVersion: String
    let makeProcess: ToolBuildProcessFactoryV1
    let model: ToolBuildModelHandlerV1
    let validation: ToolBuildValidationHandlerV1
    let clarification: ToolBuildClarificationHandlerV1
    let clarificationCancellation: @Sendable () async -> Void
    /// `nil` falls back to the request's snapshot, which is what a test that
    /// does not care about secrets wants.
    let secretNames: ToolBuildSecretNamesV1?
    let makeCandidateID: @Sendable () -> UUID
    let sleep: ToolBuildSleepV1

    var activeRequest: ToolBuildRequestV1?
    var activeProcess: ToolBuildProcessClientV1?
    var terminal: Result<ToolBuildResultV1, ToolAgentFailureCodeV1>?
    var hostDeadlineRunID: UUID?
    var latestAttempt: ToolBuildAttemptV1?
    var latestValidation: ToolAgentValidationReportV1?
    var attestation: ToolAgentAttestationV1?
    var clarificationCount = 0
    var pendingClarification: (runID: UUID, token: UUID, task: Task<ToolAgentAskUserResponseV1, Error>)?
    var completionRecordReadHook: (@Sendable () async -> Void)?
    var deadlineTaskCompletionHook: (@Sendable () -> Void)?

    public init(
        store: ToolBuildStore,
        runtimeVersion: String,
        policyVersion: String,
        makeProcess: @escaping ToolBuildProcessFactoryV1,
        model: @escaping ToolBuildModelHandlerV1,
        validation: @escaping ToolBuildValidationHandlerV1,
        clarification: @escaping ToolBuildClarificationHandlerV1 = { _ in throw ToolAgentFailureCodeV1.invalidProtocol },
        clarificationCancellation: @escaping @Sendable () async -> Void = {},
        secretNames: ToolBuildSecretNamesV1? = nil,
        makeCandidateID: @escaping @Sendable () -> UUID = { UUID() },
        sleep: @escaping ToolBuildSleepV1 = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.store = store
        self.runtimeVersion = runtimeVersion
        self.policyVersion = policyVersion
        self.makeProcess = makeProcess
        self.model = model
        self.validation = validation
        self.clarification = clarification
        self.clarificationCancellation = clarificationCancellation
        self.secretNames = secretNames
        self.makeCandidateID = makeCandidateID
        self.sleep = sleep
    }

    public func build(_ request: ToolBuildRequestV1) async throws -> ToolBuildResultV1 {
        guard activeRequest == nil else { throw ToolBuildSupervisorError.alreadyRunning }
        guard Self.isValid(request, runtimeVersion: runtimeVersion, policyVersion: policyVersion) else {
            throw ToolBuildSupervisorError.invalidRequest
        }
        activeRequest = request
        terminal = nil
        latestAttempt = nil
        latestValidation = nil
        attestation = nil
        clarificationCount = 0
        pendingClarification = nil
        defer { clearActiveRun(request.runID) }
        var deadline: Task<Void, Never>?
        defer { deadline?.cancel() }

        do {
            try await store.create(request)
            let process = try await makeProcess(request)
            activeProcess = process
            try await process.send(.start(
                runID: request.runID,
                try .init(
                    description: request.description,
                    budgets: request.budgets,
                    operation: request.operation,
                    currentTool: request.currentTool,
                    failure: request.failure
                )
            ))

            let timeout = UInt64(request.budgets.durationSeconds) * 1_000_000_000
            let deadlineTaskCompletionHook = self.deadlineTaskCompletionHook
            deadline = Task { [weak self] in
                defer { deadlineTaskCompletionHook?() }
                do {
                    guard let self else { return }
                    try await self.sleep(timeout)
                    guard !Task.isCancelled else { return }
                    await self.expire(runID: request.runID)
                } catch {}
            }

            let result = try await withTaskCancellationHandler {
                try await runLoop(request: request, process: process)
            } onCancel: {
                Task { [weak self] in
                    _ = await self?.cancel(runID: request.runID)
                }
            }
            await process.finish()
            return result
        } catch {
            if case .failure(.timedOut)? = terminal, hostDeadlineRunID == request.runID {
                await deadline?.value
            }
            if let terminal {
                return try terminal.get()
            }
            let failure = Self.failureCode(for: error)
            await terminate(runID: request.runID, state: Self.state(for: failure), failure: failure)
            throw failure
        }
    }
    public func cancel(runID: UUID) async -> Bool {
        guard activeRequest?.runID == runID, terminal == nil else { return false }
        let process = activeProcess
        terminal = .failure(.cancelled)
        await cancelPendingClarification(runID: runID)
        if let process {
            try? await process.send(.cancel(runID: runID, .init(reason: .userRequested)))
            await process.cancel()
        }
        try? await store.transition(runID: runID, to: .cancelled, failure: .cancelled)
        return true
    }
    func expire(runID: UUID) async {
        guard activeRequest?.runID == runID, terminal == nil else { return }
        hostDeadlineRunID = runID
        let process = activeProcess
        terminal = .failure(.timedOut)
        await cancelPendingClarification(runID: runID)
        if let process {
            try? await process.send(.cancel(runID: runID, .init(reason: .deadlineExceeded)))
            await process.cancel()
        }
        try? await store.transition(runID: runID, to: .failed, failure: .timedOut)
    }
    func runLoop(request: ToolBuildRequestV1, process: ToolBuildProcessClientV1) async throws -> ToolBuildResultV1 {
        while terminal == nil {
            guard let message = try await process.receive() else {
                throw ToolAgentFailureCodeV1.workerFailure
            }
            guard message.runID == request.runID else {
                throw ToolAgentFailureCodeV1.invalidProtocol
            }
            switch message.payload {
            case .state(let update):
                try await acceptState(update.state, request: request)
            case .modelRequest(let modelRequest):
                try await acceptModelRequest(modelRequest, request: request, process: process)
            case .toolRequest(let toolRequest):
                try await acceptToolRequest(toolRequest, request: request, process: process)
            case .completed(let completed):
                try await acceptCompleted(completed, request: request)
            case .failed(let failed):
                await terminate(
                    runID: request.runID,
                    state: Self.state(for: failed.code),
                    failure: failed.code
                )
            default:
                throw ToolAgentFailureCodeV1.invalidProtocol
            }
        }
        return try terminal!.get()
    }
    func terminate(runID: UUID, state: ToolAgentBuildStateV1, failure: ToolAgentFailureCodeV1) async {
        guard activeRequest?.runID == runID, terminal == nil else { return }
        let process = activeProcess
        terminal = .failure(failure)
        await cancelPendingClarification(runID: runID)
        await process?.cancel()
        try? await store.transition(runID: runID, to: state, failure: failure)
    }

    private func clearActiveRun(_ runID: UUID) {
        guard activeRequest?.runID == runID else { return }
        activeRequest = nil
        activeProcess = nil
        hostDeadlineRunID = nil
        latestAttempt = nil
        latestValidation = nil
        attestation = nil
        clarificationCount = 0
        completionRecordReadHook = nil
        deadlineTaskCompletionHook = nil
    }

    private func cancelPendingClarification(runID: UUID) async {
        guard let pending = pendingClarification, pending.runID == runID else { return }
        await clarificationCancellation()
        pending.task.cancel()
        _ = await pending.task.result
        clearPendingClarification(runID: runID, token: pending.token)
    }

    func clearPendingClarification(runID: UUID, token: UUID) {
        if pendingClarification?.runID == runID, pendingClarification?.token == token { pendingClarification = nil }
    }

    func setCompletionRecordReadHook(_ hook: (@Sendable () async -> Void)?) {
        completionRecordReadHook = hook
    }

    func setDeadlineTaskCompletionHook(_ hook: (@Sendable () -> Void)?) {
        deadlineTaskCompletionHook = hook
    }

    private static func isValid(_ request: ToolBuildRequestV1, runtimeVersion: String, policyVersion: String) -> Bool {
        let budgets = request.budgets
        return !request.description.isEmpty
            && request.description.utf8.count <= ToolAgentProtocolLimitsV1.maximumSafeMessageBytes
            && (try? ToolAgentRequestContractV1.validate(
                operation: request.operation,
                currentTool: request.currentTool,
                failure: request.failure
            )) != nil
            && !runtimeVersion.isEmpty
            && !policyVersion.isEmpty
            && (1...ToolAgentBudgetsV1.preview.modelTurns).contains(budgets.modelTurns)
            && (1...ToolAgentBudgetsV1.preview.toolCalls).contains(budgets.toolCalls)
            && (0...ToolAgentBudgetsV1.preview.repairs).contains(budgets.repairs)
            && (1...ToolAgentBudgetsV1.preview.durationSeconds).contains(budgets.durationSeconds)
    }

    static func failureCode(for error: Error) -> ToolAgentFailureCodeV1 {
        if let code = error as? ToolAgentFailureCodeV1 { return code }
        if error is CancellationError { return .cancelled }
        if error is ToolAgentProtocolErrorV1 || error is JSONLProcessError { return .invalidProtocol }
        return .workerFailure
    }

    static func state(for failure: ToolAgentFailureCodeV1) -> ToolAgentBuildStateV1 {
        switch failure {
        case .cancelled: return .cancelled
        case .budgetExhausted: return .budgetExhausted
        default: return .failed
        }
    }
}
