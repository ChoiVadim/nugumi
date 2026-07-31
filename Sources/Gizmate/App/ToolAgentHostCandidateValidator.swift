import AppKit
import Foundation
import GizmateToolAgentCore

enum ToolAgentHostCandidateValidator {
    static func validate(
        candidateID: UUID,
        fingerprint: ToolAgentFingerprintV1,
        candidate: ToolAgentCandidateV1,
        applicationExists: (String) -> Bool
    ) throws -> ToolAgentValidationReportV1 {
        let failureDetail: String?
        switch candidate.kind {
        case .prompt:
            failureDetail = nil
        case .native:
            switch candidate.nativeAction {
            case .openApp, .openAppFullScreen, .sendTextToApp:
                failureDetail = applicationExists(candidate.target)
                    ? nil
                    : "No installed macOS application named \(candidate.target) was found."
            case .openURL:
                let testValue = candidate.target.replacingOccurrences(
                    of: "{input}",
                    with: "https://example.com"
                )
                let scheme = URL(string: testValue)?.scheme?.lowercased()
                failureDetail = ["http", "https"].contains(scheme)
                    ? nil
                    : "The native link target must be a valid http or https URL."
            case .revealInFinder, .runShortcut:
                failureDetail = nil
            case nil:
                failureDetail = "The native action is missing."
            }
        case .python:
            failureDetail = "Python candidates must be tested in the sandbox worker."
        case .agent:
            failureDetail = "Agent candidates are checked by running them."
        }

        if let failureDetail {
            return try ToolAgentValidationReportV1(
                candidateID: candidateID,
                fingerprint: fingerprint,
                outcome: .failed,
                failure: .invalidCandidate,
                stderrDetail: failureDetail
            )
        }
        return try ToolAgentValidationReportV1(
            candidateID: candidateID,
            fingerprint: fingerprint,
            outcome: .passed,
            passingFingerprint: fingerprint
        )
    }

    @MainActor
    static func installedApplicationExists(_ target: String) -> Bool {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("."),
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) != nil {
            return true
        }
        if NSWorkspace.shared.runningApplications.contains(where: {
            $0.localizedName?.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return true
        }
        let appName = trimmed.hasSuffix(".app") ? trimmed : "\(trimmed).app"
        let roots = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications"),
        ]
        return roots.contains {
            FileManager.default.fileExists(
                atPath: ($0 as NSString).appendingPathComponent(appName)
            )
        }
    }
}
