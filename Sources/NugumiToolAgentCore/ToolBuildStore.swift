import Foundation

public struct ToolBuildRequestV1: Codable, Equatable, Sendable {
    public let runID: UUID
    public let description: String
    public let budgets: ToolAgentBudgetsV1
    public let createdAt: Date

    public init(runID: UUID = UUID(), description: String, budgets: ToolAgentBudgetsV1 = .preview, createdAt: Date = Date()) {
        self.runID = runID
        self.description = description
        self.budgets = budgets
        self.createdAt = createdAt
    }
}

public struct ToolBuildEventV1: Codable, Equatable, Sendable {
    public let sequence: Int
    public let state: ToolAgentBuildStateV1
    public let counters: ToolAgentUsageCountersV1
    public let failure: ToolAgentFailureCodeV1?

    public init(sequence: Int, state: ToolAgentBuildStateV1, counters: ToolAgentUsageCountersV1, failure: ToolAgentFailureCodeV1?) {
        self.sequence = sequence
        self.state = state
        self.counters = counters
        self.failure = failure
    }
}

public struct ToolBuildAttemptV1: Codable, Equatable, Sendable {
    public let sequence: Int
    public let candidateID: UUID
    public let fingerprint: ToolAgentFingerprintV1
    public let candidate: ToolAgentCandidateV1

    public init(sequence: Int, candidateID: UUID, fingerprint: ToolAgentFingerprintV1, candidate: ToolAgentCandidateV1) {
        self.sequence = sequence
        self.candidateID = candidateID
        self.fingerprint = fingerprint
        self.candidate = candidate
    }
}

public struct ToolBuildValidationRecordV1: Codable, Equatable, Sendable {
    public let sequence: Int
    public let report: ToolAgentValidationReportV1

    public init(sequence: Int, report: ToolAgentValidationReportV1) {
        self.sequence = sequence
        self.report = report
    }
}

public struct ToolBuildResultV1: Codable, Equatable, Sendable {
    public let candidateID: UUID
    public let fingerprint: ToolAgentFingerprintV1

    public init(candidateID: UUID, fingerprint: ToolAgentFingerprintV1) {
        self.candidateID = candidateID
        self.fingerprint = fingerprint
    }
}

public struct ToolBuildRecordV1: Codable, Equatable, Sendable {
    public let request: ToolBuildRequestV1
    public var state: ToolAgentBuildStateV1
    public var counters: ToolAgentUsageCountersV1
    public var events: [ToolBuildEventV1]
    public var attempts: [ToolBuildAttemptV1]
    public var validations: [ToolBuildValidationRecordV1]
    public var result: ToolBuildResultV1?
    public var failure: ToolAgentFailureCodeV1?

    fileprivate init(request: ToolBuildRequestV1) {
        let counters = ToolAgentUsageCountersV1(modelTurns: 0, toolCalls: 0, repairs: 0)
        self.request = request
        self.state = .created
        self.counters = counters
        self.events = [.init(sequence: 0, state: .created, counters: counters, failure: nil)]
        self.attempts = []
        self.validations = []
        self.result = nil
        self.failure = nil
    }

    public var isTerminal: Bool {
        result != nil || failure != nil
    }
}

public enum ToolBuildStoreError: Error, Equatable, Sendable {
    case duplicateRun
    case runNotFound
    case terminalRun
}

public actor ToolBuildStore {
    private let directoryURL: URL
    private var records: [UUID: ToolBuildRecordV1] = [:]

    public init(directoryURL: URL) throws {
        self.directoryURL = directoryURL
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    public func create(_ request: ToolBuildRequestV1) throws {
        guard records[request.runID] == nil, !FileManager.default.fileExists(atPath: url(for: request.runID).path) else {
            throw ToolBuildStoreError.duplicateRun
        }
        let record = ToolBuildRecordV1(request: request)
        try persist(record)
        records[request.runID] = record
    }

    public func record(runID: UUID) throws -> ToolBuildRecordV1 {
        if let record = records[runID] { return record }
        let data: Data
        do {
            data = try Data(contentsOf: url(for: runID))
        } catch {
            throw ToolBuildStoreError.runNotFound
        }
        let record = try JSONDecoder().decode(ToolBuildRecordV1.self, from: data)
        records[runID] = record
        return record
    }

    public func transition(runID: UUID, to state: ToolAgentBuildStateV1, failure: ToolAgentFailureCodeV1? = nil) throws {
        try update(runID: runID) { record in
            guard !record.isTerminal else { throw ToolBuildStoreError.terminalRun }
            record.state = state
            record.failure = failure
            record.events.append(.init(
                sequence: record.events.count,
                state: state,
                counters: record.counters,
                failure: failure
            ))
        }
    }

    public func charge(runID: UUID, modelTurns: Int = 0, toolCalls: Int = 0, repairs: Int = 0) throws {
        try update(runID: runID) { record in
            guard !record.isTerminal else { throw ToolBuildStoreError.terminalRun }
            record.counters = .init(
                modelTurns: record.counters.modelTurns + modelTurns,
                toolCalls: record.counters.toolCalls + toolCalls,
                repairs: record.counters.repairs + repairs
            )
        }
    }

    public func appendAttempt(runID: UUID, candidateID: UUID, fingerprint: ToolAgentFingerprintV1, candidate: ToolAgentCandidateV1) throws {
        try update(runID: runID) { record in
            guard !record.isTerminal else { throw ToolBuildStoreError.terminalRun }
            record.attempts.append(.init(
                sequence: record.attempts.count,
                candidateID: candidateID,
                fingerprint: fingerprint,
                candidate: candidate
            ))
        }
    }

    public func appendValidation(runID: UUID, report: ToolAgentValidationReportV1) throws {
        try update(runID: runID) { record in
            guard !record.isTerminal else { throw ToolBuildStoreError.terminalRun }
            record.validations.append(.init(sequence: record.validations.count, report: report))
        }
    }

    public func complete(runID: UUID, result: ToolBuildResultV1) throws {
        try update(runID: runID) { record in
            guard !record.isTerminal else { throw ToolBuildStoreError.terminalRun }
            record.state = .candidateReady
            record.result = result
            if record.events.last?.state != .candidateReady {
                record.events.append(.init(
                    sequence: record.events.count,
                    state: .candidateReady,
                    counters: record.counters,
                    failure: nil
                ))
            }
        }
    }

    private func update(runID: UUID, mutation: (inout ToolBuildRecordV1) throws -> Void) throws {
        var record = try self.record(runID: runID)
        try mutation(&record)
        try persist(record)
        records[runID] = record
    }

    private func persist(_ record: ToolBuildRecordV1) throws {
        let data = try ToolAgentCanonicalJSONV1.encode(record)
        try data.write(to: url(for: record.request.runID), options: .atomic)
    }

    private func url(for runID: UUID) -> URL {
        directoryURL.appendingPathComponent(runID.uuidString.lowercased()).appendingPathExtension("json")
    }
}
