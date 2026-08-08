import CryptoKit
import Foundation
import GizmateToolAgentCore

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


/// One gizmo being edited, and its own test run.
///
/// Lifted out of `ToolEditorPanel`, where all of this lived as `@State` on a
/// 1600-line SwiftUI view. That worked while a gizmo was only ever edited
/// inside one modal, and stopped working the moment the main chat had to build
/// and change gizmos too: state that belongs to a view dies with the view, so a
/// build begun in the chat ended the moment you looked at another section.
///
/// No chat and no agent in here on purpose. This is the half that can be tested
/// without a model: what a draft is, when a test result still applies to it,
/// and what saving it approves.
@MainActor
final class GizmoDraft: ObservableObject {
    /// Which gizmo this is a draft of.
    enum Subject: Hashable {
        case new
        case existing(UUID)
    }

    /// Runs a script once and reports what happened, streaming its output.
    /// A closure rather than the bridge, so a test can drive this with no
    /// process — the same call `AskEngine` and `ToolChatConversation.Answer`
    /// make, for the same reason.
    typealias Runner = (
        _ tool: GizmateTool,
        _ script: String,
        _ onOutput: @escaping @Sendable (String) -> Void
    ) async -> ToolTestState

    let subject: Subject

    /// The three things a person can change. `didSet` is the point of this
    /// type: invalidation used to be a view's `.onChange`, which anything
    /// writing these fields could route around, and what it guards is whether
    /// saving approves the gizmo for its first run. Unbypassable here.
    @Published var draft: GizmateTool { didSet { invalidate() } }
    @Published var script: String { didSet { invalidate() } }
    @Published var brief: String { didSet { invalidate() } }

    @Published private(set) var test: ToolTestState = .idle
    /// The tail of what the run has printed so far, capped: uv's progress bars
    /// redraw with `\r` and would otherwise grow without bound.
    @Published private(set) var liveOutput = ""
    /// A visible clock, because "Running…" on its own cannot tell a 3-second
    /// script from a stalled one.
    @Published private(set) var elapsed = 0
    @Published private(set) var summary: String?
    @Published private(set) var assurance: ToolAgentAssuranceV1?
    /// Whether there is a gizmo here yet, or only a request for one.
    @Published private(set) var hasTool: Bool

    /// The candidate the builder last declared ready, if the draft still
    /// matches it. Cleared by any edit, which is what makes a stale card go.
    private(set) var readyFingerprint: String?

    private var ticker: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var runningFingerprint: String?
    private var passedFingerprint: String?
    /// A draft Gizmate itself executed while building it. Carries exactly the
    /// standing a passed Install & test does: this precise code has already run
    /// in front of the user.
    private var builtAndRanFingerprint: String?
    /// True while `apply` is writing the three fields, so the invalidation edge
    /// does not fire between them and throw away the standing the build just
    /// earned. Without it, writing draft then script then brief invalidates
    /// twice on the way to a consistent state.
    private var applying = false

    private let tools: ToolsStore
    private let runner: Runner

    init(subject: Subject, tools: ToolsStore, runner: @escaping Runner) {
        self.subject = subject
        self.tools = tools
        self.runner = runner
        if case .existing(let id) = subject, let existing = tools.tool(id: id) {
            draft = existing
            script = tools.script(for: id) ?? ""
            brief = existing.brief
            summary = existing.brief.isEmpty ? nil : existing.brief
            hasTool = true
        } else {
            draft = GizmateTool()
            script = ""
            brief = ""
            hasTool = false
        }
    }

    // MARK: - What this draft is

    var fingerprint: String {
        ToolEditorDraftVerification.fingerprint(tool: draft, script: script, brief: brief)
    }

