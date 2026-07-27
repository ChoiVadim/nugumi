import Foundation
import NugumiToolAgentCore
import NugumiToolIPC

extension CandidateValidator {
    func reply(
        _ request: CandidateValidationRequestV1,
        fixtureIndex: Int? = nil,
        outcome: ToolAgentValidationOutcomeV1 = .failed,
        failure: ToolAgentFailureCodeV1? = nil,
        processResult: BoundedProcessResult? = nil,
        actualOutput: String? = nil,
        directory: URL? = nil,
        started: UInt64,
        passingFingerprint: ToolAgentFingerprintV1? = nil
    ) -> CandidateValidationReplyV1 {
        let signal = processResult.flatMap(Self.terminationSignal)
        let stderr = processResult.flatMap {
            String(data: $0.stderr, encoding: .utf8)
        }.map {
            Self.redacted($0, privateDirectory: directory)
        }
        return CandidateValidationReplyV1(
            runID: request.runID,
            candidateID: request.candidateID,
            fingerprint: request.fingerprint,
            fixtureIndex: fixtureIndex,
            outcome: outcome,
            failure: failure,
            exitCode: signal == nil ? processResult?.exitCode : nil,
            terminationSignal: signal,
            actualOutput: actualOutput.map {
                Self.redacted($0, privateDirectory: directory)
            },
            stderrDetail: stderr,
            stdoutWasTruncated: processResult?.stdoutWasTruncated ?? false,
            stderrWasTruncated: processResult?.stderrWasTruncated ?? false,
            processGroupTerminated: processResult?.processGroupTerminated ?? true,
            durationMilliseconds: Self.duration(
                since: started,
                now: DispatchTime.now().uptimeNanoseconds
            ),
            passingFingerprint: passingFingerprint
        )
    }

    static func normalizedOutput(_ value: String) -> String {
        var normalized = value.replacingOccurrences(of: "\r\n", with: "\n")
        if normalized.hasSuffix("\n") {
            normalized.removeLast()
        }
        return normalized
    }

    static func redacted(
        _ value: String,
        privateDirectory: URL?
    ) -> String {
        var result = value
        if let privateDirectory {
            result = result.replacingOccurrences(
                of: privateDirectory.path,
                with: "[REDACTED_PATH]"
            )
        }
        return result.replacingOccurrences(
            of: #"/[^\s"'()]*"#,
            with: "[REDACTED_PATH]",
            options: .regularExpression
        )
    }

    private static func terminationSignal(
        _ result: BoundedProcessResult
    ) -> Int32? {
        (128...255).contains(result.exitCode)
            ? result.exitCode - 128
            : nil
    }

    private static func duration(since start: UInt64, now: UInt64) -> Int {
        Int((now - start) / 1_000_000)
    }
}

public extension SandboxProbeLimits {
    static let candidateValidation = Self(
        wallSeconds: 10,
        cpuSeconds: 3,
        addressSpaceBytes: 256 * 1_024 * 1_024,
        fileBytes: 4 * 1_024 * 1_024,
        stdoutBytes: 64 * 1_024,
        stderrBytes: 64 * 1_024
    )
}
