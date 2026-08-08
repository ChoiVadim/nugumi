import CryptoKit
import Foundation

// One gizmo's editable state, and the rules that decide what saving it means.
//
// Lifted out of `ToolEditor.swift` ahead of the draft itself, so the move that
// matters lands on its own. Both types are pure — no view, no agent, no model
// call — which is why they were always the wrong things to be reading out of a
// 1600-line SwiftUI file.

enum ToolEditorDraftVerification {
    static func fingerprint(tool: GizmateTool, script: String, brief: String) -> String {
        var effectiveTool = tool
        effectiveTool.brief = brief
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var payload = (try? encoder.encode(effectiveTool)) ?? Data()
        payload.append(0)
        payload.append(contentsOf: script.utf8)
        return SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Whether saving this draft also approves it for its first run.
    ///
    /// Code that has already run once in front of the user needs no second
    /// consent, whoever pressed the button: Install & test, or the build itself,
    /// which validates a candidate by running it. Anything else — saved without
    /// testing, built without ever being run, or edited since — still meets the
    /// run gate, because nobody has run *this* code yet.
    ///
    /// Only the two kinds that execute something have a gate to skip; a prompt
    /// or a native action never had one.
    static func savingApproves(
        kind: ToolKind,
        ranFingerprint: String?,
        current: String
    ) -> Bool {
        guard kind == .python || kind == .agent else { return false }
        return ranFingerprint == current
    }
}

enum ToolTestState {
    case idle
    case running
    case passed(String)
    case failed(String)

    var isRunning: Bool { if case .running = self { return true }; return false }
    var isFailure: Bool { if case .failed = self { return true }; return false }

    var report: String? {
        switch self {
        case .idle: return nil
        // The editor shows live output while running, so this is only a fallback.
        case .running: return nil
        case .passed(let text), .failed(let text): return text
        }
    }
}
