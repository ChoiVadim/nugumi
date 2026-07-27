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
public typealias ToolBuildSleepV1 = @Sendable (UInt64) async throws -> Void

public actor ToolBuildSupervisor {
    let store: ToolBuildStore
    let runtimeVersion: String
    let policyVersion: String
    let makeProcess: ToolBuildProcessFactoryV1
    let model: ToolBuildModelHandlerV1
    let validation: ToolBuildValidationHandlerV1
    let makeCandidateID: @Sendable () -> UUID
    let sleep: ToolBuildSleepV1

    var activeRequest: ToolBuildRequestV1?
    var activeProcess: ToolBuildProcessClientV1?
    var terminal: Result<ToolBuildResultV1, ToolAgentFailureCodeV1>?
    var latestAttempt: ToolBuildAttemptV1?
    var latestValidation: ToolAgentValidationReportV1?
    var attestation: ToolAgentAttestationV1?

    public init(
        store: ToolBuildStore,
        runtimeVersion: String,
        policyVersion: String,
        makeProcess: @escaping ToolBuildProcessFactoryV1,
        model: @escaping ToolBuildModelHandlerV1,
        validation: @escaping ToolBuildValidationHandlerV1,
        makeCandidateID: @escaping @Sendable () -> UUID = { UUID() },
        sleep: @escaping ToolBuildSleepV1 = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.store = store
        self.runtimeVersion = runtimeVersion
        self.policyVersion = policyVersion
        self.makeProcess = makeProcess
        self.model = model
        self.validation = validation
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
        defer { clearActiveRun(request.runID) }

        do {
            try await store.create(request)
            let process = try await makeProcess(request)
            activeProcess = process
            try await process.send(.start(
                runID: request.runID,
                .init(description: request.description, budgets: request.budgets)
            ))

            let timeout = UInt64(request.budgets.durationSeconds) * 1_000_000_000
            let deadline = Task { [weak self] in
                do {
                    guard let self else { return }
                    try await self.sleep(timeout)
                    guard !Task.isCancelled else { return }
                    await self.expire(runID: request.runID)
                } catch {}
            }
            defer { deadline.cancel() }

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
        terminal = .failure(.cancelled)
        if let process = activeProcess {
            try? await process.send(.cancel(runID: runID, .init(reason: .userRequested)))
            await process.cancel()
        }
        try? await store.transition(runID: runID, to: .cancelled, failure: .cancelled)
        return true
    }

    func expire(runID: UUID) async {
        guard activeRequest?.runID == runID, terminal == nil else { return }
        terminal = .failure(.timedOut)
        if let process = activeProcess {
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
        terminal = .failure(failure)
        await activeProcess?.cancel()
        try? await store.transition(runID: runID, to: state, failure: failure)
    }

    private func clearActiveRun(_ runID: UUID) {
        guard activeRequest?.runID == runID else { return }
        activeRequest = nil
        activeProcess = nil
        latestAttempt = nil
        latestValidation = nil
        attestation = nil
    }

    private static func isValid(_ request: ToolBuildRequestV1, runtimeVersion: String, policyVersion: String) -> Bool {
        let budgets = request.budgets
        return !request.description.isEmpty
            && request.description.utf8.count <= ToolAgentProtocolLimitsV1.maximumSafeMessageBytes
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
