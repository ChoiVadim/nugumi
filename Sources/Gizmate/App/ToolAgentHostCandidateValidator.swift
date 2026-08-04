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
                // Says what to do about it, because the obvious repair is the
                // wrong one. Handed only the fact, the model rewrites the tool
                // in Python — which cannot open a missing app either, and now
                // it is an unread script the user has to approve. A misspelling
                // is worth another try; an app that is genuinely not installed
                // is not a tool this Mac can build today.
                failureDetail = applicationExists(candidate.target)
                    ? nil
                    : "No installed macOS application named \(candidate.target) was found. "
                        + "Check the spelling and the name macOS shows for it, and try the "
                        + "native action once more. If the app really is not installed, say "
                        + "so with UNSUPPORTED — do not rewrite this as a Python tool, "
                        + "because Python cannot open an app that is not there either."
            case .openURL:
                let testValue = candidate.target.replacingOccurrences(
                    of: "{input}",
                    with: "https://example.com"
                )
                let scheme = URL(string: testValue)?.scheme?.lowercased()
                failureDetail = ["http", "https"].contains(scheme)
                    ? nil
                    : "The native link target must be a valid http or https URL."
            case .revealInFinder, .runShortcut, .saveToNote:
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

    /// Whether a native candidate's app target names something this Mac can
    /// actually open.
    ///
    /// Delegates to the resolver the run itself uses. Keeping a second copy of
    /// the rules here is how the builder came to refuse names a run could have
    /// opened — and would just as easily accept ones it could not.
    @MainActor
    static func installedApplicationExists(_ target: String) -> Bool {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if NativeToolRunner.applicationURL(for: trimmed) != nil { return true }
        // An app running from somewhere nobody scans is still installed.
        return NSWorkspace.shared.runningApplications.contains {
            $0.localizedName?.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
                || $0.bundleIdentifier?.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }
    }
}
