import Foundation
import GizmateToolAgentCore

/// Every gizmo currently being edited or built, and the one build in flight.
///
/// Owned by the app rather than by a view, and that is the whole reason it
/// exists. A build takes minutes and its result lives nowhere else until it is
/// saved, so hanging it off `ToolEditorPanel`'s `@State` meant closing the
/// panel — or, once Home hosted it, merely looking at another section — threw
/// the work away.
///
/// It also settles a question two surfaces would otherwise answer differently.
/// The chat can be changing a gizmo while that gizmo's Details modal is open,
/// and if each held its own copy the second save would quietly overwrite the
/// first. `draft(for:)` memoizes, so there is one draft per gizmo and both
/// surfaces are looking at it.
@MainActor
final class GizmoBuilder: ObservableObject {
    /// The three model calls a build makes. Closures rather than a protocol,
    /// the same call `AskEngine` and `ToolChatConversation.Answer` make: this is
    /// drivable with no network, and `SettingsHost` does not grow three more
    /// methods that six stub conformances would have to spell out.
    @MainActor
    struct Agent {
        var generate: (
            _ description: String,
            _ onPartial: @escaping @Sendable (String) -> Void,
            _ clarification: @escaping ToolBuildClarificationHandlerV1,
            _ cancelled: @escaping @Sendable () async -> Void,
            _ secret: @escaping ToolAgentLiveBuilder.SecretRequest
        ) async -> Result<GeneratedTool, Error>
        var revise: (
            _ tool: GizmateTool,
            _ script: String,
            _ instruction: String,
            _ onPartial: @escaping @Sendable (String) -> Void,
            _ clarification: @escaping ToolBuildClarificationHandlerV1,
            _ cancelled: @escaping @Sendable () async -> Void,
            _ secret: @escaping ToolAgentLiveBuilder.SecretRequest
        ) async -> Result<GeneratedTool, Error>
        var repair: (
            _ tool: GizmateTool,
            _ script: String,
            _ failure: String,
            _ onPartial: @escaping @Sendable (String) -> Void,
            _ clarification: @escaping ToolBuildClarificationHandlerV1,
            _ cancelled: @escaping @Sendable () async -> Void,
            _ secret: @escaping ToolAgentLiveBuilder.SecretRequest
        ) async -> Result<GeneratedTool, Error>
    }

    /// One transcript for the app, not one per gizmo.
    ///
    /// A conversation about building something is a conversation with Gizmate,
    /// and it was being restarted every time the subject changed — which is why
    /// switching gizmos used to wipe what had just been said. The answer broker
    /// inside the session forbids two builds at once anyway, so one is the
    /// honest number.
    let chat: ToolBuilderChatSession
    /// The gizmo the build in flight is about.
    @Published private(set) var live: GizmoDraft?
    @Published private(set) var generating = false

    private var drafts: [GizmoDraft.Subject: GizmoDraft] = [:]
    private var generateTask: Task<Void, Never>?

    private let tools: ToolsStore
    private let runner: GizmoDraft.Runner
    private let agent: Agent

    init(
        tools: ToolsStore,
        runner: @escaping GizmoDraft.Runner,
        agent: Agent,
        chat: ToolBuilderChatSession? = nil
    ) {
        self.tools = tools
        self.runner = runner
        self.agent = agent
        // No greeting: Home's chat opens on its own invitation, and a line
        // sitting here from launch would mean that screen is never empty.
        self.chat = chat ?? ToolBuilderChatSession(greeting: nil)
    }

    /// The draft for this gizmo, made once and kept.
    ///
    /// Identity is what matters here, not the contents: two calls must return
    /// the same object or the two surfaces editing it are editing different
    /// things.
    func draft(for subject: GizmoDraft.Subject) -> GizmoDraft {
        if let existing = drafts[subject] { return existing }
        let made = GizmoDraft(subject: subject, tools: tools, runner: runner)
        drafts[subject] = made
        return made
    }

