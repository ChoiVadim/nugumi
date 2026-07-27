import Foundation
import NugumiToolAgentCore

@objc public protocol NugumiToolWorkerProtocol {
    func runProbe(_ requestData: Data, withReply reply: @escaping (Data) -> Void)
    func cancelProbe(_ runID: String, withReply reply: @escaping (Bool) -> Void)
    func runCandidate(
        _ requestData: Data,
        withReply reply: @escaping (Data) -> Void
    )
    func cancelCandidate(
        _ runID: String,
        withReply reply: @escaping (Bool) -> Void
    )
}

@objc public protocol NugumiToolWorkerHostProtocol {
    func fetchProbeFixture(_ requestData: Data, withReply reply: @escaping (Data) -> Void)
}

public struct SandboxProbeLimits: Codable, Equatable, Sendable {
    public let wallSeconds: Int
    public let cpuSeconds: Int
    public let addressSpaceBytes: UInt64
    public let fileBytes: UInt64
    public let stdoutBytes: Int
    public let stderrBytes: Int

    public init(
        wallSeconds: Int,
        cpuSeconds: Int,
        addressSpaceBytes: UInt64,
        fileBytes: UInt64,
        stdoutBytes: Int,
        stderrBytes: Int
    ) {
        self.wallSeconds = wallSeconds
        self.cpuSeconds = cpuSeconds
        self.addressSpaceBytes = addressSpaceBytes
        self.fileBytes = fileBytes
        self.stdoutBytes = stdoutBytes
        self.stderrBytes = stderrBytes
    }

    public static let feasibility = Self(
        wallSeconds: 5,
        cpuSeconds: 2,
        addressSpaceBytes: 256 * 1_024 * 1_024,
        fileBytes: 4 * 1_024 * 1_024,
        stdoutBytes: 64 * 1_024,
        stderrBytes: 64 * 1_024
    )
}

public struct SandboxProbeRequest: Codable, Equatable, Sendable {
    public let runID: UUID
    public let deniedReadPath: String
    public let deniedWritePath: String
    public let limits: SandboxProbeLimits

    public init(
        runID: UUID,
        deniedReadPath: String,
        deniedWritePath: String,
        limits: SandboxProbeLimits
    ) {
        self.runID = runID
        self.deniedReadPath = deniedReadPath
        self.deniedWritePath = deniedWritePath
        self.limits = limits
    }
}

public struct ProbeFixtureRequest: Codable, Equatable, Sendable {
    public let runID: UUID
    public let url: URL

    public init(runID: UUID, url: URL) {
        self.runID = runID
        self.url = url
    }
}

public struct ProbeFixtureResponse: Codable, Equatable, Sendable {
    public let accepted: Bool
    public let statusCode: Int?
    public let body: Data

    public init(accepted: Bool, statusCode: Int?, body: Data) {
        self.accepted = accepted
        self.statusCode = statusCode
        self.body = body
    }
}

public struct SandboxProbeResult: Codable, Equatable, Sendable {
    public let runID: UUID
    public let pythonVersion: String
    public let dependencyVersion: String
    public let workspaceWriteSucceeded: Bool
    public let hostReadDenied: Bool
    public let hostWriteDenied: Bool
    public let rawNetworkDenied: Bool
    public let mediatedNetworkSucceeded: Bool
    public let stdoutBounded: Bool
    public let stderrBounded: Bool
    public let timedOutProcessGroupTerminated: Bool

    public init(
        runID: UUID,
        pythonVersion: String,
        dependencyVersion: String,
        workspaceWriteSucceeded: Bool,
        hostReadDenied: Bool,
        hostWriteDenied: Bool,
        rawNetworkDenied: Bool,
        mediatedNetworkSucceeded: Bool,
        stdoutBounded: Bool,
        stderrBounded: Bool,
        timedOutProcessGroupTerminated: Bool
    ) {
        self.runID = runID
        self.pythonVersion = pythonVersion
        self.dependencyVersion = dependencyVersion
        self.workspaceWriteSucceeded = workspaceWriteSucceeded
        self.hostReadDenied = hostReadDenied
        self.hostWriteDenied = hostWriteDenied
        self.rawNetworkDenied = rawNetworkDenied
        self.mediatedNetworkSucceeded = mediatedNetworkSucceeded
        self.stdoutBounded = stdoutBounded
        self.stderrBounded = stderrBounded
        self.timedOutProcessGroupTerminated = timedOutProcessGroupTerminated
    }

    public var gatePassed: Bool {
        workspaceWriteSucceeded
            && hostReadDenied
            && hostWriteDenied
            && rawNetworkDenied
            && mediatedNetworkSucceeded
            && stdoutBounded
            && stderrBounded
            && timedOutProcessGroupTerminated
            && pythonVersion == "3.12.11"
            && dependencyVersion == "3.10"
    }
}

public enum SandboxProbeFailureCode: String, Codable, Equatable, Sendable {
    case invalidRequest
    case hostProxyRejected
    case runtimeMissing
    case launchFailed
    case invalidProbeOutput
    case cancelled
}

public struct SandboxProbeFailure: Codable, Equatable, Sendable {
    public let runID: UUID?
    public let code: SandboxProbeFailureCode

    public init(runID: UUID?, code: SandboxProbeFailureCode) {
        self.runID = runID
        self.code = code
    }
}

public enum SandboxProbeReply: Codable, Equatable, Sendable {
    case success(SandboxProbeResult)
    case failure(SandboxProbeFailure)
}

public struct SandboxProbeGateReport: Codable, Equatable, Sendable {
    public let gatePassed: Bool
    public let result: SandboxProbeResult

    public init(result: SandboxProbeResult) {
        self.gatePassed = result.gatePassed
        self.result = result
    }
}
