import Foundation

extension ToolBuildSupervisor {
    func acceptState(_ state: ToolAgentBuildStateV1, request: ToolBuildRequestV1) async throws {
        try await advance(to: state, request: request)
    }

    func advance(to state: ToolAgentBuildStateV1, request: ToolBuildRequestV1) async throws {
        let record = try await store.record(runID: request.runID)
        if record.state == state { return }
        guard Self.canTransition(from: record.state, to: state),
              Self.hasEvidence(for: state, validation: latestValidation, attestation: attestation, counters: record.counters) else {
            throw ToolAgentFailureCodeV1.invalidProtocol
        }
        try await store.transition(runID: request.runID, to: state)
    }

    func acceptModelRequest(
        _ modelRequest: ToolAgentModelRequestV1,
        request: ToolBuildRequestV1,
        process: ToolBuildProcessClientV1
    ) async throws {
        let record = try await store.record(runID: request.runID)
        guard record.counters.modelTurns < request.budgets.modelTurns else {
            throw ToolAgentFailureCodeV1.budgetExhausted
        }
        try await store.charge(runID: request.runID, modelTurns: 1)
        let response = try await model(modelRequest)
        guard terminal == nil else { return }
        try await process.send(.modelResponse(
            runID: request.runID,
            .init(requestID: modelRequest.requestID, result: response)
        ))
    }

    func acceptToolRequest(
        _ envelope: ToolAgentToolRequestEnvelopeV1,
        request: ToolBuildRequestV1,
        process: ToolBuildProcessClientV1
    ) async throws {
        let record = try await store.record(runID: request.runID)
        guard record.counters.toolCalls < request.budgets.toolCalls else {
            throw ToolAgentFailureCodeV1.budgetExhausted
        }
        try await store.charge(runID: request.runID, toolCalls: 1)

        let response: ToolAgentToolResponseV1
        switch envelope.request {
        case .readBuildContext:
            let charged = try await store.record(runID: request.runID)
            response = .readBuildContext(.init(
                remaining: .init(
                    modelTurns: request.budgets.modelTurns - charged.counters.modelTurns,
                    toolCalls: request.budgets.toolCalls - charged.counters.toolCalls,
                    repairs: request.budgets.repairs - charged.counters.repairs
                ),
                secretNames: await secretNames?() ?? request.availableSecretNames,
                notesAvailable: await notesAvailable?()
            ))
        case .writeCandidate(let write):
            response = .writeCandidate(try await acceptWrite(write, request: request))
        case .runValidation(let validationRequest):
            response = .runValidation(try await acceptValidation(validationRequest, request: request))
        case .finishCandidate(let finish):
            response = .finishCandidate(try await acceptFinish(finish, request: request))
        case .askUser(let clarificationRequest):
            response = .askUser(try await acceptClarification(clarificationRequest, request: request))
        }
        guard terminal == nil else { return }
        try await process.send(.toolResponse(
            runID: request.runID,
            .init(callID: envelope.callID, result: response)
        ))
    }

    func acceptClarification(_ clarificationRequest: ToolAgentAskUserRequestV1, request: ToolBuildRequestV1) async throws -> ToolAgentAskUserResponseV1 {
        // One call, not three. The request carries every question at once now,
        // so a second call is the model coming back for a fact it already had
        // the room to ask for, and each one costs the user another stop.
        guard latestAttempt == nil,
              clarificationCount < 1 else {
            throw ToolAgentFailureCodeV1.invalidProtocol
        }
        clarificationCount += 1
        let handler = clarification
        let token = UUID()
        let task = Task { try await handler(clarificationRequest) }
        pendingClarification = (request.runID, token, task)
        do {
            let response = try await task.value
            clearPendingClarification(runID: request.runID, token: token)
            guard terminal == nil else {
                throw ToolAgentFailureCodeV1.cancelled
            }
            return response
        } catch {
            clearPendingClarification(runID: request.runID, token: token)
            throw error
        }
    }

    func acceptWrite(
        _ write: ToolAgentWriteCandidateRequestV1,
        request: ToolBuildRequestV1
    ) async throws -> ToolAgentWriteCandidateResponseV1 {
        try await advance(to: .writing, request: request)
        let candidateID = makeCandidateID()
        let fingerprint = try ToolAgentCandidateFingerprintV1.make(
            candidate: write.candidate,
            runtimeVersion: runtimeVersion,
            policyVersion: policyVersion
        )
        let response = try ToolAgentWriteCandidateResponseV1(
            candidateID: candidateID,
            fingerprint: fingerprint
        )
        try await store.appendAttempt(
            runID: request.runID,
            candidateID: candidateID,
            fingerprint: fingerprint,
            candidate: write.candidate
        )
        latestAttempt = .init(
            sequence: (try await store.record(runID: request.runID)).attempts.count - 1,
            candidateID: candidateID,
            fingerprint: fingerprint,
            candidate: write.candidate
        )
        latestValidation = nil
        attestation = nil
        return response
    }