    /// Throws a draft away once it has been saved or abandoned, cancelling
    /// whatever it still had running. The next `draft(for:)` hydrates a fresh
    /// one from the store, which is what makes a saved gizmo reopen showing
    /// what was saved rather than what was typed before it.
    func discard(_ subject: GizmoDraft.Subject) {
        drafts[subject]?.cancelInFlight()
        drafts[subject] = nil
    }

    /// Whether this gizmo has work in flight, for a control that must not let
    /// someone edit underneath it.
    func isBusy(_ subject: GizmoDraft.Subject) -> Bool {
        drafts[subject]?.isRunning ?? false
    }

    // MARK: - Building

    var isBuilding: Bool { generating }

    /// Builds a new gizmo from a plain description.
    func startNew(_ request: String) {
        let draft = self.draft(for: .new)
        draft.brief = request
        live = draft
        run { agent, partial, clarify, cancelled, secret in
            await agent.generate(request, partial, clarify, cancelled, secret)
        }
    }

    /// Changes one that exists.
    func startEdit(_ id: UUID, instruction: String) {
        let draft = self.draft(for: .existing(id))
        live = draft
        let tool = draft.draft
        let script = draft.script
        run { agent, partial, clarify, cancelled, secret in
            await agent.revise(tool, script, instruction, partial, clarify, cancelled, secret)
        }
    }

    /// A message typed while a build is open: either an answer to a question
    /// the agent asked, or the next instruction.
    func send(_ text: String) async {
        guard let submission = await chat.submit(text) else { return }
        switch submission {
        case .answeredClarification:
            // The agent is waiting on this and will carry on by itself. Starting
            // a second build here is what would strand the first one's
            // continuation.
            return
        case .buildRequest(let request):
            chat.markCandidateStale()
            guard let live, live.hasTool else {
                startNew(request)
                return
            }
            guard case .existing(let id) = live.subject else {
                startNew(request)
                return
            }
            startEdit(id, instruction: request)
        }
    }

    func stop() {
        generateTask?.cancel()
        generateTask = nil
        generating = false
        live?.cancelRun()
    }

    /// Saves the gizmo the build produced, without closing anything: the chat
    /// is where this happened and the chat stays where it is.
    @discardableResult
    func saveLive() -> GizmateTool? {
        guard let live, let saved = live.save() else { return nil }
        chat.markCandidateStale()
        discard(live.subject)
        self.live = nil
        return saved
    }

    /// The one shape all three calls share: mark busy, run, apply or report.
    /// The one shape all three calls share, including the four handlers that
    /// put the agent's own voice in the transcript: its running commentary, the
    /// questions it stops to ask, what happens when one is abandoned, and a
    /// request for a key.
    private func run(
        _ call: @escaping (
            Agent,
            @escaping @Sendable (String) -> Void,
            @escaping ToolBuildClarificationHandlerV1,
            @escaping @Sendable () async -> Void,
            @escaping ToolAgentLiveBuilder.SecretRequest
        ) async -> Result<GeneratedTool, Error>
    ) {
        generateTask?.cancel()
        generating = true
        let agent = agent
        let chat = chat
        generateTask = Task { @MainActor [weak self] in
            let outcome = await call(
                agent,
                { partial in Task { @MainActor in chat.recordActivity(partial) } },
                { clarification in try await chat.ask(clarification) },
                { await chat.cancel() },
                { name in await chat.requestSecret(name) }
            )
            guard let self else { return }
            self.generating = false
            self.generateTask = nil
            switch outcome {
            case .success(let generated):
                self.live?.apply(
                    tool: generated.tool,
                    script: generated.script,
                    brief: generated.brief,
                    summary: generated.summary,
                    assurance: generated.tool.kind == .python ? generated.assurance : nil,
                    ranAlready: generated.assurance != .unverified
                )
                self.live?.markCandidateReady()
                self.chat.candidateReady(
                    generated.tool.name,
                    note: generated.assurance.explanation,
                    trial: generated.assurance == .verified ? .notNeeded : .untried
                )
            case .failure(let error):
                self.chat.appendError(error.localizedDescription)
            }
        }
    }
}
