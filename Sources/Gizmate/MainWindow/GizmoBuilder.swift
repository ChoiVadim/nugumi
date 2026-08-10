import Combine
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
        /// `images` is what the person showed rather than described — a
        /// reference screenshot, a photo of the thing they want read. Carried
        /// only by the two calls a person starts; `repair` is started by a
        /// failure and has no message to attach one to.
        var generate: (
            _ description: String,
            _ images: [ChatImage],
            _ onPartial: @escaping @Sendable (String) -> Void,
            _ clarification: @escaping ToolBuildClarificationHandlerV1,
            _ cancelled: @escaping @Sendable () async -> Void,
            _ secret: @escaping ToolAgentLiveBuilder.SecretRequest
        ) async -> Result<GeneratedTool, Error>
        var revise: (
            _ tool: GizmateTool,
            _ script: String,
            _ instruction: String,
            _ images: [ChatImage],
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
        /// Whether the model a build would run on can look at a picture.
        ///
        /// Asked before the build rather than discovered inside it: the clients
        /// throw on a picture a model can't take, which would end the whole
        /// build over an attachment. Losing the picture and saying so is the
        /// smaller loss, and it is the user's call whether to switch models and
        /// ask again.
        var seesPictures: () -> Bool = { false }
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
    private var chatChanges: AnyCancellable?

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
        // The chat is a second `ObservableObject` hanging off this one, and
        // SwiftUI does not follow that hop: a view holding `@ObservedObject var
        // builder` is subscribed to this object alone, so `chat.activity`
        // changing redrew nothing. The build's running commentary sat on one
        // line until something *else* here published — leaving the section and
        // coming back was the reliable way to see the next step, which is the
        // same symptom, from the same cause, that `HomeChatPane` documents for
        // `homeChat`.
        //
        // Forwarded here rather than fixed by handing every view a second
        // `@ObservedObject`: `chat` is a `let`, so there is no re-subscription
        // to get wrong, and three call sites reading `builder.chat` cannot each
        // remember to observe it.
        chatChanges = self.chat.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
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
    ///
    /// - Parameter question: what the user typed, when they typed it somewhere
    ///   else. `request` is Gizmate's own wording of the job and is what the
    ///   agent is given; this is what the transcript shows, because a person
    ///   should see their own sentence above the work it started.
    func startNew(
        _ request: String,
        asking question: String? = nil,
        showing images: [ChatImage] = []
    ) {
        if let question { chat.record(request: question, images: images) }
        let carried = picturesTheModelCanSee(images)
        let draft = self.draft(for: .new)
        draft.brief = request
        live = draft
        run { agent, partial, clarify, cancelled, secret in
            await agent.generate(request, carried, partial, clarify, cancelled, secret)
        }
    }

    /// Changes one that exists.
    func startEdit(
        _ id: UUID,
        instruction: String,
        asking question: String? = nil,
        showing images: [ChatImage] = []
    ) {
        if let question { chat.record(request: question, images: images) }
        let carried = picturesTheModelCanSee(images)
        let draft = self.draft(for: .existing(id))
        live = draft
        let tool = draft.draft
        let script = draft.script
        run { agent, partial, clarify, cancelled, secret in
            await agent.revise(tool, script, instruction, carried, partial, clarify, cancelled, secret)
        }
    }

    /// The pictures worth sending, and a line in the transcript when there is a
    /// difference. Said in the chat rather than as a status line, because a
    /// status line is replaced by the next one and this is a fact about what
    /// the finished gizmo was built from.
    private func picturesTheModelCanSee(_ images: [ChatImage]) -> [ChatImage] {
        guard !images.isEmpty else { return [] }
        NSLog("[Gizmate/Build] %d picture(s) offered, model sees pictures: %@",
              images.count, agent.seesPictures() ? "yes" : "no")
        guard !agent.seesPictures() else { return images }
        chat.record(
            note: "I can't look at pictures on the model that's picked for building, "
                + "so I'll go by your words. Choose one that reads images in Settings "
                + "if you want me to use what you showed me."
        )
        return []
    }

    /// Fixes a gizmo whose last run failed, from the error it produced.
    ///
    /// The failure is the instruction, so there is nothing for the user to type
    /// and nothing for them to retype: the agent is handed the diagnostics it
    /// needs. Started from the Details modal's "Fix it", which used to run its
    /// own agent call against its own chat session, and therefore had nowhere to
    /// put a question the repair stopped to ask.
    func startRepair(_ draft: GizmoDraft, failure: String) {
        live = draft
        let tool = draft.draft
        let script = draft.script
        chat.markCandidateStale()
        run { agent, partial, clarify, cancelled, secret in
            await agent.repair(tool, script, failure, partial, clarify, cancelled, secret)
        }
    }

    /// A message typed while a build is open: either an answer to a question
    /// the agent asked, or the next instruction.
    func send(_ text: String, showing images: [ChatImage] = []) async {
        guard let submission = await chat.submit(text, images: images) else { return }
        switch submission {
        case .answeredClarification:
            // The agent is waiting on this and will carry on by itself. Starting
            // a second build here is what would strand the first one's
            // continuation.
            //
            // Which is also why a picture cannot ride along: an answer travels
            // as `ToolAgentAskUserResponseV1`, which is text, and it resumes a
            // turn that is already in flight. Said out loud rather than
            // swallowed, because the agent's own question is often "show me the
            // reference", and a picture that vanishes at exactly that moment is
            // the worst place to be quiet.
            if !images.isEmpty {
                chat.record(
                    note: "I can't take a picture along with an answer to my own question. "
                        + "Answer in words, then show me the picture in a new message and "
                        + "I'll look at it."
                )
            }
            return
        case .buildRequest(let request):
            chat.markCandidateStale()
            guard let live, live.hasTool else {
                startNew(request, showing: images)
                return
            }
            guard case .existing(let id) = live.subject else {
                startNew(request, showing: images)
                return
            }
            startEdit(id, instruction: request, showing: images)
        }
    }

    /// Whether the person can usefully run this one themselves before saving,
    /// which is the single decision behind both the offer and the sentence
    /// making it. It used to be two: the copy asked "run it once and tell me
    /// what happened" whenever Gizmate's own run proved nothing, while the
    /// button appeared only for a script — so a prompt gizmo asked to be run
    /// and gave you nothing to press.
    ///
    /// A surface is the other half of the same mistake. Its run prints rows
    /// for a panel, not an answer: pressing Try it shows a person a line of
    /// JSON, which grades nothing. The way to judge one is to look at the edge
    /// it lives on, and saving is what puts it there.
    static func trial(for generated: GeneratedTool) -> ToolBuilderTrial {
        guard generated.tool.kind == .python, generated.tool.output != .surface else {
            return .notNeeded
        }
        return generated.assurance == .verified ? .notNeeded : .untried
    }

    /// Clears the builder's half of Home's transcript, for the "new chat"
    /// control beside the panel toggle.
    ///
    /// Drafts are deliberately left in place. `stop` ends the build in flight
    /// and `chat.reset` takes the conversation away, but an unsaved gizmo is
    /// real work that a second surface may be showing — the Details modal
    /// holds the same object, per `draft(for:)` — so discarding it here would
    /// destroy something the user never asked to lose. Opening that gizmo again
    /// finds it exactly as it was.
    func startFresh() {
        stop()
        chat.reset()
        live = nil
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
        // The whole transcript, not only the card. A saved gizmo is a finished
        // piece of work, and leaving the conversation that built it on screen
        // means the next thing you type lands underneath a wall of steps about
        // something already done.
        chat.reset()
        discard(live.subject)
        self.live = nil
        return saved
    }

    /// What the build has been doing, written for the agent that started it.
    ///
    /// One agent decides and one transcript is drawn, but the agent is only
    /// ever sent its own turns — so a build it started is invisible to it. The
    /// user watches a gizmo fail on screen, types "try again", and is asked what
    /// they would like to try again. This is the missing half of the sentence.
    ///
    /// Deliberately a summary rather than the whole transcript: the build's own
    /// running commentary is dozens of status lines about work that is over, and
    /// what the next message needs is what happened and where it stands.
    ///
    /// - Returns: `nil` when no build has been started, so a first message
    ///   carries no heading about a build that never happened.
    func situation(lastMessages limit: Int = 4) -> String? {
        let recent = chat.messages.suffix(limit).map {
            ($0.role == .user ? "They said: " : "You said: ") + $0.text
        }
        guard !recent.isEmpty else { return nil }
        let standing: String
        if generating {
            standing = "You are building it right now."
        } else if chat.isAwaitingAnswer {
            standing = "You are waiting for them to answer your question."
        } else if chat.readyMessage != nil {
            standing = "It is finished and waiting for them to press Save."
        } else if chat.hasError {
            standing = "It stopped without finishing. They can see the reason on screen."
        } else {
            standing = "Nothing is being built at the moment."
        }
        return """
            What your builder has been doing (they can see all of this on screen):
            \(recent.joined(separator: "\n"))
            \(standing)
            """
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
                    trial: Self.trial(for: generated)
                )
            case .failure(let error):
                self.chat.appendError(error.localizedDescription)
            }
        }
    }
}
