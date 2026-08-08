import Foundation

/// The plain half of Home's chat: the messages that are not about building
/// anything.
///
/// A second conversation rather than Ask's, deliberately. Ask is about what is
/// on your screen — it carries screenshots, it draws on them, and its system
/// prompt is written for that. This one is about Gizmate and about whatever you
/// felt like asking. Interleaving the two would put a screen analysis three
/// lines above a gizmo being built, in one transcript that is about neither.
///
/// Much smaller than `AskConversationStore` because there is no camera, no
/// pencil, no annotations, and nothing to consent to: it is text in and text
/// out. What they do share is the shape, so a reader of one recognises the
/// other.
@MainActor
final class ToolChatConversation: ObservableObject {
    struct Turn: Equatable, Identifiable {
        let id = UUID()
        let question: String
        var answer: String
        var failure: String?
    }

    @Published private(set) var turns: [Turn] = []
    /// The turn being answered, if one is. Separate from `turns` for the same
    /// reason `AskConversationStore.pending` is: a half-arrived answer is not a
    /// turn yet, and treating it as one puts an empty answer in the history the
    /// next question would carry.
    @Published private(set) var pending: Turn?

    var isRunning: Bool { pending != nil && pending?.failure == nil }

    /// What it takes to answer one message. A closure rather than the backend
    /// itself, so this is drivable with no network — the same call `AskEngine`
    /// makes, and for the same reason.
    typealias Answer = (_ history: [Turn], _ question: String, _ onPartial: @escaping (String) -> Void) async throws -> String

    private let answer: Answer
    private var task: Task<Void, Never>?
    /// Which turn a streamed partial belongs to. A partial reaches the main
    /// actor through a hop and can land after its own turn has committed.
    private var turn = 0

    init(answer: @escaping Answer) {
        self.answer = answer
    }

    func send(_ question: String) {
        let clean = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !isRunning else { return }
        pending = Turn(question: clean, answer: "")
        turn += 1
        let token = turn
        let history = turns
        let answer = answer

        task?.cancel()
        task = Task { [weak self] in
            do {
                let reply = try await answer(history, clean) { partial in
                    Task { @MainActor [weak self] in
                        guard let self, self.turn == token, self.pending != nil else { return }
                        self.pending?.answer = partial
                    }
                }
                try Task.checkCancellation()
                guard let self, self.turn == token else { return }
                self.turns.append(Turn(question: clean, answer: reply))
                self.pending = nil
            } catch is CancellationError {
                self?.pending = nil
            } catch {
                self?.pending?.failure = error.localizedDescription
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }

    func clear() {
        cancel()
        turns = []
    }
}