    var canSave: Bool {
        guard draft.isUsable else { return false }
        guard draft.kind == .python else { return true }
        return !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isRunning: Bool { test.isRunning }

    /// What the report box shows: the live tail while a run is in flight, the
    /// outcome once it has one.
    var reportText: String? {
        if test.isRunning {
            return liveOutput.isEmpty ? nil : liveOutput
        }
        return test.report
    }

    // MARK: - Editing

    /// Any edit drops whatever standing the draft had. Four things go together
    /// and must: the ready card, a passed test, a run in flight, and the fact
    /// that Gizmate itself ran this code. Each of them is a claim about code
    /// that no longer exists.
    private func invalidate() {
        guard !applying else { return }
        let now = fingerprint
        if let readyFingerprint, now != readyFingerprint { self.readyFingerprint = nil }
        if let passedFingerprint, now != passedFingerprint {
            self.passedFingerprint = nil
            test = .idle
            liveOutput = ""
        }
        if let builtAndRanFingerprint, now != builtAndRanFingerprint {
            self.builtAndRanFingerprint = nil
        }
        if let runningFingerprint, now != runningFingerprint {
            self.runningFingerprint = nil
            cancelRun()
        }
    }

    /// What the builder writes when a candidate arrives. One transaction, so
    /// the invalidation edge sees a consistent draft rather than three
    /// intermediate ones.
    func apply(
        tool: GizmateTool,
        script newScript: String,
        brief newBrief: String,
        summary newSummary: String?,
        assurance newAssurance: ToolAgentAssuranceV1?,
        ranAlready: Bool
    ) {
        applying = true
        draft = tool
        script = newScript
        if !newBrief.isEmpty { brief = newBrief }
        applying = false

        summary = newSummary
        assurance = newAssurance
        hasTool = true
        test = .idle
        liveOutput = ""
        passedFingerprint = nil
        runningFingerprint = nil
        readyFingerprint = fingerprint
        builtAndRanFingerprint = ranAlready ? fingerprint : nil
    }

    /// Whether the ready card still describes this draft.
    var candidateIsFresh: Bool { readyFingerprint == fingerprint }

    // MARK: - Running it

    /// Runs the draft once. Returns the outcome, or `nil` when the result was
    /// discarded because the draft moved while it ran — the double guard below
    /// is what stops a stale run's verdict being adopted by code it never saw.
    @discardableResult
    func runTest() async -> ToolTestState? {
        let tool = draft
        let code = script
        let started = fingerprint
        liveOutput = ""
        elapsed = 0
        test = .running
        passedFingerprint = nil
        runningFingerprint = started
        startTicker()

        let outcome = await runner(tool, code) { [weak self] chunk in
            Task { @MainActor in
                guard let self else { return }
                self.liveOutput = String((self.liveOutput + chunk).suffix(4000))
            }
        }
        stopTicker()
        runTask = nil
        guard runningFingerprint == started, fingerprint == started else { return nil }
        runningFingerprint = nil
        test = outcome
        if case .passed = outcome { passedFingerprint = started }
        return outcome
    }

    func cancelRun() {
        runTask?.cancel()
        runTask = nil
        stopTicker()
        if test.isRunning { test = .idle }
        runningFingerprint = nil
    }

    /// Everything in flight, for a draft being thrown away. The ticker matters
    /// most: it is a one-second repeat that would otherwise run for the rest of
    /// the session.
    func cancelInFlight() {
        cancelRun()
    }

    private func startTicker() {
        stopTicker()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.elapsed += 1
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    // MARK: - Saving

    /// Writes the gizmo and decides its first-run approval. Returns what was
    /// saved.
    ///
    /// Saving never places the gizmo: one is built in the chat and given a home
    /// from the Ring or Edges section afterwards.
    @discardableResult
    func save() -> GizmateTool? {
        guard canSave else { return nil }
        var tool = draft
        tool.name = tool.name.trimmingCharacters(in: .whitespacesAndNewlines)
        tool.prompt = tool.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        tool.brief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        tool.options = GizmateTool.sanitizedOptions(tool.options)
        tools.save(tool, script: tool.kind == .python ? script : nil)

        let ran: String? = {
            if case .passed = test, let passedFingerprint { return passedFingerprint }
            return builtAndRanFingerprint
        }()
        if ToolEditorDraftVerification.savingApproves(
            kind: tool.kind, ranFingerprint: ran, current: fingerprint
        ) {
            ToolApprovals.approve(tool.id, hash: tools.approvalHash(for: tool))
        } else {
            ToolApprovals.revoke(tool.id)
        }
        return tool
    }
}