    func acceptValidation(
        _ validationRequest: ToolAgentRunValidationRequestV1,
        request: ToolBuildRequestV1
    ) async throws -> ToolAgentValidationReportV1 {
        guard let attempt = latestAttempt, attempt.candidateID == validationRequest.candidateID else {
            throw ToolAgentFailureCodeV1.attestationFailed
        }
        try await advance(to: .testing, request: request)
        let input = ToolBuildValidationInputV1(
            request: request,
            candidateID: attempt.candidateID,
            fingerprint: attempt.fingerprint,
            candidate: attempt.candidate
        )
        let supplied = try await validation(input)
        let checked = try ToolAgentValidationReportV1(
            candidateID: supplied.candidateID,
            fingerprint: supplied.fingerprint,
            outcome: supplied.outcome,
            assurance: supplied.assurance,
            failure: supplied.failure,
            fixtureIndex: supplied.fixtureIndex,
            expectedOutput: supplied.expectedOutput,
            actualOutput: supplied.actualOutput,
            stderrDetail: supplied.stderrDetail,
            exitCode: supplied.exitCode,
            terminationSignal: supplied.terminationSignal,
            stdoutWasTruncated: supplied.stdoutWasTruncated,
            stderrWasTruncated: supplied.stderrWasTruncated,
            durationMilliseconds: supplied.durationMilliseconds,
            passingFingerprint: supplied.passingFingerprint
        )
        guard checked.candidateID == attempt.candidateID,
              checked.fingerprint == attempt.fingerprint else {
            throw ToolAgentFailureCodeV1.attestationFailed
        }
        try await store.appendValidation(runID: request.runID, report: checked)
        latestValidation = checked
        if checked.outcome == .failed {
            let record = try await store.record(runID: request.runID)
            guard record.counters.repairs < request.budgets.repairs else {
                throw ToolAgentFailureCodeV1.budgetExhausted
            }
            try await store.charge(runID: request.runID, repairs: 1)
            try await advance(to: .diagnosing, request: request)
            try await advance(to: .repairing, request: request)
        } else {
            try await advance(to: .verifying, request: request)
        }
        return checked
    }

    func acceptFinish(
        _ finish: ToolAgentFinishCandidateRequestV1,
        request: ToolBuildRequestV1
    ) async throws -> ToolAgentAttestationV1 {
        guard let attempt = latestAttempt, let latestValidation else {
            throw ToolAgentFailureCodeV1.attestationFailed
        }
        let write = try ToolAgentWriteCandidateResponseV1(
            candidateID: attempt.candidateID,
            fingerprint: attempt.fingerprint
        )
        let exact = try ToolAgentAttestationV1(write: write, validation: latestValidation, finish: finish)
        attestation = exact
        try await advance(to: .candidateReady, request: request)
        return exact
    }

    func acceptCompleted(_ completed: ToolAgentCompletedV1, request: ToolBuildRequestV1) async throws {
        let record = try await store.record(runID: request.runID)
        await completionRecordReadHook?()
        guard terminal == nil else { return }
        guard record.state == .candidateReady,
              let attestation,
              attestation.candidateID == completed.candidateID,
              attestation.fingerprint == completed.fingerprint else {
            throw ToolAgentFailureCodeV1.attestationFailed
        }
        let result = ToolBuildResultV1(
            candidateID: completed.candidateID,
            fingerprint: completed.fingerprint
        )
        let installedTerminal: Result<ToolBuildResultV1, ToolAgentFailureCodeV1> = .success(result)
        terminal = installedTerminal
        do {
            try await store.complete(runID: request.runID, result: result)
        } catch {
            if terminal == installedTerminal {
                terminal = nil
            }
            throw error
        }
    }

    static func canTransition(from: ToolAgentBuildStateV1, to: ToolAgentBuildStateV1) -> Bool {
        if from == to { return true }
        switch (from, to) {
        case (.created, .understanding),
             (.understanding, .writing),
             (.writing, .testing),
             (.testing, .diagnosing),
             (.testing, .verifying),
             (.diagnosing, .repairing),
             (.repairing, .writing),
             (.verifying, .candidateReady):
            return true
        default:
            return false
        }
    }

    static func hasEvidence(
        for state: ToolAgentBuildStateV1,
        validation: ToolAgentValidationReportV1?,
        attestation: ToolAgentAttestationV1?,
        counters: ToolAgentUsageCountersV1
    ) -> Bool {
        switch state {
        case .diagnosing: return validation?.outcome == .failed
        case .repairing: return validation?.outcome == .failed && counters.repairs > 0
        case .verifying: return validation?.outcome == .passed
        case .candidateReady: return attestation != nil
        case .failed, .cancelled, .budgetExhausted: return false
        default: return true
        }
    }
}
