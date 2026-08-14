import Combine
import GizmateToolAgentCore
import SwiftUI

enum ToolBuilderChatRole: Equatable {
    case assistant
    case user
}

struct ToolBuilderChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: ToolBuilderChatRole
    let text: String
    /// What was shown along with the words. Kept so the transcript can draw the
    /// message the way it was sent: a reference picture that vanished the
    /// moment it was sent reads as a message Gizmate never received.
    var images: [ChatImage] = []
}

enum ToolBuilderSubmission: Equatable {
    case buildRequest(String)
    case answeredClarification
}

/// The builder's questions and how far through them the user is.
///
/// The step lives here rather than in the card's `@State` because the
/// transcript re-evaluates its body on every streamed chunk above it, and the
/// one thing that must not be lost to a redraw is the answer someone already
/// gave. It is also what makes the flow testable without a view.
struct ToolBuilderQuestions: Equatable {
    let questions: [ToolAgentAskUserQuestionV1]
    /// One per question already answered, in order. An empty string is a skip.
    private(set) var answers: [String] = []

    var current: ToolAgentAskUserQuestionV1? {
        questions.indices.contains(answers.count) ? questions[answers.count] : nil
    }

    /// One-based, for "2 of 3". Reads as the count when everything is answered,
    /// which is only ever a frame before the card goes away.
    var step: Int { min(answers.count + 1, questions.count) }
    var total: Int { questions.count }
    var isComplete: Bool { answers.count >= questions.count }

    mutating func answer(_ text: String) {
        guard !isComplete else { return }
        answers.append(text)
    }

    /// Everything from here on is the builder's call. Used by the card's ✕:
    /// dismissing a question is not cancelling a build, and a person who does
    /// not know the answer must not be the reason nothing gets made.
    mutating func skipRemaining() {
        answers.append(contentsOf: Array(repeating: "", count: questions.count - answers.count))
    }

    /// What the transcript keeps once the card is gone. Skips are left out
    /// entirely: a row saying the user declined to answer is noise about a
    /// decision they already made.
    var recap: String? {
        let lines = zip(questions, answers)
            .filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "**\($0.0.question)** \($0.1)" }
        return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
    }
}

/// What is still missing before saving would be an honest thing to offer.
///
/// Gizmate grades its own validation, and two of the three grades do not prove
/// the tool produces the right answer — only that it compiles, or that it exits
/// cleanly. For those the last check available is the person who asked for the
/// tool running it once, so the chat asks for that instead of putting Save up
/// as if the tool were proven.
enum ToolBuilderTrial: Equatable {
    /// Gizmate ran it and the output matched, or the kind has nothing to run.
    case notNeeded
    case untried
    case passed
    case failed
}

@MainActor
final class ToolBuilderChatSession: ObservableObject {
    @Published private(set) var messages: [ToolBuilderChatMessage]
    @Published private(set) var activity: [String] = []
    @Published private(set) var isAwaitingAnswer = false
    /// The questions the builder stopped to ask, and the answers so far.
    /// Non-nil means a card is up and owns the composer.
    @Published private(set) var pendingQuestions: ToolBuilderQuestions?
    @Published private(set) var readyMessage: String?
    @Published private(set) var hasError = false
    @Published private(set) var trial: ToolBuilderTrial = .notNeeded
    /// The secret a candidate declared that the user has not stored. Non-nil
    /// means the build is parked in front of a key field.
    @Published private(set) var pendingSecret: String?

    private let answers: ToolBuilderAnswerBroker
    private let activityLimit: Int
    /// Kept so `reset` can open the way `init` did.
    private let greeting: String?
    private var answerGeneration: ToolBuilderAnswerBroker.Generation?
    private var secretContinuation: CheckedContinuation<Bool, Never>?

    /// The line this opens with. Nothing, unless someone asks for one.
    ///
    /// It used to default to "tell me what you want to happen", because the only
    /// session there was belonged to a panel that existed to build something and
    /// had to say so the moment it appeared. Home's chat is not that: it opens
    /// on its own invitation, and a greeting sitting here from launch would mean
    /// that screen is never empty and the invitation is never shown.
    init(
        activityLimit: Int = 8,
        greeting: String? = nil,
        beforeAnswerWaitRegistration: @escaping @Sendable () async -> Void = {}
    ) {
        answers = ToolBuilderAnswerBroker(
            beforeWaitRegistration: beforeAnswerWaitRegistration
        )
        self.activityLimit = max(1, activityLimit)
        self.greeting = greeting
        messages = greeting.map { [ToolBuilderChatMessage(role: .assistant, text: $0)] } ?? []
    }

    var currentActivity: String? { activity.last }

    /// Puts what the user asked into this transcript, for a request that reached
    /// the builder from somewhere other than its own composer.
    ///
    /// Home's chat is that somewhere: it hands the build over the moment
    /// Gizmate writes a directive, and drops its own turn because the answer was
    /// never prose. Without this the question would vanish with it, and the
    /// build would appear to have started on its own.
    func record(request text: String, images: [ChatImage] = []) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty || !images.isEmpty else { return }
        messages.append(.init(role: .user, text: value, images: images))
    }

    /// Something the builder needs to say on its own behalf — not a model's
    /// answer and not a step, but a fact about what it could and couldn't do
    /// with what it was given.
    func record(note: String) {
        messages.append(.init(role: .assistant, text: note))
    }

    func submit(_ text: String, images: [ChatImage] = []) async -> ToolBuilderSubmission? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        // A card is up: this is an answer to the question it is showing, not a
        // message. It gets no bubble of its own, because the card draws the
        // answer itself and the recap keeps it afterwards.
        if pendingQuestions != nil {
            await answer(value)
            return .answeredClarification
        }
        record(request: value, images: images)
        guard isAwaitingAnswer, let answerGeneration else {
            return .buildRequest(value)
        }
        await answers.answer([value], for: answerGeneration)
        return .answeredClarification
    }

    /// Answers whichever question the card is showing, and hands the whole set
    /// back to the builder once the last one is in.
    func answer(_ text: String) async {
        guard var pending = pendingQuestions else { return }
        pending.answer(text.trimmingCharacters(in: .whitespacesAndNewlines))
        await settle(pending)
    }

    /// The card's ✕. Skipping is not cancelling: the builder gets empty answers
    /// and is told to decide for itself, so the gizmo still gets made.
    func skipQuestions() async {
        guard var pending = pendingQuestions else { return }
        pending.skipRemaining()
        await settle(pending)
    }

    private func settle(_ pending: ToolBuilderQuestions) async {
        guard pending.isComplete else {
            pendingQuestions = pending
            return
        }
        pendingQuestions = nil
        if let recap = pending.recap {
            messages.append(.init(role: .assistant, text: recap))
        }
        guard let answerGeneration else { return }
        await answers.answer(pending.answers, for: answerGeneration)
    }

    func ask(_ request: ToolAgentAskUserRequestV1) async throws
        -> ToolAgentAskUserResponseV1 {
        let generation = try await answers.begin()
        if Task.isCancelled {
            await answers.cancel(generation)
            throw CancellationError()
        }
        answerGeneration = generation
        pendingQuestions = ToolBuilderQuestions(questions: request.questions)
        isAwaitingAnswer = true
        defer {
            if answerGeneration == generation {
                answerGeneration = nil
                isAwaitingAnswer = false
                pendingQuestions = nil
            }
        }
        return try ToolAgentAskUserResponseV1(
            answers: try await answers.wait(for: generation)
        )
    }

    /// Parks the build in front of a key field and waits.
    ///
    /// Not an `ask_user` clarification: those are capped at three and are only
    /// allowed before the first candidate is written, and a missing credential
    /// is usually discovered exactly when the code that reads it gets written.
    /// It also asks for the wrong thing — the user is holding a value, and being
    /// asked to name it first is a step that does nothing.
    ///
    /// - Returns: whether the key is now on disk. `false` is a real answer: the
    ///   validation run then fails on the missing key, which is the truth about
    ///   a tool that cannot authenticate.
    func requestSecret(_ name: String) async -> Bool {
        // Never strand an earlier waiter: a candidate may declare two keys.
        resolveSecret(false)
        messages.append(.init(
            role: .assistant,
            text: "This gizmo needs \(name). Paste it below — it stays on your "
                + "Mac, and only the name is ever sent to the model."
        ))
        pendingSecret = name
        return await withCheckedContinuation { secretContinuation = $0 }
    }

    /// - Parameter stored: whether the value reached disk. Skipping is `false`.
    func resolveSecret(_ stored: Bool) {
        guard let continuation = secretContinuation else { return }
        secretContinuation = nil
        pendingSecret = nil
        continuation.resume(returning: stored)
    }

    func recordActivity(_ status: String) {
        let value = status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, activity.last != value else { return }
        activity.append(value)
        if activity.count > activityLimit {
            activity.removeFirst(activity.count - activityLimit)
        }
    }

    /// - Parameter note: what running the candidate actually proved, when that
    ///   is a question worth answering. Saying "ready" about a tool Gizmate only
    ///   compiled would be the same overclaim the old validator made by
    ///   refusing to build anything it could not run.
    /// - Parameter trial: `.untried` when that note is an admission rather than
    ///   a result, which turns the next step from Save into one real run.
    func candidateReady(
        _ name: String,
        note: String? = nil,
        trial: ToolBuilderTrial = .notNeeded
    ) {
        hasError = false
        self.trial = trial
        readyMessage = [
            "\(name) is ready.",
            note,
            trial == .untried
                ? "Run it once and tell me what happened — or save it as is."
                : "Review it, ask for a change, or save the gizmo.",
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    /// The user took the run. Finishing cleanly still isn't proof the answer is
    /// the one they wanted — only they can say that — so passing asks rather
    /// than declares.
    func trialFinished(passed: Bool, report: String? = nil) {
        trial = passed ? .passed : .failed
        hasError = !passed
        if passed {
            readyMessage = "It ran and finished cleanly. If the result is what "
                + "you wanted, save it — otherwise tell me what's off."
            return
        }
        readyMessage = "That run failed. I can fix it from the error, or tell "
            + "me what you saw."
        // The full report lives on the script page; the tail is what says which
        // failure this was.
        if let report, !report.isEmpty {
            messages.append(.init(role: .assistant, text: String(report.suffix(600))))
        }
    }

    /// Back to how this opened. `markCandidateStale` clears what is claimed
    /// about a candidate; this clears the conversation that produced it, which
    /// is what a finished piece of work needs — a transcript about a gizmo that
    /// has been saved is describing something that is no longer in progress.
    func reset() {
        markCandidateStale()
        messages = greeting.map { [ToolBuilderChatMessage(role: .assistant, text: $0)] } ?? []
        activity = []
        pendingSecret = nil
        pendingQuestions = nil
    }

    func markCandidateStale() {
        hasError = false
        readyMessage = nil
        trial = .notNeeded
    }

    func appendError(_ message: String) {
        hasError = true
        messages.append(.init(role: .assistant, text: message))
        recordActivity("Stopped before a verified gizmo was ready.")
    }

    func cancel() async {
        isAwaitingAnswer = false
        pendingQuestions = nil
        // A build torn down while a key row is up would otherwise leave the
        // validation handler suspended on a continuation nobody will resume.
        resolveSecret(false)
        guard let answerGeneration else { return }
        self.answerGeneration = nil
        await answers.cancel(answerGeneration)
    }
}

actor ToolBuilderAnswerBroker {
    struct Generation: Equatable, Sendable {
        fileprivate let value: UInt64
    }

    private enum State {
        case idle
        case accepting(Generation, buffered: [String]?)
        case waiting(Generation, CheckedContinuation<[String], Error>)
        case cancelledBeforeRegistration(Generation)
    }

    private let beforeWaitRegistration: @Sendable () async -> Void
    private let onWaitRegistered: @Sendable () -> Void
    private var state: State = .idle
    private var nextGeneration: UInt64 = 0

    init(beforeWaitRegistration: @escaping @Sendable () async -> Void,
         onWaitRegistered: @escaping @Sendable () -> Void = {}) {
        self.beforeWaitRegistration = beforeWaitRegistration
        self.onWaitRegistered = onWaitRegistered
    }

    func begin() throws -> Generation {
        guard case .idle = state else {
            throw ToolAgentFailureCodeV1.invalidProtocol
        }
        nextGeneration &+= 1
        let generation = Generation(value: nextGeneration)
        state = .accepting(generation, buffered: nil)
        return generation
    }

    func wait(for generation: Generation) async throws -> [String] {
        await beforeWaitRegistration()
        switch state {
        case .cancelledBeforeRegistration(let active) where active == generation:
            state = .idle
            throw CancellationError()
        case .accepting(let active, let buffered) where active == generation:
            if let buffered {
                state = .idle
                return buffered
            }
            return try await withCheckedThrowingContinuation {
                state = .waiting(generation, $0)
                onWaitRegistered()
            }
        default:
            throw ToolAgentFailureCodeV1.invalidProtocol
        }
    }

    func answer(_ value: [String], for generation: Generation) {
        switch state {
        case .accepting(let active, buffered: nil) where active == generation:
            state = .accepting(generation, buffered: value)
        case .waiting(let active, let continuation) where active == generation:
            state = .idle
            continuation.resume(returning: value)
        default:
            break
        }
    }

    func cancel(_ generation: Generation) {
        switch state {
        case .accepting(let active, _) where active == generation:
            state = .cancelledBeforeRegistration(generation)
        case .waiting(let active, let continuation) where active == generation:
            state = .idle
            continuation.resume(throwing: CancellationError())
        default:
            break
        }
    }
}
